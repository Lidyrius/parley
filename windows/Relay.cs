using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Parley;

// The iPhone connection (docs/IPHONE.md, relay protocol v1), 1:1 with the macOS Relay.swift.
// Parley dials OUT to a small relay on Cloudflare as the host of one room — no port opens on
// the PC. It mirrors GET /sessions to the phones in the room and takes a phone's `resume` down
// the POST /resume path.

// The relay settings in credentials.json. relayUrl empty = the feature is off.
public sealed record RelayConfig
{
    public RelayConfig(string url, string room, string secret)
    {
        Url = RelayLink.Normalize(url);
        Room = room;
        Secret = secret;
    }

    public string Url { get; }      // relay base URL, normalized (no trailing slash)
    public string Room { get; }     // 16 random bytes, base64url
    public string Secret { get; }   // 32 random bytes, base64url — the relay keeps only its sha256

    public bool IsComplete => RelayLink.SocketBase(Url) is not null && Room.Length > 0 && Secret.Length > 0;

    public static RelayConfig Load()
    {
        var c = Config.Load();
        return new RelayConfig(c.RelayUrl, c.RelayRoom, c.RelaySecret);
    }

    // "iPhone verbinden…": null while no (http/https) relayUrl is set; else the settings, with
    // room + secret created once — together, since a room is claimed by its first secret.
    public static RelayConfig? Pair()
    {
        var c = Load();
        if (RelayLink.SocketBase(c.Url) is null) return null;
        if (c.IsComplete) return c;
        var paired = new RelayConfig(c.Url, RelayLink.Token(16), RelayLink.Token(32));
        if (!Config.Merge(new Dictionary<string, string> { ["relayRoom"] = paired.Room, ["relaySecret"] = paired.Secret }))
            return null;
        Log.Write("relay: created room + secret for pairing");
        return paired;
    }
}

// Pairing link, pairing page and socket URL — pure (1:1 with RelayLink on macOS).
public static class RelayLink
{
    // RFC 3986 unreserved stays, everything else is percent-encoded (UTF-8, upper-case hex).
    public static string Encode(string s) => Uri.EscapeDataString(s);

    // Trimmed, no trailing slash; a bare host gets https://.
    public static string Normalize(string url)
    {
        var u = url.Trim().TrimEnd('/');
        if (u.Length > 0 && !u.Contains("://")) u = "https://" + u;
        return u;
    }

    // parley://pair?u=<relay>&r=<room>&k=<secret> — what the iPhone scans.
    public static string Pairing(RelayConfig c) =>
        $"parley://pair?u={Encode(c.Url)}&r={Encode(c.Room)}&k={Encode(c.Secret)}";

    // <relay>/pair#<pairing link>: the relay's page draws the QR code from the fragment, which
    // the browser never sends — the secret never reaches the relay in a request. A plain string
    // on purpose: System.Uri would unescape parts of it.
    public static string PairPage(RelayConfig c) => $"{c.Url}/pair#{Encode(Pairing(c))}";

    // wss://<relay>/v1/room/<room>?role=host (ws:// for a plain-http dev relay).
    public static Uri? Socket(RelayConfig c) =>
        SocketBase(c.Url) is { } b && Uri.TryCreate($"{b}/v1/room/{Encode(c.Room)}?role=host", UriKind.Absolute, out var u)
            ? u : null;

    // The relay URL with its ws scheme; null unless http(s).
    public static string? SocketBase(string url)
    {
        if (url.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) return "wss://" + url[8..];
        if (url.StartsWith("http://", StringComparison.OrdinalIgnoreCase)) return "ws://" + url[7..];
        return null;
    }

    // `n` bytes from the system CSPRNG, base64url without padding.
    public static string Token(int bytes) => Base64Url(RandomNumberGenerator.GetBytes(bytes));

    public static string Base64Url(byte[] d) =>
        Convert.ToBase64String(d).Replace('+', '-').Replace('/', '_').TrimEnd('=');
}

// Relay frames: UTF-8 JSON text, the type in `t`.
public static class RelayFrame
{
    // `sessions`: the GET /sessions object with `t` and `at` (host clock, epoch ms) spliced in
    // front — the registry's own bytes, not re-encoded. null unless `json` is an object.
    public static string? Sessions(string json, long atMs)
    {
        var body = json.Trim();
        if (!body.StartsWith('{') || !body.EndsWith('}')) return null;
        var rest = body[1..].Trim();
        var head = "{\"t\":\"sessions\",\"at\":" + atMs.ToString(System.Globalization.CultureInfo.InvariantCulture);
        return head + (rest == "}" ? "" : ",") + rest;
    }

    // A phone's frame: `resume` takes the POST /resume path; `hello`, the relay's `pong` and
    // unknown types are ignored (forward compatible).
    public static void Dispatch(string text, Action<string> resume)
    {
        string? id;
        try
        {
            using var doc = JsonDocument.Parse(text);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("t", out var t) || t.ValueKind != JsonValueKind.String || t.GetString() != "resume"
                || !root.TryGetProperty("id", out var i) || i.ValueKind != JsonValueKind.String) return;
            id = i.GetString();
        }
        catch (JsonException) { return; }
        if (!string.IsNullOrEmpty(id)) resume(id);
    }
}

// When the overview goes out: on change (compared as the registry's JSON, so `at` never
// counts), else at least every 10 s. A new connection starts with a fresh one → sent at once.
public sealed class RelaySync
{
    public static readonly TimeSpan Heartbeat = TimeSpan.FromSeconds(10);
    private string? _last;
    private DateTime _lastAt = DateTime.MinValue;

    public bool Due(string json, DateTime now)
    {
        // ½ s slack so the 2 s check tick can't slip a heartbeat to 12 s.
        if (json == _last && now - _lastAt < Heartbeat - TimeSpan.FromSeconds(0.5)) return false;
        _last = json;
        _lastAt = now;
        return true;
    }
}

// The host's one connection to its room: reconnects with capped exponential backoff (1 s →
// 30 s), pings every 25 s (the relay answers `pong` itself), checks the overview every 2 s and
// sends it on change / every 10 s, and hands a phone's `resume` on. One background task; the
// tray reads `Connected` when its menu opens.
public sealed class RelayClient
{
    private static readonly TimeSpan TickEvery = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan PingEvery = TimeSpan.FromSeconds(25);
    private static readonly TimeSpan SilentLimit = TimeSpan.FromSeconds(60);   // nothing from the relay (not even a pong) → dead link
    private static readonly TimeSpan MaxBackoff = TimeSpan.FromSeconds(30);
    private const int MaxFrame = 1 << 20;   // as URLSessionWebSocketTask's receive limit on macOS

    public static TimeSpan NextBackoff(TimeSpan b) => b * 2 < MaxBackoff ? b * 2 : MaxBackoff;

    public RelayConfig Config { get; }
    public bool Connected => Volatile.Read(ref _connected);

    private readonly Uri _uri;
    private readonly Func<string> _sessions;
    private readonly Action<string> _resume;
    private readonly CancellationTokenSource _stop = new();
    private Task? _loop;
    private bool _connected;
    private long _lastInbound;   // UTC ticks of the last frame from the relay (receive loop → send loop)

    private RelayClient(RelayConfig config, Uri uri, Func<string> sessions, Action<string> resume)
    {
        Config = config;
        _uri = uri;
        _sessions = sessions;
        _resume = resume;
    }

    // null unless the config is complete (http(s) relayUrl, room, secret).
    public static RelayClient? Create(RelayConfig config, Func<string> sessions, Action<string> resume) =>
        config.IsComplete && RelayLink.Socket(config) is { } uri ? new RelayClient(config, uri, sessions, resume) : null;

    public void Start() => _loop ??= Task.Run(() => RunAsync(_stop.Token));

    public void Stop()
    {
        if (_stop.IsCancellationRequested) return;
        _stop.Cancel();
        Log.Write("relay: stopped");
    }

    private async Task RunAsync(CancellationToken ct)
    {
        var backoff = TimeSpan.FromSeconds(1);
        while (!ct.IsCancellationRequested)
        {
            Exception? error = null;
            try
            {
                using var ws = new ClientWebSocket();
                ws.Options.SetRequestHeader("Authorization", "Bearer " + Config.Secret);
                using (var connect = CancellationTokenSource.CreateLinkedTokenSource(ct))
                {
                    connect.CancelAfter(TimeSpan.FromSeconds(60));
                    await ws.ConnectAsync(_uri, connect.Token);
                }
                Volatile.Write(ref _connected, true);
                backoff = TimeSpan.FromSeconds(1);
                Log.Write($"relay: connected to {_uri.Host}");
                await RunConnectedAsync(ws, ct);
            }
            catch (Exception e) { error = e; }
            if (ct.IsCancellationRequested) break;
            var wasUp = Volatile.Read(ref _connected);
            Volatile.Write(ref _connected, false);
            // Quiet once at the cap: an offline PC would log every 30 s otherwise.
            if (wasUp || backoff < MaxBackoff)
                Log.Write($"relay: {(wasUp ? "disconnected" : "unreachable")} ({error?.Message ?? "closed"}) — retry in {(int)backoff.TotalSeconds} s");
            try { await Task.Delay(backoff, ct); }
            catch (OperationCanceledException) { break; }
            backoff = NextBackoff(backoff);
        }
        Volatile.Write(ref _connected, false);
    }

    // One live connection: the overview when due, a ping every 25 s with a dead-link check, and
    // the receive loop. Returns or throws once the link is gone; on Stop it closes (going away).
    private async Task RunConnectedAsync(ClientWebSocket ws, CancellationToken ct)
    {
        var sync = new RelaySync();
        var lastPing = DateTime.UtcNow;
        Volatile.Write(ref _lastInbound, lastPing.Ticks);
        using var receiveCts = new CancellationTokenSource();
        var receive = ReceiveLoopAsync(ws, receiveCts.Token);
        try
        {
            while (!ct.IsCancellationRequested)
            {
                if (receive.IsCompleted) { await receive; return; }   // rethrows why it ended
                var now = DateTime.UtcNow;
                if (now - lastPing >= PingEvery)
                {
                    if (now - new DateTime(Volatile.Read(ref _lastInbound), DateTimeKind.Utc) > SilentLimit)
                        throw new TimeoutException($"no answer from the relay for {(int)SilentLimit.TotalSeconds} s");
                    lastPing = now;
                    await SendAsync(ws, "ping", ct);
                }
                var json = _sessions();
                if (sync.Due(json, now) && RelayFrame.Sessions(json, new DateTimeOffset(now).ToUnixTimeMilliseconds()) is { } frame)
                    await SendAsync(ws, frame, ct);
                await Task.WhenAny(receive, Task.Delay(TickEvery, ct));
            }
        }
        finally
        {
            if (ct.IsCancellationRequested && ws.State == WebSocketState.Open)
            {
                using var closing = new CancellationTokenSource(TimeSpan.FromSeconds(1));
                try { await ws.CloseOutputAsync(WebSocketCloseStatus.EndpointUnavailable, null, closing.Token); } catch { }
            }
            receiveCts.Cancel();
            try { await receive; } catch { }
        }
    }

    private async Task ReceiveLoopAsync(ClientWebSocket ws, CancellationToken ct)
    {
        var buffer = new byte[16 * 1024];
        using var frame = new MemoryStream();
        while (true)
        {
            var r = await ws.ReceiveAsync(new ArraySegment<byte>(buffer), ct);
            if (r.MessageType == WebSocketMessageType.Close)
                throw new WebSocketException($"closed by the relay ({r.CloseStatus} {r.CloseStatusDescription})");
            frame.Write(buffer, 0, r.Count);
            if (frame.Length > MaxFrame) throw new WebSocketException("frame too large");
            if (!r.EndOfMessage) continue;
            Volatile.Write(ref _lastInbound, DateTime.UtcNow.Ticks);
            if (r.MessageType == WebSocketMessageType.Text)   // binary: reserved for audio (stage 2)
                RelayFrame.Dispatch(Encoding.UTF8.GetString(frame.GetBuffer(), 0, (int)frame.Length), _resume);
            frame.SetLength(0);
        }
    }

    // Only the connection loop sends, so sends never overlap (ClientWebSocket allows one at a time).
    private static Task SendAsync(ClientWebSocket ws, string text, CancellationToken ct) =>
        ws.SendAsync(new ArraySegment<byte>(Encoding.UTF8.GetBytes(text)), WebSocketMessageType.Text, true, ct);
}
