using System.Collections.Concurrent;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Parley;

// Loopback HTTP server, same contract as macOS: the Claude Code Stop hook LONG-POLLS
// POST /turn and blocks until the voice reply is transcribed. Turns are serialized —
// one is spoken/recorded at a time; concurrent hooks queue FIFO (their connections
// stay open). GET /health, /status, /sessions and POST /ready, /wake, /presence, /resume
// as on macOS.
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

    // Sessions are keyed by the agent's session_id; the tmux pane only as a fallback.
    public static string SessionKey(TurnPayload t) => string.IsNullOrEmpty(t.SessionId) ? t.TmuxPane : t.SessionId;

    public Server(Func<TurnPayload, Task<(string, bool, int, string)>> runTurn, Action onReady)
    {
        _runTurn = runTurn;
        _onReady = onReady;
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
                Sessions.Queued(id, turn.Label ?? "", turn.Project);
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
                    Sessions.WakePoll(key, turn.Label ?? "", turn.Project, pending.Length > 0);
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
                    presence.State ?? "idle", presence.Usage, presence.Tasks, presence.Host);
                NotifyParked();
                await Respond(ctx, 200, instruction is null ? "{}" : JsonSerializer.Serialize(new { instruction }));
                return;
            }

            // /resume — the mod's resume button: answer at once, then run the short voice dialog
            // for that session behind any running turn. Only parked / idle-with-mod sessions.
            if (req.HttpMethod == "POST" && path == "/resume")
            {
                var id = ResumePayload.Decode(body)?.Id ?? "";
                if (id.Length == 0 || !Sessions.TryQueueResume(id))   // atomic: a double click gets 404
                {
                    await Respond(ctx, 404, "{\"ok\":false}");
                    return;
                }
                _ = Task.Run(() => RunResumeDialog(id));
                await Respond(ctx, 200, "{\"ok\":true}");
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

    // The POST /resume dialog (pre-recorded line → beep → record → transcribe) waits at the
    // turn gate like any turn; its transcript ("" → ResumeInstruction) is delivered after.
    private async Task RunResumeDialog(string id)
    {
        var info = Sessions.Describe(id);
        var (label, project) = info ?? ("", "");
        var turn = new TurnPayload { Event = ResumeEvent, SessionId = id, Project = project, Label = label, Listen = true };
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
