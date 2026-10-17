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
// /dispatch, /permission as on macOS. Everything that voices or listens holds PhoneCall from
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
                Sessions.Queued(id, turn.Label ?? "", turn.Project, turn.Cwd);
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
                    Sessions.Finished(id, r.transcript, r.park, r.wait);
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
                if (instruction is null && Delivery.TakePending(presence.Cwd) is { } waiting)
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
            // for that session behind any running turn. Only parked / idle-with-mod sessions.
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

            // /dispatch — the Zentrale (docs/IPHONE.md, v2): deliver an instruction to the session
            // in a folder, starting one there when none runs. A relative cwd lives under projectsDir.
            if (req.HttpMethod == "POST" && path == "/dispatch")
            {
                var d = DispatchPayload.Decode(body);
                var cwd = d is null ? null : CwdPath.Resolve(d.Cwd, Config.Load().ProjectsDir);
                if (d is null || cwd is null)
                {
                    await Respond(ctx, 400, "{\"ok\":false,\"error\":\"cwd must be an absolute path\"}");
                    return;
                }
                if (!Directory.Exists(cwd))
                {
                    await Respond(ctx, 404, "{\"ok\":false,\"error\":\"no such folder\"}");
                    return;
                }
                var result = Delivery.Dispatch(cwd, (d.Instruction ?? "").Trim(), d.Start ?? true);
                var ok = result != DispatchResult.Failed;
                await Respond(ctx, ok ? 200 : 500, JsonSerializer.Serialize(new
                {
                    ok,
                    result = result.ToString().ToLowerInvariant(),
                    error = ok ? null : "could not start a session",
                }));
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

    // ---- resuming sessions (tray, voice command, POST /resume) ------------------------

    // Resume without a dialog (tray / voice command). Unknown ids are a no-op.
    public void Resume(string id, string instruction) => Deliver(id, instruction);

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
    public bool StartResume(string id)
    {
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

    // Parked or idle-with-mod sessions, for the tray and the voice resume command.
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
