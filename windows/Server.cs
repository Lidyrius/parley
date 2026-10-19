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
// /dispatch, /permission, /snapshots… as on macOS. Everything that voices or listens holds PhoneCall from
// the moment it queues, so an iPhone in a call knows Parley is busy (docs/IPHONE.md, v2).
public sealed class Server
{
    private readonly HttpListener _listener = new();
    private readonly SemaphoreSlim _turnGate = new(1, 1);   // serializes the pipeline
    private readonly Func<TurnPayload, Task<(string transcript, bool park, int wait, string resume)>> _runTurn;
    private readonly Action _onReady;
    private int _queued;

    public int QueuedTurns => Volatile.Read(ref _queued);

    // Parked (paused-but-resumable) sessions. Their Stop hook short-polls /wake; we hand
    // back a pending instruction to wake them — no keystrokes. Keyed by session key.
    private sealed class Parked { public string Label = "", Project = ""; public string? Pending; public DateTime LastSeen; }
    private readonly ConcurrentDictionary<string, Parked> _parked = new();
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

    // Wiedervorlagen (Reminders.cs), kept in reminders.json; a handed-over one → OnReminded.
    public ReminderStore Reminders { get; } = new(Path.Combine(Config.Dir, "reminders.json"));
    public Action<Reminder>? OnReminded;
    // Snapshots (Snapshots.cs), kept in snapshots.json beside them.
    public SnapshotStore Snapshots { get; } = new(Path.Combine(Config.Dir, "snapshots.json"));

    // POST /permission is answered within this — the hook waits ≤ 120 s; a few seconds spare.
    public static readonly TimeSpan PermissionHold = TimeSpan.FromSeconds(115);

    // Routing, POST /dispatch and instructions waiting for a session's first presence.
    public Delivery Delivery { get; }

    // Sessions are keyed by the agent's session_id; the tmux pane only as a fallback.
    public static string SessionKey(TurnPayload t) => string.IsNullOrEmpty(t.SessionId) ? t.TmuxPane : t.SessionId;

    public Server(Func<TurnPayload, Task<(string, bool, int, string)>> runTurn, Action onReady)
    {
        _runTurn = runTurn;
        _onReady = onReady;
        Delivery = new Delivery(Sessions, (id, instruction) => Deliver(id, instruction));
        Sessions.ReminderRows = () => Reminders.Rows();
        Sessions.SnapshotRows = () => Snapshots.Rows();
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
                await Respond(ctx, 200, "{\"ok\":true}");
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
                FireReminders(r => r.After == id);   // its turn ended: "wenn Shirts fertig ist"
                Sessions.Queued(id, turn.Label ?? "", turn.Project, turn.Cwd);
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
                        await Respond(ctx, 200, TurnJson(answer, false, 0, ""));
                        return;
                    }
                    turn = outcome.ForSir ?? turn;   // unanswered: Sir's voice, like any update
                }
                using var hold = PhoneCall.Hold();   // released after the reply — never leaks on an error
                Interlocked.Increment(ref _queued);
                if (_turnGate.CurrentCount == 0)   // another turn is active → this one waits
                    Notifier.Notify("Parley", $"Projekt {turn.SpokenLabel} wartet auf Antwort");
                await _turnGate.WaitAsync();   // FIFO-ish serialization; hook connection stays open
                (string transcript, bool park, int wait, string resume) r = ("", false, 0, "");
                try
                {
                    Interlocked.Decrement(ref _queued);
                    Sessions.Activate(id, turn.Speak);
                    r = await _runTurn(turn);
                }
                finally
                {
                    Sessions.Finished(id, r.transcript, r.park, r.wait, r.resume);
                    _turnGate.Release();
                }
                await Respond(ctx, 200, TurnJson(r.transcript, r.park, r.wait, r.resume));
                return;
            }

            // /wake — a parked session's Stop hook short-polls this. Answer immediately with
            // any pending resume instruction (consuming it), else empty; (re)register so the
            // session stays listed as resumable.
            if (req.HttpMethod == "POST" && path == "/wake")
            {
                var turn = TurnPayload.Decode(body);
                var pending = "";
                if (turn is not null)
                {
                    var key = SessionKey(turn);
                    var p = _parked.GetOrAdd(key, _ => new Parked());
                    p.Label = turn.SpokenLabel;
                    p.Project = turn.Project;
                    p.LastSeen = DateTime.UtcNow;
                    pending = Interlocked.Exchange(ref p.Pending, null) ?? "";
                    Sessions.WakePoll(key, turn.Label ?? "", turn.Project, pending.Length > 0, turn.Cwd);
                    Delivery.ClaimName(key, turn.Cwd);
                    Prune();
                    NotifyParked();
                }
                await Respond(ctx, 200, TurnJson(pending, false, 0, ""));
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
                var instruction = Sessions.Presence(presence.SessionId, presence.Label ?? "", project,
                    presence.State ?? "idle", presence.Usage, presence.Tasks, presence.Host, presence.Cwd);
                // A session started for an instruction (POST /dispatch, a wake routed to the
                // Zentrale) gets it on the first presence from its folder.
                Delivery.ClaimName(presence.SessionId, presence.Cwd);
                if (instruction is null && Delivery.TakePending(presence.Cwd, presence.SessionId) is { } waiting)
                {
                    instruction = waiting;
                    Sessions.MarkInjected(presence.SessionId);
                    Log.Write($"dispatch: delivered the waiting instruction to {project}");
                }
                NotifyParked();
                await Respond(ctx, 200, instruction is null ? "{}" : JsonSerializer.Serialize(new { instruction }));
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
                var result = Delivery.Dispatch(cwd, (d.Instruction ?? "").Trim(), d.Start ?? true, d.Resume, d.Name);
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
                Log.Write($"remind: for {rem.Label}, {(rem.At is { } at ? $"at {at:o}" : $"after {rem.AfterLabel}")}");
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
    public void TickReminders() => FireReminders(r => ReminderStore.IsDue(r, DateTime.UtcNow, Sessions.StateSince));

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
        foreach (var r in Reminders.Take(due)) Hand(r);
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
        if (r.Session is { } id && Sessions.Running(id).Deliverable) Deliver(id, text);
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
        try
        {
            using var doc = JsonDocument.Parse(body.Length == 0 ? "{}" : body);
            var r = doc.RootElement;
            if (r.TryGetProperty("ids", out var a) && a.ValueKind == JsonValueKind.Array)
                ids.AddRange(a.EnumerateArray().Where(v => v.ValueKind == JsonValueKind.String).Select(v => v.GetString()!));
            if (r.TryGetProperty("id", out var i) && i.ValueKind == JsonValueKind.String) ids.Add(i.GetString()!);
            if (r.TryGetProperty("project", out var p) && p.ValueKind == JsonValueKind.String) project = p.GetString()!.Trim();
        }
        catch (Exception) { return (400, "{\"ok\":false,\"error\":\"bad close payload\"}"); }
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
            _parked.TryRemove(id, out _);
            Log.Write($"close: {s.Label} ({id})");
            closed.Add(new { id, label = s.Label });
        }
        if (closed.Count > 0) NotifyParked();
        return (closed.Count > 0 ? 200 : codes[0], JsonSerializer.Serialize(new { ok = failed.Count == 0, closed, failed }));
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
    // its next /presence (≤2 s) and submits it as a prompt.
    private void Deliver(string id, string instruction)
    {
        if (Sessions.ParkedHookAlive(id))
        {
            var p = _parked.GetOrAdd(id, _ => new Parked());
            p.Pending = instruction;
            p.LastSeen = DateTime.UtcNow;
            Sessions.WakeQueued(id);
        }
        else Sessions.SetPending(id, instruction);
        NotifyParked();
    }

    // POST /resume and the relay's `resume` frame (docs/IPHONE.md): the voice dialog for a
    // resumable session. False = unknown or not resumable (atomic: a double click gets false).
    // A Fortsetzen arrived just now (the call Sir started for it is not a call to greet).
    private DateTime _resumedAt = DateTime.MinValue;
    public bool ResumedRecently() => DateTime.UtcNow - _resumedAt < TimeSpan.FromSeconds(5);

    public bool StartResume(string id)
    {
        if (id.Length > 0) _resumedAt = DateTime.UtcNow;
        // During Sir's timer: no dialog — the wait ends now and the session reports when done.
        if (id.Length > 0 && Sessions.EndWait(id) is { } early)
        {
            Log.Write($"resume: {id} — Sir ends the wait early");
            Deliver(id, early);
            return true;
        }
        if (id.Length == 0 || !Sessions.TryQueueResume(id)) return false;
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
        await _turnGate.WaitAsync();
        var transcript = "";
        try
        {
            Interlocked.Decrement(ref _queued);
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

    private async Task RunWake(IDisposable hold)
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
        var job = Task.Run<string?>(async () =>
        {
            using var hold = PhoneCall.Hold();
            Interlocked.Increment(ref _queued);
            var entered = false;
            try
            {
                var wait = deadline - DateTime.UtcNow;
                entered = await _turnGate.WaitAsync(wait > TimeSpan.Zero ? wait : TimeSpan.Zero);
            }
            finally { Interlocked.Decrement(ref _queued); }
            if (!entered) return null;   // the gate stayed busy until the deadline
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
            Log.Write($"permission: {tool} for {spoken} → ask (no answer within {(int)PermissionHold.TotalSeconds} s)");
            return Permission.Ask;
        }
        var transcript = await job;
        var decision = transcript is null ? Permission.Ask : Permission.Decide(transcript);
        Log.Write($"permission: {tool} for {spoken} → {decision}");
        return decision;
    }

    // Resumable (parked) sessions, for the tray and the voice resume command.
    public List<ParkedInfo> ResumableList() => Sessions.ResumableList();

    private void Prune()
    {
        var cutoff = DateTime.UtcNow.AddSeconds(-90);
        foreach (var kv in _parked.Where(kv => kv.Value.LastSeen <= cutoff).ToList())
            _parked.TryRemove(kv.Key, out _);
    }

    private void NotifyParked() { try { OnParkedChanged?.Invoke(ResumableList()); } catch { } }

    private static string TurnJson(string transcript, bool park, int wait, string resume) =>
        JsonSerializer.Serialize(new WireReply(transcript, park, wait, resume));

    private sealed record WireReply(
        [property: JsonPropertyName("transcript")] string Transcript,
        [property: JsonPropertyName("park")] bool Park,
        [property: JsonPropertyName("wait")] int Wait,
        [property: JsonPropertyName("resume")] string Resume);

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
