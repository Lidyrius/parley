using System.Collections.Concurrent;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Parley;

// Loopback HTTP server, same contract as macOS: the Claude Code Stop hook LONG-POLLS
// POST /turn and blocks until the voice reply is transcribed. Turns are serialized —
// one is spoken/recorded at a time; concurrent hooks queue FIFO (their connections
// stay open). GET /health, /status, /sessions and POST /ready, /wake, /presence, /resume,
// /dispatch, /permission, /snapshots…, /supervisor as on macOS. Everything that voices or listens holds PhoneCall from
// the moment it queues, so an iPhone in a call knows Parley is busy (docs/IPHONE.md, v2).
public sealed class Server
{
    private readonly HttpListener _listener = new();
    private readonly FifoGate _turnGate = new();   // serializes the pipeline, first come first served
    private readonly Func<TurnPayload, Task<(string transcript, bool park, int wait, string resume)>> _runTurn;
    private readonly Action _onReady;
    private int _queued;

    public int QueuedTurns => Volatile.Read(ref _queued);

    // Parked (paused-but-resumable) sessions. Their Stop hook short-polls /wake; we hand
    // back a pending instruction to wake them — no keystrokes. Keyed by session key.
    private sealed class Parked { public string Label = "", Project = ""; public string? Pending; public DateTime LastSeen, Since = DateTime.UtcNow; }
    private readonly ConcurrentDictionary<string, Parked> _parked = new();
    // A hook parked longer than this is told to end (`end`): nobody is coming back to it.
    private static readonly TimeSpan ParkLimit = TimeSpan.FromHours(12);

    // /wake, /presence, Deliver and the per-session queue below change together under this.
    private readonly object _lock = new();
    // What waits at the gate per session key: a newer /turn answers the older ones "" and
    // /close all of them. `_atGate` counts those not yet let in (Sessions.Waiting reads it).
    // `TurnId`: a hookless turn (POST /turn/cancel finds it); `Entered`: let in, being voiced.
    // `Payload`: a /turn's own; `Reported`: the Überwachungsmodus came on while it waited — it
    // went to the Zentrale as a report, not to Sir (Supervisor.cs).
    private sealed class Waiter { public readonly CancellationTokenSource Drop = new(); public bool Turn, Entered, Reported; public string? TurnId; public TurnPayload? Payload; }
    private readonly Dictionary<string, List<Waiter>> _waiters = new();
    private readonly ConcurrentDictionary<string, int> _atGate = new();
    // Closed by POST /close: its hook's next /wake answers `end` (until a new /turn revives it).
    private readonly HashSet<string> _closed = new();
    // Hookless (docs/HOOKLESS.md): the open turn_id per session — from its /turn until its reply
    // is delivered (or nothing is), through a wait. Presence `awaiting` anything else → unknown_turn.
    private readonly Dictionary<string, string> _turns = new();
    // Sir typed while a hookless turn is voiced: its recording ends now (TurnPipeline.Abandon).
    public Action? AbandonTurn;
    public event Action<List<ParkedInfo>>? OnParkedChanged;

    public readonly record struct ParkedInfo(string Id, string Label, string Project);

    // Every session and its state (GET /sessions, POST /resume, the announcement).
    public SessionRegistry Sessions { get; } = new();

    // What a resumed session continues with when no instruction was spoken.
    public const string ResumeInstruction = "Wir machen weiter.";

    // Queue item for the POST /resume voice dialog (rides the turn gate, never overlaps).
    public const string ResumeEvent = "resume";

    // iPhone (docs/IPHONE.md, v2): the wake greeting and a permission question ride the gate too.
    public const string WakeEvent = "wake";
    public const string PermissionEvent = "permission";
    // The Wachhund's question (Watchdog.cs): through the gate like a permission prompt.
    public const string WatchdogEvent = "watchdog";
    // A Wiedervorlage for Sir himself (Reminders.cs), spoken like an update.
    public const string ReminderEvent = "reminder";
    // Sir is back after a call he didn't take: what he missed goes to the Zentrale for one summary.
    public const string CallbackEvent = "callback";

    // Wiedervorlagen (Reminders.cs), kept in reminders.json; a handed-over one → OnReminded.
    public ReminderStore Reminders { get; } = new(Path.Combine(Config.Dir, "reminders.json"));
    public Action<Reminder>? OnReminded;
    // Snapshots (Snapshots.cs), kept in snapshots.json beside them.
    public SnapshotStore Snapshots { get; } = new(Path.Combine(Config.Dir, "snapshots.json"));
    // Überwachungsmodus (Supervisor.cs): the switch, kept in supervisor.json beside them (swapped
    // whole, never changed in place), the reports waiting for the Zentrale, and the batch handed
    // to it last (until it took it) — those two change under _lock.
    // ponytail: the inbox is in memory — reports not handed over yet (seconds, usually) are gone
    // with a restart; keep them beside reminders.json if that ever bites.
    private volatile Supervisor _supervisor = Supervisor.Load(Supervisor.FilePath);
    private readonly List<string> _reports = new();
    private string? _reportsOut;
    // What Sir missed (Supervisor.cs, Missed): the Zentrale's lines since a call he didn't take,
    // kept for his call back (missed.json), and when to ring once more ("In 5 Min." on the
    // phone) — both under _lock. `_callBackWaits`: a call-back dialog waits at the gate.
    private readonly List<MissedLine> _missed = Missed.Load(Missed.FilePath);
    private DateTime? _ringAgainAt;
    private int _callBackWaits;

    // POST /permission is answered within this — the hook waits ≤ 120 s; a few seconds spare.
    public static readonly TimeSpan PermissionHold = TimeSpan.FromSeconds(115);

    // Routing, POST /dispatch and instructions waiting for a session's first presence.
    public Delivery Delivery { get; }

    // Label and registry state for Remote Control's catch-up (RemoteControl.Seen).
    private (string Label, string State)? RemoteInfo(string id) => Sessions.Info(id) is { } i ? (i.Label, i.State) : null;

    // Sessions are keyed by the agent's session_id; the tmux pane only as a fallback.
    public static string SessionKey(TurnPayload t) => string.IsNullOrEmpty(t.SessionId) ? t.TmuxPane : t.SessionId;

    // `startSession`: how a session is started in a folder (folder, resume id → started); null =
    // SessionStarter (a terminal window). The Linux host starts them in tmux (linux/Tmux.cs).
    public Server(Func<TurnPayload, Task<(string, bool, int, string)>> runTurn, Action onReady,
                  Func<string, string?, bool>? startSession = null)
    {
        _runTurn = runTurn;
        _onReady = onReady;
        Delivery = new Delivery(Sessions, (id, instruction) => Deliver(id, instruction), startSession);
        Sessions.Waiting = id => _atGate.TryGetValue(id, out var n) && n > 0;
        Sessions.ReminderRows = () => Reminders.Rows();
        Sessions.SnapshotRows = () => Snapshots.Rows();
        SyncSupervisor();
        // 127.0.0.1 covers native Git Bash and WSL2 mirrored networking. (WSL NAT mode
        // would need an urlacl + firewall rule — documented, not default.)
        _listener.Prefixes.Add("http://127.0.0.1:8787/");
    }

    public void Start()
    {
        _listener.Start();
        _ = Task.Run(AcceptLoop);
        Log.Write("server listening on 127.0.0.1:8787");
    }

    private async Task AcceptLoop()
    {
        while (_listener.IsListening)
        {
            HttpListenerContext ctx;
            try { ctx = await _listener.GetContextAsync(); }
            catch { break; }
            _ = Task.Run(() => Handle(ctx));
        }
    }

    private async Task Handle(HttpListenerContext ctx)
    {
        try
        {
            var req = ctx.Request;
            var path = req.Url?.AbsolutePath ?? "";
            if (req.HttpMethod == "GET" && path == "/health")
            {
                await Respond(ctx, 200, "{\"ok\":true,\"async\":1}");
                return;
            }
            // /mod — stop-hook.sh asks first: a hookless mod carries this session's turns → it steps aside.
            if (req.HttpMethod == "GET" && path == "/mod")
            {
                var live = Sessions.ModLive(req.QueryString["session_id"] ?? "");
                await Respond(ctx, 200, live ? "{\"live\":true}" : "{\"live\":false}");
                return;
            }
            if (req.HttpMethod == "GET" && path == "/status")
            {
                await Respond(ctx, 200, LiveStatus.Json());
                return;
            }
            if (req.HttpMethod == "GET" && path == "/sessions")
            {
                await Respond(ctx, 200, Sessions.Json());
                return;
            }
            if (req.HttpMethod == "GET" && path == "/remind")
            {
                await Respond(ctx, 200, JsonSerializer.Serialize(new { reminders = Reminders.Rows() }));
                return;
            }
            if (req.HttpMethod == "GET" && path == "/supervisor")
            {
                SyncSupervisor();
                await Respond(ctx, 200, SupervisorJson());
                return;
            }

            string body;
            using (var r = new StreamReader(req.InputStream, Encoding.UTF8))
                body = await r.ReadToEndAsync();

            if (req.HttpMethod == "POST" && path == "/ready")
            {
                Log.Write("ready received");
                try { _onReady(); } catch { }
                var project = TurnPayload.Decode(body)?.Project ?? "";
                Notifier.Notify("Parley", "Voice-Modus aktiv" + (project.Length > 0 ? $" · {project}" : ""));
                await Respond(ctx, 200, "{\"ok\":true}");
                return;
            }

            if (req.HttpMethod == "POST" && path == "/turn")
            {
                var turn = TurnPayload.Decode(body);
                if (turn is null)
                {
                    await Respond(ctx, 400, "{\"ok\":false,\"error\":\"bad turn payload\"}");
                    return;
                }
                var id = SessionKey(turn);
                // Hookless (docs/HOOKLESS.md): the mod carries the turn — queued now, answered at
                // once; its reply becomes a delivery (Settle). Without `async` the hook long-polls.
                if (turn.Async && turn.TurnId is { Length: > 0 } tid && id.Length > 0)
                {
                    lock (_lock) _turns[id] = tid;
                    await Respond(ctx, 200, "{\"queued\":true}");
                    try { Settle(id, tid, await Voice(turn, id, tid)); }
                    catch (Exception e)
                    {
                        Log.Write($"turn failed ({turn.SpokenLabel}): {e.Message}");
                        lock (_lock) if (Open(id, tid)) _turns.Remove(id);
                    }
                    return;
                }
                var reply = await Voice(turn, id, null);
                await Respond(ctx, 200, TurnJson(reply.transcript, reply.park, reply.wait, reply.resume));
                return;
            }

            // /turn/cancel — Sir typed before the voice reply came: the hookless turn leaves the
            // queue; one being voiced loses its recording. Nothing of it is delivered.
            if (req.HttpMethod == "POST" && path == "/turn/cancel")
            {
                var c = TurnPayload.Decode(body);
                var (id, tid) = (c?.SessionId ?? "", c?.TurnId ?? "");
                Waiter? w = null;
                var known = false;
                lock (_lock)
                {
                    known = Open(id, tid);
                    if (known) _turns.Remove(id);
                    if (tid.Length > 0 && _waiters.TryGetValue(id, out var list)) w = list.FirstOrDefault(x => x.TurnId == tid);
                }
                if (w is { Entered: true }) AbandonTurn?.Invoke();
                else w?.Drop.Cancel();
                if (known) Sessions.EndWait(id);   // in its wait: over, and its timer delivers nothing
                Log.Write($"turn cancelled ({id}: {tid}{(w is { Entered: true } ? ", recording abandoned" : "")})");
                await Respond(ctx, 200, "{\"ok\":true}");
                return;
            }

            // /wake — a parked session's Stop hook short-polls this. Answer immediately with
            // any pending resume instruction (consuming it), else empty; (re)register so the
            // session stays listed as resumable. `end`: closed, a newer /turn of this session,
            // or parked past ParkLimit — the hook stops polling and finishes.
            if (req.HttpMethod == "POST" && path == "/wake")
            {
                var turn = TurnPayload.Decode(body);
                var pending = "";
                var end = false;
                if (turn is not null)
                {
                    var key = SessionKey(turn);
                    lock (_lock)
                    {
                        Prune();
                        var p = _parked.GetOrAdd(key, _ => new Parked());
                        end = _closed.Contains(key) || DateTime.UtcNow - p.Since > ParkLimit
                            || (key.Length > 0 && _waiters.TryGetValue(key, out var queued) && queued.Any(x => x.Turn));
                        if (end) _parked.TryRemove(key, out _);
                        else
                        {
                            p.Label = turn.SpokenLabel;
                            p.Project = turn.Project;
                            p.LastSeen = DateTime.UtcNow;
                            FlushReportsLocked();   // the Zentrale's parked hook takes its reports with this poll
                            pending = p.Pending ?? "";
                            p.Pending = null;
                            Sessions.WakePoll(key, turn.Label ?? "", turn.Project, pending.Length > 0, turn.Cwd);
                        }
                    }
                    if (end) Log.Write($"wake: {turn.SpokenLabel} — end");
                    else { Delivery.ClaimName(key, turn.Cwd); RemoteControl.Seen(key, () => RemoteInfo(key)); }
                    NotifyParked();
                }
                await Respond(ctx, 200, TurnJson(pending, false, 0, "", end));
                return;
            }

            // /presence — the mod's heartbeat from every Claude Code session (~2 s). A pending
            // resume instruction rides back exactly once; the mod submits it as a prompt.
            if (req.HttpMethod == "POST" && path == "/presence")
            {
                var presence = PresencePayload.Decode(body);
                if (presence is null || string.IsNullOrEmpty(presence.SessionId))
                {
                    await Respond(ctx, 400, "{\"ok\":false,\"error\":\"bad presence payload\"}");
                    return;
                }
                var project = string.IsNullOrEmpty(presence.Project)
                    ? Path.GetFileName((presence.Cwd ?? "").TrimEnd('/', '\\'))
                    : presence.Project;
                Sessions.Presence(presence.SessionId, presence.Label ?? "", project, presence.State ?? "idle",
                    presence.Usage, presence.Tasks, presence.Host, presence.Cwd, presence.Async, presence.Ack);
                // A session started for an instruction (POST /dispatch, a wake routed to the
                // Zentrale) gets it on the first presence from its folder.
                Delivery.ClaimName(presence.SessionId, presence.Cwd);
                if (Delivery.TakePending(presence.Cwd, presence.SessionId) is { } waiting)
                {
                    Sessions.SetPending(presence.SessionId, waiting);
                    Log.Write($"dispatch: delivered the waiting instruction to {project}");
                }
                (string Text, string Id)? delivery;
                var unknown = false;
                lock (_lock)   // the mod took it: the parked hook doesn't (and the other way round)
                {
                    delivery = Sessions.NextDelivery(presence.SessionId, presence.Async);
                    if (delivery is not null && _parked.TryGetValue(presence.SessionId, out var hook)) hook.Pending = null;
                    // Hookless: the turn it waits for is gone (a restart, or it ended without a reply).
                    unknown = presence.Awaiting is { Length: > 0 } awaiting && !Open(presence.SessionId, awaiting);
                }
                RemoteControl.Seen(presence.SessionId, () => RemoteInfo(presence.SessionId));
                NotifyParked();
                FlushReports();   // the Zentrale may take its reports now (they go out with its next presence)
                await Respond(ctx, 200, delivery is { } d ? JsonSerializer.Serialize(new { instruction = d.Text, delivery_id = d.Id })
                    : unknown ? "{\"unknown_turn\":true}" : "{}");
                return;
            }

            // /resume — the mod's resume button: answer at once, then run the short voice dialog
            // for that session behind any running turn. Only resumable (parked) sessions.
            if (req.HttpMethod == "POST" && path == "/resume")
            {
                if (!StartResume(ResumePayload.Decode(body)?.Id ?? ""))
                {
                    await Respond(ctx, 404, "{\"ok\":false}");
                    return;
                }
                await Respond(ctx, 200, "{\"ok\":true}");
                return;
            }

            // /past — the Zentrale looks up a past session (title, folder, last prompt) to resume it.
            if (req.HttpMethod == "POST" && path == "/past")
            {
                string? q = null;
                var limit = 10;
                try
                {
                    using var doc = JsonDocument.Parse(body.Length == 0 ? "{}" : body);
                    if (doc.RootElement.TryGetProperty("q", out var qv) && qv.ValueKind == JsonValueKind.String) q = qv.GetString();
                    if (doc.RootElement.TryGetProperty("limit", out var lv) && lv.TryGetInt32(out var l)) limit = Math.Clamp(l, 1, 50);
                }
                catch (JsonException) { }
                await Respond(ctx, 200, Transcript.PastJson(Transcript.FindPast(q, limit)));
                return;
            }

            // /dispatch — the Zentrale (docs/IPHONE.md, v2): deliver an instruction to the session
            // in a folder, starting one there when none runs. Same answers as macOS:
            // {"ok":true,"delivered":"session"|"pending","started":bool}; 400 for a relative or
            // missing folder.
            if (req.HttpMethod == "POST" && path == "/dispatch")
            {
                var d = DispatchPayload.Decode(body);
                string? past = null;
                if (d?.Resume is { } rid && (!Transcript.IsSessionId(rid) || (past = Transcript.File(rid)) is null))
                {
                    await Respond(ctx, 404, "{\"ok\":false,\"error\":\"no past session with that id\"}");
                    return;
                }
                // With `resume` the folder defaults to the session's own.
                var raw = d?.Cwd ?? (past is null ? null : Transcript.Summary(past)?.Cwd);
                var cwd = d is null || string.IsNullOrWhiteSpace(raw) || !Path.IsPathRooted(raw)
                    ? null : CwdPath.Resolve(raw, Config.Load().ProjectsDir);
                if (d is null || cwd is null || !Directory.Exists(cwd))
                {
                    await Respond(ctx, 400, "{\"ok\":false,\"error\":\"cwd must be an existing absolute folder\"}");
                    return;
                }
                var instruction = Addressed((d.Instruction ?? "").Trim(), d.From, cwd, d.Resume, d.Name);
                var result = Delivery.Dispatch(cwd, instruction, d.Start ?? true, d.Resume, d.Name);
                if (result == DispatchResult.Failed)
                {
                    await Respond(ctx, 500, "{\"ok\":false,\"error\":\"could not start a session\"}");
                    return;
                }
                await Respond(ctx, 200, JsonSerializer.Serialize(new
                {
                    ok = true,
                    delivered = result == DispatchResult.Delivered ? "session" : "pending",
                    started = result is DispatchResult.Started or DispatchResult.Starting,
                }));
                return;
            }

            // /palette — the Zentrale made a colour palette by voice: to the phone (now, or when it
            // connects). Same answers as macOS: {"ok":true,"name"} or 400 {"ok":false,"error"}.
            if (req.HttpMethod == "POST" && path == "/palette")
            {
                var (name, frame, error) = PaletteSpec.Parse(body);
                if (error is not null)
                {
                    await Respond(ctx, 400, JsonSerializer.Serialize(new { ok = false, error }));
                    return;
                }
                OnPalette?.Invoke(name!, frame!);
                await Respond(ctx, 200, JsonSerializer.Serialize(new { ok = true, name }));
                return;
            }

            // Start check (Zentrale.cs Delivery): GET /starting lists the starts on the way; Windows
            // can't type into another console, so POST /starting/answer says so.
            if (req.HttpMethod == "GET" && path == "/starting")
            {
                await Respond(ctx, 200, JsonSerializer.Serialize(Delivery.Starting()));
                return;
            }
            if (req.HttpMethod == "POST" && path == "/starting/answer")
            {
                if (Delivery.StartAnswer is not null)   // the Linux host types into its tmux sessions
                {
                    var (status, answer) = Delivery.AnswerStart(body);
                    await Respond(ctx, status, answer);
                    return;
                }
                await Respond(ctx, 501, JsonSerializer.Serialize(new { ok = false, error = "not on Windows — answer in the session's window" }));
                return;
            }

            // /remind — a Wiedervorlage (Reminders.cs). Same answers as macOS:
            // {"ok":true,"reminder":{id,text,to,at,after}} or 400 {"ok":false,"error"}.
            if (req.HttpMethod == "POST" && path == "/remind")
            {
                var (rem, error) = Reminders.Add(body, DateTime.UtcNow, ResolveSession);
                if (rem is null)
                {
                    await Respond(ctx, 400, JsonSerializer.Serialize(new { ok = false, error }));
                    return;
                }
                Log.Write($"remind: for {rem.Label}, {(rem.At is { } at ? $"at {at:o}" : $"after {rem.AfterLabel}")}{(rem.Every is { } every ? $", every {every} min" : "")}");
                FireReminders(r => r.Id == rem.Id && ReminderStore.IsDue(r, DateTime.UtcNow, Sessions.StateSince));
                await Respond(ctx, 200, JsonSerializer.Serialize(new { ok = true, reminder = ReminderStore.Rows(new[] { rem })[0] }));
                return;
            }
            if (req.HttpMethod == "POST" && path == "/remind/cancel")
            {
                var ids = new List<string>();
                try
                {
                    using var doc = JsonDocument.Parse(body.Length == 0 ? "{}" : body);
                    var r = doc.RootElement;
                    if (r.TryGetProperty("ids", out var a) && a.ValueKind == JsonValueKind.Array)
                        ids.AddRange(a.EnumerateArray().Where(v => v.ValueKind == JsonValueKind.String).Select(v => v.GetString()!));
                    if (r.TryGetProperty("id", out var i) && i.ValueKind == JsonValueKind.String) ids.Add(i.GetString()!);
                }
                catch (JsonException) { }
                var gone = Reminders.Cancel(ids);
                if (gone.Count == 0)
                {
                    await Respond(ctx, 404, "{\"ok\":false,\"error\":\"no reminder with that id\"}");
                    return;
                }
                Log.Write($"remind: cancelled {string.Join(", ", gone.Select(g => g.Label))}");
                await Respond(ctx, 200, JsonSerializer.Serialize(new { cancelled = ReminderStore.Rows(gone) }));
                return;
            }

            // /supervisor — the Überwachungsmodus on / off (the Zentrale sets it itself), and who is
            // exempt: {"on":bool,"exempt":[…]}, either or both. Same answers as macOS.
            if (req.HttpMethod == "POST" && path == "/supervisor")
            {
                bool? on = null;
                List<string>? exempt = null;
                try
                {
                    using var doc = JsonDocument.Parse(body.Length == 0 ? "{}" : body);
                    var r = doc.RootElement;
                    if (r.ValueKind == JsonValueKind.Object)
                    {
                        if (r.TryGetProperty("on", out var o) && o.ValueKind is JsonValueKind.True or JsonValueKind.False) on = o.GetBoolean();
                        if (r.TryGetProperty("exempt", out var x) && x.ValueKind == JsonValueKind.Array)
                            exempt = x.EnumerateArray().Where(v => v.ValueKind == JsonValueKind.String).Select(v => v.GetString()!).ToList();
                    }
                }
                catch (JsonException) { }
                if (on is null && exempt is null)
                {
                    await Respond(ctx, 400, "{\"ok\":false,\"error\":\"give on (true / false) and / or exempt (session names or ids)\"}");
                    return;
                }
                SetSupervisor(on, exempt);
                await Respond(ctx, 200, SupervisorJson());
                return;
            }

            // /snapshots… — Snapshots (Snapshots.cs). Same routes and answers as macOS.
            if (path == "/snapshots" || path.StartsWith("/snapshots/", StringComparison.Ordinal))
            {
                var (code, json) = SnapshotRoute(req.HttpMethod, path, body);
                await Respond(ctx, code, json);
                return;
            }

            // /rename — one session's own name, beside its project's ("Literally Apps SEO"); "" → back.
            // Same answers as macOS: {"ok":true,"id","label"}, 404 unknown, 400 without id.
            if (req.HttpMethod == "POST" && path == "/rename")
            {
                string? id = null, name = null;
                try
                {
                    using var doc = JsonDocument.Parse(body.Length == 0 ? "{}" : body);
                    var r = doc.RootElement;
                    if (r.TryGetProperty("id", out var i) && i.ValueKind == JsonValueKind.String) id = i.GetString();
                    if (r.TryGetProperty("name", out var n) && n.ValueKind == JsonValueKind.String) name = n.GetString();
                }
                catch (JsonException) { }
                if (string.IsNullOrEmpty(id))
                {
                    await Respond(ctx, 400, "{\"ok\":false,\"error\":\"give id and name\"}");
                    return;
                }
                if (Sessions.Info(id) is null || Sessions.Rename(id, name) is not { } label)
                {
                    await Respond(ctx, 404, "{\"ok\":false,\"error\":\"unknown session\"}");
                    return;
                }
                Log.Write($"rename: {id} → {label}");
                NotifyParked();
                await Respond(ctx, 200, JsonSerializer.Serialize(new { ok = true, id, label }));
                return;
            }

            // /close — the Zentrale ends running sessions: {"id"} | {"ids":[…]} | {"project":"…"}.
            if (req.HttpMethod == "POST" && path == "/close")
            {
                var (code, json) = Close(body);
                await Respond(ctx, code, json);
                return;
            }

            // /permission — the PermissionRequest hook long-polls; answered allow / deny / ask.
            if (req.HttpMethod == "POST" && path == "/permission")
            {
                var p = PermissionPayload.Decode(body);
                var decision = p is null ? Permission.Ask : await AskPermission(p);
                await Respond(ctx, 200, JsonSerializer.Serialize(new { decision }));
                return;
            }

            await Respond(ctx, 404, "{\"ok\":false}");
        }
        catch (Exception e)
        {
            Log.Write($"server error: {e.Message}");
            try { ctx.Response.Abort(); } catch { }
        }
    }

    // ---- turns (POST /turn) ------------------------------------------------------------

    // One /turn through the gate and the pipeline (or to the guest it asks): its reply, "" when
    // dropped. `turnId`: a hookless turn (docs/HOOKLESS.md) — cancelled meanwhile, it keeps nothing.
    private async Task<(string transcript, bool park, int wait, string resume)> Voice(TurnPayload turn, string id, string? turnId)
    {
        FireReminders(r => r.After == id);   // its turn ended: "wenn Shirts fertig ist"
        lock (_lock)   // together: no report slips in between and is wiped with what waited for it
        {
            ReclaimReports(id);
            Sessions.Queued(id, turn.Label ?? "", turn.Project, turn.Cwd);
        }
        Delivery.ClaimName(id, turn.Cwd);
        if (Sessions.Name(id) is { } own) turn.Label = own;   // its own name: announced, rung, shown
        // v7: <speak to="Max"> and Max is a guest of this session — the question goes to him
        // (Shares.cs), not through Sir's voice; it comes back here if he doesn't answer.
        if (turn.To is { Length: > 0 } to && turn.WantsListen && AskGuest is { } ask && Sessions.SharedGuest(id, to) is { } guest)
        {
            Sessions.SetAsking(id, guest.Name);
            GuestOutcome outcome;
            try { outcome = await ask(guest.Id, turn); }
            finally { Sessions.SetAsking(id, null); }
            if (outcome.Answer is { } answer)
            {
                Sessions.Finished(id, answer, false, 0);
                return (answer, false, 0, "");
            }
            turn = outcome.ForSir ?? turn;   // unanswered: Sir's voice, like any update
        }
        // Überwachungsmodus (Supervisor.cs): only the Zentrale's turn (and an exempt session's) is
        // voiced; any other is its report. The mod's Zentrale gets the reports on its presence; a
        // hook-carried turn takes them with its reply (nothing else may reach a busy hook-only session).
        var takesReports = false;
        if (_supervisor is { On: true } supervisor)
        {
            var label = Sessions.Describe(id)?.label ?? turn.SpokenLabel;
            if (Supervisor.IsZentrale(label, turn.Cwd, ZentraleDir())) takesReports = turnId is null;
            else if (!supervisor.Exempts(id, label)) return Report(turn, id, label, park: turnId is null);
        }
        using var hold = PhoneCall.Hold();   // released after the reply — never leaks on an error
        Interlocked.Increment(ref _queued);
        if (_turnGate.Busy)   // another turn is active → this one waits
            Notifier.Notify("Parley", $"Projekt {turn.SpokenLabel} wartet auf Antwort");
        var w = Enlist(id, turn: true, turnId, turn);   // older ones of this session are answered "" now
        var entered = await Enter(id, w);   // FIFO; hook connection stays open
        Interlocked.Decrement(ref _queued);
        bool reported;
        lock (_lock)   // let in, or reported meanwhile (SetSupervisor): one of the two, never both
        {
            reported = w.Reported;
            if (entered && !reported) w.Entered = true;
        }
        if (reported)   // the Überwachungsmodus came on while it waited: its report is in the inbox
        {
            Delist(id, w);
            if (entered) _turnGate.Release();
            return EndReported(turn, id, park: turnId is null);
        }
        if (!entered)   // a newer /turn of this session, or /close: no one listens for it
        {
            Delist(id, w);
            Sessions.Unqueued(id);
            Log.Write($"turn dropped ({turn.SpokenLabel}: a newer turn, cancelled, or closed)");
            return ("", false, 0, "");
        }
        (string transcript, bool park, int wait, string resume) r = ("", false, 0, "");
        try
        {
            Sessions.Activate(id, turn.Speak);
            r = await _runTurn(turn);
        }
        finally
        {
            Delist(id, w);
            if (turnId is not null && !Open(id, turnId)) r = ("", false, 0, "");   // cancelled: nothing of it stays
            if (takesReports || TakesReports(turn, id, turnId)) r = WithReports(r);   // (on by now: as well)
            Sessions.Finished(id, r.transcript, r.park, r.wait, r.resume, hostWait: turnId is not null);
            _turnGate.Release();
        }
        return r;
    }

    // ---- Überwachungsmodus (Supervisor.cs) -----------------------------------------------

    private static readonly HashSet<string> Talking = new() { "speaking", "listening", "transcribing", "queued" };
    private readonly object _zentraleStart = new();   // one start of the Zentrale at a time

    public bool SupervisorOn() => _supervisor.On;

    // The switch (the tray, POST /supervisor): on / off and who is exempt — what is null stays.
    public void SetSupervisor(bool? on, List<string>? exempt = null)
    {
        Supervisor? changed = null;
        var moved = new List<Waiter>();
        var zentrale = ZentraleDir();
        lock (_lock)
        {
            var old = _supervisor;
            var s = new Supervisor
            {
                On = on ?? old.On,
                Exempt = exempt?.Select(x => x.Trim()).Where(x => x.Length > 0).ToList() ?? old.Exempt,
            };
            if (s.On != old.On || !s.Exempt.SequenceEqual(old.Exempt))
            {
                _supervisor = changed = s;
                s.Save(Supervisor.FilePath);
            }
            // Switched on: turns already waiting for their voice go the new way too — reports, not
            // a queue for Sir. (One being voiced stays; the Zentrale's own and an exempt one wait on.)
            if (s.On && !old.On)
                foreach (var (key, list) in _waiters)
                {
                    var w = list.LastOrDefault(o => o.Turn);   // its newest: the older ones are dropped anyway
                    if (w is null || w.Entered || w.Reported || w.Payload is not { } turn || _closed.Contains(key)
                        || (w.TurnId is { } tid && !Open(key, tid))) continue;
                    var label = Sessions.Describe(key)?.label ?? turn.SpokenLabel;
                    if (Supervisor.IsZentrale(label, turn.Cwd, zentrale) || s.Exempts(key, label)) continue;
                    _reports.Add(Supervisor.Report(turn, key, Sessions.HasTasks(key)));
                    Log.Write($"supervisor: {label} waited for its voice — reports to the Zentrale instead ({(turn.WantsListen ? "asks" : "done")})");
                    w.Reported = true;
                    moved.Add(w);
                }
        }
        foreach (var w in moved) w.Drop.Cancel();   // outside the lock: continuations may run inline (Voice ends them)
        if (changed is not null)
        {
            Log.Write($"supervisor: {(changed.On ? "on" : "off")}{(changed.Exempt.Count == 0 ? "" : $" — exempt: {string.Join(", ", changed.Exempt)}")}");
            if (changed.On)
            {
                try { Zentrale.Ensure(Config.Load()); }
                catch (Exception e) { Log.Write($"zentrale: could not prepare its folder ({e.Message})"); }
            }
        }
        SyncSupervisor();
    }

    // The registry shows the mode in /sessions and marks the Zentrale's row (and how many of its
    // lines wait for Sir's call back).
    private void SyncSupervisor()
    {
        Sessions.SetSupervised(_supervisor.On, ZentraleDir());
        lock (_lock) Sessions.SetMissed(_missed.Count);
    }

    // {"ok":true,"on","exempt","zentrale" (its session, when it runs),"waiting" (reports in the
    // inbox),"missed" (lines kept for Sir's call back)}.
    private string SupervisorJson()
    {
        var s = _supervisor;
        var json = new Dictionary<string, object> { ["ok"] = true, ["on"] = s.On, ["exempt"] = s.Exempt };
        if (Sessions.InFolder(ZentraleDir()) is { } z) json["zentrale"] = z.Id;
        lock (_lock)
        {
            json["waiting"] = _reports.Count;
            json["missed"] = _missed.Count;
        }
        return JsonSerializer.Serialize(json);
    }

    // ---- what Sir missed (a call of the Zentrale he didn't take; Supervisor.cs, Missed) ----

    public int MissedCount
    {
        get { lock (_lock) return _missed.Count; }
    }

    /// Session `id` is the Zentrale; `supervised`: … and the Überwachungsmodus is on.
    public bool IsZentrale(string id, bool supervised = false) =>
        (!supervised || _supervisor.On) && Sessions.Info(id) is { } i && Supervisor.IsZentrale(i.Label, i.Cwd, ZentraleDir());

    /// The Zentrale's line is kept for Sir's call back; how many wait now. `ringAgain`: he asked
    /// to be rung again in that many seconds.
    public int AddMissed(TurnPayload turn, double? ringAgain = null)
    {
        int n;
        lock (_lock)
        {
            _missed.Add(new MissedLine { At = (DateTime.UtcNow - DateTime.UnixEpoch).TotalMilliseconds, Text = turn.Speak, Asks = turn.WantsListen });
            if (_missed.Count > Missed.Most) _missed.RemoveRange(0, _missed.Count - Missed.Most);
            Missed.Save(_missed, Missed.FilePath);
            n = _missed.Count;
            Sessions.SetMissed(n);
            if (ringAgain is { } seconds) _ringAgainAt = DateTime.UtcNow.AddSeconds(seconds);
        }
        Sessions.Reported(SessionKey(turn), turn.Speak);
        return n;
    }

    /// Sir is back: everything kept, as the one instruction for the Zentrale — and the list is
    /// empty again. null: nothing waited.
    public string? TakeMissed(string? said = null)
    {
        lock (_lock)
        {
            if (_missed.Count == 0) return null;
            var text = Missed.Instruction(_missed, said);
            _missed.Clear();
            _ringAgainAt = null;
            Missed.Save(_missed, Missed.FilePath);
            Sessions.SetMissed(0);
            return text;
        }
    }

    /// The call-back dialog rides the gate like the wake dialog (never over a line being voiced).
    /// `ring`: ring the phone first — the one ring Sir asked for. Not lined up twice: one may be
    /// at it and one more may wait.
    public void CallBack(bool ring = false)
    {
        if (Interlocked.CompareExchange(ref _callBackWaits, 1, 0) != 0) return;
        _ = Task.Run(async () =>
        {
            using var hold = PhoneCall.Hold();
            Interlocked.Increment(ref _queued);
            await _turnGate.WaitAsync();
            Volatile.Write(ref _callBackWaits, 0);
            try
            {
                Interlocked.Decrement(ref _queued);
                await _runTurn(new TurnPayload { Event = CallbackEvent, Speak = ring ? "ring" : "", Listen = false });
            }
            catch (Exception e) { Log.Write($"call back failed: {e.Message}"); }
            finally { _turnGate.Release(); }
        });
    }

    // POST /dispatch `from`: who asks ("Zentrale") — the session reads "[Auftrag von Zentrale] …"
    // and, while the mode is on, that its answer goes to the Zentrale (not in the Zentrale's own
    // folder, not an exempt session — the one the dispatch reaches, as Delivery.Dispatch picks it).
    private string Addressed(string instruction, string? from, string cwd, string? resume, string? name)
    {
        if (string.IsNullOrWhiteSpace(from)) return instruction;
        var supervisor = _supervisor;
        name = string.IsNullOrWhiteSpace(name) ? null : name.Trim();
        var here = resume is not null ? (Sessions.Running(resume).Alive ? resume : null)
            : name is not null ? Sessions.Named(name, cwd)
            : Sessions.InFolder(cwd)?.Id;
        var label = resume is not null && name is not null ? name   // Dispatch renames it so
            : (here is null ? null : Sessions.Describe(here)?.label) ?? name ?? "";
        var reportsBack = supervisor.On && !CwdPath.Same(cwd, ZentraleDir()) && !supervisor.Exempts(here ?? "", label);
        return Supervisor.Instruction(instruction, from, reportsBack);
    }

    // A session's turn while the mode is on: not voiced — its report waits for the Zentrale, the
    // session is answered empty at once and parks (`park`: its hook polls /wake; the mod's session
    // is parked by its presence), so it stays resumable and takes the Zentrale's /dispatch.
    private (string transcript, bool park, int wait, string resume) Report(TurnPayload turn, string id, string label, bool park)
    {
        var report = Supervisor.Report(turn, id, Sessions.HasTasks(id));
        var stale = new List<Waiter>();
        lock (_lock)
        {
            _reports.Add(report);
            if (id.Length > 0)   // as Enlist: this session's newest turn, though it never lines up
            {
                if (_waiters.TryGetValue(id, out var list)) stale.AddRange(list.Where(o => o.Turn));
                _parked.TryRemove(id, out _);
                _closed.Remove(id);
            }
        }
        foreach (var o in stale) o.Drop.Cancel();   // outside the lock: continuations may run inline
        Log.Write($"supervisor: {label} reports to the Zentrale ({(turn.WantsListen ? "asks" : "done")}) — not voiced");
        return EndReported(turn, id, park);
    }

    // Its report is in the inbox: the session's turn is over — shown with its line, parked.
    private (string transcript, bool park, int wait, string resume) EndReported(TurnPayload turn, string id, bool park)
    {
        Sessions.Reported(id, turn.Speak);
        Sessions.Finished(id, "", park, 0);
        NotifyParked();
        _ = Task.Run(() => FlushReports(start: true));   // off the reply's way: a start takes a moment
        return ("", park, 0, "");
    }

    // A hook-carried turn of the Zentrale while the mode is on: it takes the reports with its reply.
    private bool TakesReports(TurnPayload turn, string id, string? turnId) =>
        turnId is null && _supervisor.On
        && Supervisor.IsZentrale(Sessions.Describe(id)?.label ?? turn.SpokenLabel, turn.Cwd, ZentraleDir());

    // Hands the waiting reports to the Zentrale once it can take them: reachable, nothing else
    // waiting for it, and not talking to Sir right now (they follow his answer). Not running and
    // `start`: started, as a wake routed to it (its folder made when missing; the restart guard
    // allows no second one) — the reports wait here, without the 10-min limit of a dispatch.
    private void FlushReports(bool start = false)
    {
        bool missing;
        lock (_lock)
        {
            if (_reports.Count == 0) return;
            missing = FlushReportsLocked();
        }
        if (!missing) { NotifyParked(); return; }
        if (!start) return;
        lock (_zentraleStart)
        {
            try { Delivery.Dispatch(Zentrale.Ensure(Config.Load()), "", start: true); }
            catch (Exception e) { Log.Write($"zentrale: could not start it for its reports ({e.Message})"); }
        }
    }

    // Caller holds _lock. True: reports wait and no Zentrale runs.
    private bool FlushReportsLocked()
    {
        if (_reports.Count == 0) return false;
        if (Sessions.InFolder(ZentraleDir()) is not { } z) return true;
        if (!z.Deliverable || Sessions.HasPending(z.Id) || (_parked.TryGetValue(z.Id, out var hook) && hook.Pending is not null)
            || Sessions.Info(z.Id) is not { } info || Talking.Contains(info.State)) return false;
        var batch = string.Join("\n\n", _reports);
        Log.Write($"supervisor: {_reports.Count} report(s) → the Zentrale");
        _reports.Clear();
        _reportsOut = batch;
        DeliverLocked(z.Id, batch);
        return false;
    }

    // The batch is still untaken and the session moves on (its own turn, another instruction for
    // it, its end): back into the inbox — no report is lost to an overwrite. Caller holds _lock.
    private void ReclaimReports(string id)
    {
        if (_reportsOut is not { } batch) return;
        var hook = _parked.TryGetValue(id, out var p) && p.Pending == batch;   // the parked hook's copy
        if (hook) p!.Pending = null;
        if (!Sessions.TakeBack(id, batch) && !hook) return;                    // the mod's, not handed out yet
        _reports.Insert(0, batch);
        _reportsOut = null;
        Log.Write("supervisor: the Zentrale moved on before it took its reports — kept for it");
    }

    // A hook-carried turn of the Zentrale: the waiting reports ride back with its reply.
    // (An empty, unparked reply is a stale or ended hook's: nobody would read them.)
    private (string transcript, bool park, int wait, string resume) WithReports((string transcript, bool park, int wait, string resume) r)
    {
        lock (_lock)
        {
            if (_reports.Count == 0 || r.wait != 0 || !(r.park || r.transcript.Length > 0)) return r;
            var text = string.Join("\n\n", new[] { r.transcript }.Concat(_reports).Where(t => t.Length > 0));
            Log.Write($"supervisor: {_reports.Count} report(s) → the Zentrale (with its reply)");
            _reports.Clear();
            return (text, false, 0, r.resume);
        }
    }

    // Hookless: is `turnId` still this session's open turn (not cancelled, closed, or overtaken)?
    private bool Open(string id, string turnId)
    {
        lock (_lock) return _turns.TryGetValue(id, out var t) && t == turnId;
    }

    // A hookless turn's reply: a transcript is delivered, a wait runs on the host's timer, park
    // and silence deliver nothing (the turn closes — `awaiting` it answers unknown_turn).
    private void Settle(string id, string turnId, (string transcript, bool park, int wait, string resume) r)
    {
        lock (_lock)
        {
            if (!Open(id, turnId)) return;   // cancelled, a newer turn, closed: nothing of it goes out
            if (r.wait > 0)
            {
                _ = Task.Run(() => HostWait(id, turnId, r.wait));
                return;
            }
            _turns.Remove(id);
            if (r.transcript.Length > 0) DeliverLocked(id, r.transcript);
        }
        NotifyParked();
    }

    // "Warte X Minuten" without a hook to sleep: at its end waitResume is delivered — unless
    // Fortsetzen ended it first (EndWait delivered its own text), or a new turn / cancel / close.
    private async Task HostWait(string id, string turnId, int seconds)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < until && Sessions.HostWaiting(id) && Open(id, turnId)) await Task.Delay(1000);
        lock (_lock)
        {
            if (!Open(id, turnId)) return;
            _turns.Remove(id);
            if (Sessions.TakeWaitResume(id) is { } resume) DeliverLocked(id, resume);
        }
        NotifyParked();
    }

    // ---- shared sessions (Shares.cs) -----------------------------------------------------

    // v7: the share hub takes a guest's question (share id, turn) → his answer, or the turn for Sir.
    public Func<string, TurnPayload, Task<GuestOutcome>>? AskGuest;

    // A guest's words (or the note that he joined / left) for a session — as a routed instruction.
    public void DeliverRouted(string id, string instruction) => Deliver(id, instruction);

    // ---- Wiedervorlage (Reminders.cs) ----------------------------------------------------

    // A Wiedervorlage for Sir waits at the gate (a Fragerunde ends then, as for Sir's own timer).
    private int _remindersWaiting;
    public bool TimerQueued() => Sessions.TimerQueued() || Volatile.Read(ref _remindersWaiting) > 0;

    // Every 30 s (Program): what is due by time, or because its session is done.
    public void TickReminders()
    {
        SyncSupervisor();
        FireReminders(r => ReminderStore.IsDue(r, DateTime.UtcNow, Sessions.StateSince));
        FlushReports(start: true);
        var ring = false;   // "In 5 Min.": the one ring Sir asked for
        lock (_lock)
        {
            if (_ringAgainAt is { } at && at <= DateTime.UtcNow)
            {
                _ringAgainAt = null;
                ring = _missed.Count > 0;
            }
        }
        if (ring) CallBack(ring: true);
    }

    /// A session by id, spoken name / folder name (running first), or a past session's id.
    private (string? Id, string Label, string Cwd)? ResolveSession(string name)
    {
        if (Sessions.Info(name) is { } i) return (name, i.Label, i.Cwd);
        if (Sessions.Named(name) is { } id && Sessions.Info(id) is { } n) return (id, n.Label, n.Cwd);
        if (Transcript.IsSessionId(name) && Transcript.File(name) is { } f && Transcript.Summary(f) is { } p)
            return (name, Path.GetFileName(p.Cwd.TrimEnd('/', '\\')), CwdPath.Normalize(p.Cwd));
        return null;
    }

    private void FireReminders(Func<Reminder, bool> due)
    {
        foreach (var r in Reminders.Take(due, DateTime.UtcNow)) Hand(r);   // a recurring one stays, due again
    }

    // For Sir: spoken through the gate like an update. For a session: its instruction now if it
    // can take it, else by its folder — resuming that very session, or starting one.
    private void Hand(Reminder r)
    {
        if (r.ForSir)
        {
            Log.Write($"remind: Sir — {r.Text}");
            _ = Task.Run(async () =>
            {
                using var hold = PhoneCall.Hold();
                Interlocked.Increment(ref _queued);
                Interlocked.Increment(ref _remindersWaiting);
                await _turnGate.WaitAsync();
                Interlocked.Decrement(ref _remindersWaiting);
                try
                {
                    Interlocked.Decrement(ref _queued);
                    await _runTurn(new TurnPayload { Event = ReminderEvent, Speak = ReminderStore.Spoken(r), Listen = false });
                }
                catch (Exception e) { Log.Write($"reminder failed: {e.Message}"); }
                finally { _turnGate.Release(); }
            });
            return;
        }
        var text = ReminderStore.Instruction(r);
        if (r.Every is not null)
        {
            // Recurring: whoever runs in its folder now (a new session since, maybe) — started
            // when none does, and no round while it works or talks to Sir (the next comes anyway).
            (string Id, bool Deliverable)? live = null;
            if (r.Session is { } known && Sessions.Running(known).Alive) live = (known, Sessions.Running(known).Deliverable);
            else if (r.Cwd is { Length: > 0 } folder) live = Sessions.InFolder(folder);
            if (live is { } busy && Sessions.Info(busy.Id) is { } info && ReminderStore.SkipRound.Contains(info.State))
            {
                Log.Write($"remind: {r.Label} is busy ({info.State}) — this round is skipped");
                return;
            }
            if (live is { } target && target.Deliverable) Deliver(target.Id, text);
            else if (r.Cwd is { Length: > 0 } dir) Delivery.Dispatch(dir, text, true);
            else
            {
                Log.Write($"remind: {r.Label} is gone and has no folder — round dropped: {r.Text}");
                return;
            }
        }
        else if (r.Session is { } id && Sessions.Running(id).Deliverable) Deliver(id, text);
        else if (r.Cwd is { Length: > 0 } cwd)
            Delivery.Dispatch(cwd, text, true, r.Session is { } sid && Transcript.File(sid) is not null ? sid : null);
        else
        {
            Log.Write($"remind: {r.Label} is gone and has no folder — dropped: {r.Text}");
            return;
        }
        Log.Write($"remind: handed to {r.Label}");
        OnReminded?.Invoke(r);
    }

    // ---- Snapshots (Snapshots.cs) ------------------------------------------------------

    // One open at a time, as the server queue on macOS: opening twice starts nothing twice.
    private readonly object _snapshotGate = new();

    // The sessions running now (or just `ids`) under `name`; the same name again replaces it.
    // Folders kept normalized, as Reminders keep them.
    public Snapshot? SaveSnapshot(string name, IReadOnlyList<string>? ids = null)
    {
        var keep = ids is null ? Sessions.Live() : new List<(string Id, string Label, string Cwd)>();
        foreach (var id in ids ?? Array.Empty<string>())
            if (Sessions.Info(id) is { } i) keep.Add((id, i.Label, i.Cwd));
        var s = Snapshots.Save(name, keep.Select(k => (k.Id, k.Label, CwdPath.Normalize(k.Cwd))), DateTime.UtcNow);
        if (s is not null) Log.Write($"snapshot: saved {s.Name} — {string.Join(", ", s.Sessions.Select(x => x.Name))}");
        return s;
    }

    // Per session: still running → left alone; folder gone → missing; else started through
    // /dispatch's path — resumed when its transcript is still there, else a new one, same name.
    public (Snapshot Snapshot, List<SnapshotOutcome> Results)? OpenSnapshot(string id)
    {
        if (Snapshots.Find(id) is not { } s) return null;
        var outcomes = new List<SnapshotOutcome>();
        lock (_snapshotGate)
            foreach (var item in s.Sessions)
            {
                string result;
                if (Sessions.Running(item.Id).Alive) result = "running";
                else if (!Directory.Exists(item.Cwd)) result = "missing";
                else
                {
                    var resume = Transcript.IsSessionId(item.Id) && Transcript.File(item.Id) is not null ? item.Id : null;
                    var r = Delivery.Dispatch(item.Cwd, "", true, resume, item.Name);
                    // Failed (not even cmd came up) counts as a start, as on macOS, where the starter
                    // never reports back; Delivered / Pending / Starting: it runs, or is on the way.
                    result = r is not (DispatchResult.Started or DispatchResult.Failed) ? "running" : resume is not null ? "resumed" : "started";
                }
                outcomes.Add(new SnapshotOutcome(item.Id, item.Name, result));
            }
        Log.Write($"snapshot: opened {s.Name} — {string.Join(", ", outcomes.Select(o => $"{o.Name} {o.Result}"))}");
        return (s, outcomes);
    }

    public bool DeleteSnapshot(string id)
    {
        if (Snapshots.Delete(id) is not { } gone) return false;
        Log.Write($"snapshot: deleted {gone.Name}");
        return true;
    }

    // GET /snapshots, POST /snapshots {name, ids?}, /snapshots/open {id}, /snapshots/delete {id}.
    private (int, string) SnapshotRoute(string method, string path, string body)
    {
        var r = SnapshotStore.Request(body);
        switch (method, path)
        {
            case ("GET", "/snapshots"):
                return (200, JsonSerializer.Serialize(new { snapshots = Snapshots.Rows() }));
            case ("POST", "/snapshots"):
                if (SaveSnapshot(r?.Name ?? "", r?.Ids) is not { } saved)
                    return (400, "{\"ok\":false,\"error\":\"give a name; no running session to keep\"}");
                return (200, JsonSerializer.Serialize(new { ok = true, snapshot = SnapshotStore.Rows(new[] { saved })[0] }));
            case ("POST", "/snapshots/open"):
                if (OpenSnapshot(r?.Id ?? "") is not { } opened) return (404, "{\"ok\":false,\"error\":\"unknown snapshot\"}");
                return (200, JsonSerializer.Serialize(new { ok = true, name = opened.Snapshot.Name, results = SnapshotStore.Results(opened.Results) }));
            case ("POST", "/snapshots/delete"):
                return DeleteSnapshot(r?.Id ?? "") ? (200, "{\"ok\":true}") : (404, "{\"ok\":false,\"error\":\"unknown snapshot\"}");
            default:
                return (404, "{\"ok\":false,\"error\":\"not found\"}");
        }
    }

    // ---- closing sessions (POST /close) ------------------------------------------------

    // Ends a session's process: null = closing, else why not. The Zentrale's folder.
    public Func<string, string?> Closer = SessionCloser.Close;
    // A palette for the phone (POST /palette): its name and `palette` frame.
    public Action<string, string>? OnPalette;
    public Func<string> ZentraleDir = () => Zentrale.Dir(Config.Load());

    // Same answers as macOS: {"ok","closed":[{id,label}],"failed":[{id,error}]}. Each closed one
    // shows stopped and stays resumable (/past + /dispatch resume); the Zentrale never closes
    // itself. 200 when any closed, else the first failure's code: 404 unknown, 403 the Zentrale,
    // 409 not running / not closable here.
    public (int, string) Close(string body)
    {
        var ids = new List<string>();
        var project = "";
        var ended = "";
        try
        {
            using var doc = JsonDocument.Parse(body.Length == 0 ? "{}" : body);
            var r = doc.RootElement;
            if (r.TryGetProperty("ids", out var a) && a.ValueKind == JsonValueKind.Array)
                ids.AddRange(a.EnumerateArray().Where(v => v.ValueKind == JsonValueKind.String).Select(v => v.GetString()!));
            if (r.TryGetProperty("id", out var i) && i.ValueKind == JsonValueKind.String) ids.Add(i.GetString()!);
            if (r.TryGetProperty("project", out var p) && p.ValueKind == JsonValueKind.String) project = p.GetString()!.Trim();
            if (r.TryGetProperty("session_id", out var s) && s.ValueKind == JsonValueKind.String) ended = s.GetString()!;
        }
        catch (Exception) { return (400, "{\"ok\":false,\"error\":\"bad close payload\"}"); }
        if (ended.Length > 0 && ids.Count == 0 && project.Length == 0) return Ended(ended);
        if (project.Length > 0) ids.AddRange(Sessions.RunningNamed(project));
        if (ids.Count == 0)
            return project.Length == 0
                ? (400, "{\"ok\":false,\"error\":\"give id, ids or project\"}")
                : (404, "{\"ok\":false,\"error\":\"no running session of that project\"}");

        var closed = new List<object>();
        var failed = new List<object>();
        var codes = new List<int>();
        void Fail(string id, int code, string why) { failed.Add(new { id, error = why }); codes.Add(code); }
        var zentrale = ZentraleDir();
        foreach (var id in ids.Distinct())
        {
            if (Sessions.Info(id) is not { } s) { Fail(id, 404, "unknown session"); continue; }
            if (Zentrale.Is(s.Label, s.Cwd, zentrale)) { Fail(id, 403, "the Zentrale does not close itself"); continue; }
            if (s.State == "stopped") { Fail(id, 409, "already stopped"); continue; }
            if (Closer(id) is { } why) { Fail(id, 409, why); continue; }
            Sessions.Closed(id);
            List<Waiter> drop;
            lock (_lock)
            {
                _closed.Add(id);
                _turns.Remove(id);
                _parked.TryRemove(id, out _);
                drop = _waiters.TryGetValue(id, out var list) ? list.ToList() : new();
            }
            foreach (var d in drop) d.Drop.Cancel();   // its queued turns are answered "", dialogs dropped
            Log.Write($"close: {s.Label} ({id})");
            closed.Add(new { id, label = s.Label });
        }
        if (closed.Count > 0) NotifyParked();
        return (closed.Count > 0 ? 200 : codes[0], JsonSerializer.Serialize(new { ok = failed.Count == 0, closed, failed }));
    }

    // The mod's session.end ({"session_id"}, docs/HOOKLESS.md): the session is over by itself —
    // its queue, open turn and deliveries go (a turn being voiced records no more); nothing is
    // ended, the row ages out like any quiet session.
    private (int, string) Ended(string id)
    {
        List<Waiter> drop;
        lock (_lock)
        {
            ReclaimReports(id);   // the Zentrale ended with its reports untaken: kept for the next one
            _closed.Add(id);
            _turns.Remove(id);
            _parked.TryRemove(id, out _);
            drop = _waiters.TryGetValue(id, out var list) ? list.ToList() : new();
            Sessions.DropDeliveries(id);
        }
        foreach (var d in drop) d.Drop.Cancel();
        if (drop.Any(d => d.Entered && d.TurnId is not null)) AbandonTurn?.Invoke();
        Log.Write($"close: {id} ended (its queue and deliveries dropped)");
        NotifyParked();
        return (200, "{\"ok\":true}");
    }

    // ---- resuming sessions (tray, voice command, POST /resume) ------------------------

    // Resume without a dialog (tray / voice command). Unknown ids are a no-op.
    // During Sir's timer the session continues with what the wait would have given it.
    public void Resume(string id, string instruction)
    {
        var early = Sessions.EndWait(id);
        Deliver(id, instruction == ResumeInstruction ? early ?? instruction : instruction);
    }

    // Hand an instruction to a session: a parked hook picks it up on its next /wake poll
    // (≤3 s) and injects it as the next turn; an idle session's mod gets it as the reply to
    // its next /presence (≤2 s) and submits it as a prompt. Parked (its hook may be slow to
    // poll): both get it — whichever takes it first clears the other (/wake, /presence).
    // Every delivery goes this way: the mod has it until it acks (docs/HOOKLESS.md).
    private void Deliver(string id, string instruction)
    {
        lock (_lock) DeliverLocked(id, instruction);
        NotifyParked();
    }

    // Caller holds _lock.
    private void DeliverLocked(string id, string instruction)
    {
        Prune();
        // (Asked first: taking an untaken batch of reports back empties its hook's copy.)
        var parked = _parked.TryGetValue(id, out var p) && (p.Pending is not null || Sessions.IsParked(id));
        ReclaimReports(id);   // not overwritten by this one: it goes out again later
        if (parked)
        {
            p!.Pending = instruction;
            Sessions.SetPending(id, instruction);
            Sessions.WakeQueued(id);
        }
        else Sessions.SetPending(id, instruction);
    }

    // POST /resume and the relay's `resume` frame (docs/IPHONE.md): the voice dialog for a
    // resumable session. False = unknown or not resumable (atomic: a double click gets false).
    // A Fortsetzen arrived just now (the call Sir started for it is not a call to greet).
    private DateTime _resumedAt = DateTime.MinValue;
    public bool ResumedRecently() => DateTime.UtcNow - _resumedAt < TimeSpan.FromSeconds(5);

    public bool StartResume(string id)
    {
        if (id.Length == 0 || !Sessions.CanResume(id)) return false;   // as macOS: nothing ends for a no
        _resumedAt = DateTime.UtcNow;
        // During Sir's timer: no dialog — the wait ends now and the session reports when done.
        if (Sessions.EndWait(id) is { } early)
        {
            Log.Write($"resume: {id} — Sir ends the wait early");
            Deliver(id, early);
            return true;
        }
        if (!Sessions.TryQueueResume(id)) return false;
        _ = Task.Run(() => RunResumeDialog(id));
        return true;
    }

    // The POST /resume dialog (pre-recorded line → beep → record → transcribe) waits at the
    // turn gate like any turn; its transcript ("" → ResumeInstruction) is delivered after.
    private async Task RunResumeDialog(string id)
    {
        var info = Sessions.Describe(id);
        var (label, project) = info ?? ("", "");
        var turn = new TurnPayload { Event = ResumeEvent, SessionId = id, Project = project, Label = label, Listen = true };
        using var hold = PhoneCall.Hold();
        Interlocked.Increment(ref _queued);
        var w = Enlist(id, turn: false);
        var entered = await Enter(id, w);
        Interlocked.Decrement(ref _queued);
        Delist(id, w);
        if (!entered) return;   // closed meanwhile: nothing to resume
        var transcript = "";
        try
        {
            Sessions.Activate(id, null);
            transcript = (await _runTurn(turn)).transcript;
        }
        catch (Exception e) { Log.Write($"resume dialog failed: {e.Message}"); }
        finally
        {
            Sessions.ResumeFinished(id, transcript.Length > 0);
            Deliver(id, transcript.Length > 0 ? transcript : ResumeInstruction);
            _turnGate.Release();
        }
    }

    // ---- iPhone: wake word, permission questions (docs/IPHONE.md, v2) ------------------

    // The phone heard "Hey Parley": only in a call while nothing is queued or voiced (the hold
    // is taken atomically with that check) — then greeting → listen → route at the gate.
    public bool StartWake()
    {
        var hold = PhoneCall.HoldIfIdle();
        if (hold is null)
        {
            Log.Write("wake ignored (no call, or Parley is busy)");
            return false;
        }
        _ = Task.Run(() => RunWake(hold));
        return true;
    }

    // The tray's "Anrufen": the same dialog on the PC's speaker and mic, when nothing else runs.
    public bool StartLocalWake()
    {
        if (PhoneCall.Away || PhoneCall.Active || QueuedTurns > 0 || _turnGate.Busy)
        {
            Log.Write("wake ignored (Unterwegs, in a call, or Parley is busy)");
            return false;
        }
        _ = Task.Run(() => RunWake(null));
        return true;
    }

    private async Task RunWake(IDisposable? hold)
    {
        using (hold)
        {
            Interlocked.Increment(ref _queued);
            await _turnGate.WaitAsync();
            try
            {
                Interlocked.Decrement(ref _queued);
                await _runTurn(new TurnPayload { Event = WakeEvent, Listen = true });
            }
            catch (Exception e) { Log.Write($"wake failed: {e.Message}"); }
            finally { _turnGate.Release(); }
        }
    }

    // A session Parley doesn't know (voice mode off) → ask at once. Else the question waits at
    // the gate like a turn; the request is answered within PermissionHold no matter what — a
    // question still running then finishes in the background (the hook already got "ask").
    // The Wachhund asks Sir (at the PC / on a call); a yes hands the session the hint — the mod
    // delivers it at once, Claude Code reads it at its next step, mid-turn. As macOS.
    public void Watchdog(string id, string label, string question, string hint)
    {
        _ = Task.Run(async () =>
        {
            var turn = new TurnPayload { Event = WatchdogEvent, SessionId = id, Label = label, Project = label, Speak = question, Listen = true };
            string transcript;
            using (PhoneCall.Hold())
            {
                await _turnGate.WaitAsync();
                try
                {
                    Sessions.Activate(id, null);
                    transcript = (await _runTurn(turn)).transcript;
                }
                catch (Exception e)
                {
                    Log.Write($"watchdog question failed: {e.Message}");
                    return;
                }
                finally
                {
                    Sessions.Released(id);
                    _turnGate.Release();
                }
            }
            if (Permission.Decide(transcript) != Permission.Allow)
            {
                Log.Write($"watchdog: {label} — Sir lets it run");
                return;
            }
            Log.Write($"watchdog: hint to {label}");
            Resume(id, hint);
        });
    }

    // No answer by voice: on Windows the on-screen prompt decides ("ask"). The Linux host is
    // headless — nobody sits at that screen and the session would hang at it — so there it is a no.
    private static string Unanswered => OperatingSystem.IsWindows() ? Permission.Ask : Permission.Deny;

    private async Task<string> AskPermission(PermissionPayload p)
    {
        var id = p.SessionId ?? "";
        var info = id.Length > 0 ? Sessions.Describe(id) : null;
        if (info is null)
        {
            Log.Write("permission: unknown session → ask");
            return Permission.Ask;
        }
        var (label, project) = info.Value;
        if (project.Length == 0) project = Path.GetFileName((p.Cwd ?? "").TrimEnd('/', '\\'));
        var spoken = label.Length > 0 ? label : project;
        var tool = p.ToolName ?? "";
        var deadline = DateTime.UtcNow + PermissionHold;
        var turn = new TurnPayload
        {
            Event = PermissionEvent, SessionId = id, Cwd = p.Cwd ?? "", Project = project, Label = spoken,
            Speak = Permission.Question(spoken, tool, p.ToolInput), Listen = true, Deadline = deadline,
        };
        Sessions.MarkQueued(id);   // shown as queued until its question is asked
        var job = Task.Run<string?>(async () =>
        {
            using var hold = PhoneCall.Hold();
            Interlocked.Increment(ref _queued);
            var w = Enlist(id, turn: false);
            var entered = false;
            try
            {
                var wait = deadline - DateTime.UtcNow;
                entered = await Enter(id, w, wait > TimeSpan.Zero ? wait : TimeSpan.Zero);
            }
            finally { Interlocked.Decrement(ref _queued); Delist(id, w); }
            if (!entered)   // the gate stayed busy until the deadline, or the session was closed
            {
                Sessions.Unqueued(id);
                return null;
            }
            try
            {
                Sessions.Activate(id, null);
                return (await _runTurn(turn)).transcript;
            }
            catch (Exception e)
            {
                Log.Write($"permission question failed: {e.Message}");
                return "";
            }
            finally
            {
                Sessions.Released(id);
                _turnGate.Release();
            }
        });
        var left = deadline - DateTime.UtcNow;
        if (await Task.WhenAny(job, Task.Delay(left > TimeSpan.Zero ? left : TimeSpan.Zero)) != job)
        {
            Log.Write($"permission: {tool} for {spoken} → {Unanswered} (no answer within {(int)PermissionHold.TotalSeconds} s)");
            return Unanswered;
        }
        var transcript = await job;
        var decision = transcript is null ? Permission.Ask : Permission.Decide(transcript);
        if (decision == Permission.Ask) decision = Unanswered;
        Log.Write($"permission: {tool} for {spoken} → {decision}");
        return decision;
    }

    // Resumable (parked) sessions, for the tray and the voice resume command.
    public List<ParkedInfo> ResumableList() => Sessions.ResumableList();

    // Line up at the gate for session `id`. A /turn drops the older /turns of that session still
    // waiting (their hooks are gone or moved on), and its parked entry; it revives a closed one.
    private Waiter Enlist(string id, bool turn, string? turnId = null, TurnPayload? payload = null)
    {
        var w = new Waiter { Turn = turn, TurnId = turnId, Payload = payload };
        var drop = new List<Waiter>();
        lock (_lock)
        {
            if (!_waiters.TryGetValue(id, out var list)) _waiters[id] = list = new();
            if (turn && id.Length > 0)   // no session key (neither id nor pane): nothing to match
            {
                drop.AddRange(list.Where(o => o.Turn));
                _parked.TryRemove(id, out _);
                _closed.Remove(id);
            }
            list.Add(w);
        }
        _atGate.AddOrUpdate(id, 1, (_, n) => n + 1);
        foreach (var o in drop) o.Drop.Cancel();   // outside the lock: continuations may run inline
        return w;
    }

    // Wait for the gate (FIFO): false = dropped (or `timeout` passed) before it was this one's turn.
    private async Task<bool> Enter(string id, Waiter w, TimeSpan? timeout = null)
    {
        try { return await _turnGate.WaitAsync(timeout ?? Timeout.InfiniteTimeSpan, w.Drop.Token); }
        finally { _atGate.AddOrUpdate(id, 0, (_, n) => Math.Max(0, n - 1)); }
    }

    private void Delist(string id, Waiter w)
    {
        lock (_lock)
            if (_waiters.TryGetValue(id, out var list) && list.Remove(w) && list.Count == 0) _waiters.Remove(id);
    }

    // Caller holds _lock.
    private void Prune()
    {
        var cutoff = DateTime.UtcNow.AddSeconds(-90);
        foreach (var kv in _parked.Where(kv => kv.Value.LastSeen <= cutoff).ToList())
            _parked.TryRemove(kv.Key, out _);
    }

    private void NotifyParked() { try { OnParkedChanged?.Invoke(ResumableList()); } catch { } }

    private static string TurnJson(string transcript, bool park, int wait, string resume, bool end = false) =>
        JsonSerializer.Serialize(new WireReply(transcript, park, wait, resume, end ? true : null));

    // `end` only on /wake, and only when set: the hook stops polling and finishes.
    private sealed record WireReply(
        [property: JsonPropertyName("transcript")] string Transcript,
        [property: JsonPropertyName("park")] bool Park,
        [property: JsonPropertyName("wait")] int Wait,
        [property: JsonPropertyName("resume")] string Resume,
        [property: JsonPropertyName("end"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] bool? End);

    private static async Task Respond(HttpListenerContext ctx, int status, string json)
    {
        var bytes = Encoding.UTF8.GetBytes(json);
        ctx.Response.StatusCode = status;
        ctx.Response.ContentType = "application/json";
        ctx.Response.ContentLength64 = bytes.Length;
        await ctx.Response.OutputStream.WriteAsync(bytes);
        ctx.Response.Close();
    }
}

// A lock taken first come, first served (SemaphoreSlim promises no order): turns are voiced
// in the order their hooks arrived. Release hands it straight to the next waiter.
public sealed class FifoGate
{
    private readonly object _lock = new();
    private readonly LinkedList<TaskCompletionSource<bool>> _waiters = new();
    private bool _held;

    public bool Busy { get { lock (_lock) return _held; } }

    public Task WaitAsync() => WaitAsync(Timeout.InfiniteTimeSpan);

    // False = `timeout` passed or `cancel` fired before this one was let in.
    public async Task<bool> WaitAsync(TimeSpan timeout, CancellationToken cancel = default)
    {
        LinkedListNode<TaskCompletionSource<bool>> node;
        lock (_lock)
        {
            if (!_held) { _held = true; return true; }
            if (timeout == TimeSpan.Zero || cancel.IsCancellationRequested) return false;
            node = _waiters.AddLast(new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously));
        }
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        await Task.WhenAny(node.Value.Task, Task.Delay(timeout, stop.Token));
        stop.Cancel();   // the delay's timer, if it is still running
        lock (_lock)
        {
            if (node.List is null) return true;   // handed over (maybe just now)
            _waiters.Remove(node);
            return false;
        }
    }

    public void Release()
    {
        lock (_lock)
        {
            if (_waiters.First is { } next) { _waiters.RemoveFirst(); next.Value.SetResult(true); }   // stays held
            else _held = false;
        }
    }
}

// Live turn state for GET /status, 1:1 with macOS: the phase of the turn being voiced and
// a rolling window of audio levels (TTS out while speaking, mic in while listening), 0…1.
// Polled ~10×/s by the Claude Code mod to draw a real level meter.
public static class LiveStatus
{
    private static readonly object Gate = new();
    private static string _phase = "idle", _session = "";
    private static readonly float[] Levels = new float[32];

    public static void Begin(string session) { lock (Gate) { _session = session; _phase = "speaking"; } }
    public static string Phase() { lock (Gate) return _phase; }
    public static void Set(string phase) { lock (Gate) _phase = phase; }
    public static void Push(float level)
    {
        lock (Gate)
        {
            Array.Copy(Levels, 1, Levels, 0, Levels.Length - 1);
            Levels[^1] = Math.Clamp(level, 0f, 1f);
        }
    }

    public static string Json()
    {
        lock (Gate)
            return JsonSerializer.Serialize(new
            {
                phase = _phase,
                session = _session,
                levels = Levels.Select(l => MathF.Round(l, 2)),
            });
    }
}
