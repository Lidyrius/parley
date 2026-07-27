using System.Collections.Concurrent;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Parley;

// Loopback HTTP server, same contract as macOS: the Claude Code Stop hook LONG-POLLS
// POST /turn and blocks until the voice reply is transcribed. Turns are serialized —
// one is spoken/recorded at a time; concurrent hooks queue FIFO (their connections
// stay open). GET /health and POST /ready as on macOS.
public sealed class Server
{
    private readonly HttpListener _listener = new();
    private readonly SemaphoreSlim _turnGate = new(1, 1);   // serializes the pipeline
    private readonly Func<TurnPayload, Task<(string transcript, bool park, int wait, string resume)>> _runTurn;
    private readonly Action _onReady;
    private int _queued;

    public int QueuedTurns => Volatile.Read(ref _queued);

    // Parked (paused-but-resumable) sessions. Their Stop hook short-polls /wake; we hand
    // back a pending instruction to wake them — no keystrokes. Keyed by route key.
    private sealed class Parked { public string Label = "", Project = ""; public string? Pending; public DateTime LastSeen; }
    private readonly ConcurrentDictionary<string, Parked> _parked = new();
    public event Action<List<ParkedInfo>>? OnParkedChanged;

    public readonly record struct ParkedInfo(string Id, string Label, string Project);

    private static string RouteKey(TurnPayload t) => string.IsNullOrEmpty(t.TmuxPane) ? t.SessionId : t.TmuxPane;

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
                Interlocked.Increment(ref _queued);
                if (_turnGate.CurrentCount == 0)   // another turn is active → this one waits
                    Notifier.Notify("Parley", $"Projekt {turn.SpokenLabel} wartet auf Antwort");
                await _turnGate.WaitAsync();   // FIFO-ish serialization; hook connection stays open
                (string transcript, bool park, int wait, string resume) r;
                try
                {
                    Interlocked.Decrement(ref _queued);
                    r = await _runTurn(turn);
                }
                finally { _turnGate.Release(); }
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
                    var key = RouteKey(turn);
                    var p = _parked.GetOrAdd(key, _ => new Parked());
                    p.Label = turn.SpokenLabel;
                    p.Project = turn.Project;
                    p.LastSeen = DateTime.UtcNow;
                    pending = Interlocked.Exchange(ref p.Pending, null) ?? "";
                    Prune();
                    NotifyParked();
                }
                await Respond(ctx, 200, TurnJson(pending, false, 0, ""));
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

    // Queue an instruction for a parked session; its next /wake poll (≤3s) injects it as
    // the next turn, resuming the session. No-op if the id is unknown.
    public void Wake(string id, string instruction)
    {
        if (_parked.TryGetValue(id, out var p)) { p.Pending = instruction; p.LastSeen = DateTime.UtcNow; }
    }

    public List<ParkedInfo> ParkedList()
    {
        var cutoff = DateTime.UtcNow.AddSeconds(-90);
        return _parked.Where(kv => kv.Value.LastSeen > cutoff)
            .Select(kv => new ParkedInfo(kv.Key, kv.Value.Label, kv.Value.Project))
            .OrderBy(p => p.Label).ToList();
    }

    private void Prune()
    {
        var cutoff = DateTime.UtcNow.AddSeconds(-90);
        foreach (var kv in _parked.Where(kv => kv.Value.LastSeen <= cutoff).ToList())
            _parked.TryRemove(kv.Key, out _);
    }

    private void NotifyParked() { try { OnParkedChanged?.Invoke(ParkedList()); } catch { } }

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
