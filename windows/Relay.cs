using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Parley;

// The iPhone connection (docs/IPHONE.md, relay protocol v1 + v2), 1:1 with the macOS Relay.swift.
// Parley dials OUT to a small relay on Cloudflare as the host of one room — no port opens on
// the PC. It mirrors GET /sessions to the phones in the room, takes a phone's `resume` down
// the POST /resume path, and carries the v2 call: binary audio frames both ways, the phone's
// `call` / `wake` / `push` / `away`, and the host's `audio` / `ring`.

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

    // A phone's frame → its message; `hello`, the relay's `pong`, unknown types and malformed
    // bodies → null, ignored (forward compatible).
    public static PhoneMessage? Parse(string text)
    {
        try
        {
            using var doc = JsonDocument.Parse(text);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("t", out var t) || t.ValueKind != JsonValueKind.String) return null;
            string? Str(string key) =>
                root.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
            switch (t.GetString())
            {
                case "resume":
                    return Str("id") is { Length: > 0 } id ? new PhoneResume(id) : null;
                case "call":
                    return Str("state") switch
                    {
                        "start" => new PhoneCallState(true,
                            root.TryGetProperty("down", out var down) && down.ValueKind == JsonValueKind.Number
                                && down.TryGetInt32(out var rate) && rate == PhoneAudio.HiFiRate ? PhoneAudio.HiFiRate : PhoneAudio.SampleRate),
                        "end" => new PhoneCallState(false),
                        _ => null,
                    };
                case "wake":
                    return new PhoneWake();
                case "push":
                    if (Str("token") is not { Length: > 0 } token) return null;
                    return Str("kind") == "alert" ? new PhoneAlert(token, Str("env") ?? "production") : new PhonePush(token, Str("env") ?? "production");
                case "silent":
                    return root.TryGetProperty("on", out var silent) && (silent.ValueKind is JsonValueKind.True or JsonValueKind.False)
                        ? new PhoneSilent(silent.ValueKind == JsonValueKind.True) : null;
                case "history":
                    return Str("id") is { Length: > 0 } hid ? new PhoneHistory(hid, Str("before") is { Length: > 0 } b ? b : null) : null;
                case "image":
                    return Str("id") is { Length: > 0 } iid && Str("key") is { Length: > 0 } key ? new PhoneImage(iid, key) : null;
                case "say":
                    return Str("id") is { Length: > 0 } sid && Str("text")?.Trim() is { Length: > 0 and <= 8000 } said ? new PhoneSay(sid, said) : null;
                case "later":
                    var after = root.TryGetProperty("after", out var af) && af.ValueKind == JsonValueKind.Number ? af.GetDouble() : 0;
                    return new PhoneLater(after > 0 ? Math.Clamp(after, 10, 3600) : null);
                case "away":
                    return root.TryGetProperty("on", out var flag) && (flag.ValueKind is JsonValueKind.True or JsonValueKind.False)
                        ? new PhoneAway(flag.ValueKind == JsonValueKind.True) : null;
                default:
                    return null;
            }
        }
        catch (JsonException) { return null; }
    }

    // host → phone (v2): what the host does with the call audio — speaking | listening | idle.
    // `label` = the session voiced now (the call screen's name).
    public static string Audio(string state, string? label = null) => label is null
        ? JsonSerializer.Serialize(new { t = "audio", state })
        : JsonSerializer.Serialize(new { t = "audio", state, label });

    // host → phone (v2): an update wants the phone (next to the VoIP push).
    public static string Ring(string label) => JsonSerializer.Serialize(new { t = "ring", label });
}

// A phone's message (protocol v1 + v2).
public abstract record PhoneMessage { }
public sealed record PhoneResume(string Id) : PhoneMessage;          // resume a session (POST /resume)
public sealed record PhoneCallState(bool Started, int Down = PhoneAudio.SampleRate) : PhoneMessage;    // `call` start / end; the voice's rate (v3: 24 kHz on request)
public sealed record PhoneWake : PhoneMessage { }                     // "Hey Parley" while the host was idle
public sealed record PhonePush(string Token, string Env) : PhoneMessage;   // VoIP token, production | development
public sealed record PhoneAway(bool On) : PhoneMessage;              // Unterwegs-Modus
// v3: Stumm, the notification push token, a session's history / image, a typed message.
public sealed record PhoneSilent(bool On) : PhoneMessage;
public sealed record PhoneAlert(string Token, string Env) : PhoneMessage;
public sealed record PhoneHistory(string Id, string? Before) : PhoneMessage;   // newest page, or the one before an item
public sealed record PhoneImage(string Id, string Key) : PhoneMessage;
public sealed record PhoneSay(string Id, string Text) : PhoneMessage;
public sealed record PhoneLater(double? After) : PhoneMessage;    // not now: ring again in n s, or null = Sir calls back

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
// sends it on change / every 10 s, and hands a phone's messages and audio on. One background
// task receives; sends come from it and from the call (audio, state) through one gate. The
// tray reads `Connected` when its menu opens.
public sealed class RelayClient
{
    private static readonly TimeSpan TickEvery = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan PingEvery = TimeSpan.FromSeconds(25);
    private static readonly TimeSpan SilentLimit = TimeSpan.FromSeconds(60);   // nothing from the relay (not even a pong) → dead link
    private static readonly TimeSpan MaxBackoff = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan SendTimeout = TimeSpan.FromSeconds(10);   // a stuck send gives up (and drops the link)
    private const int MaxFrame = 1 << 20;   // as URLSessionWebSocketTask's receive limit on macOS
    private const int MaxAudioFrame = 64 * 1024;   // the relay drops bigger binary frames; so do we

    public static TimeSpan NextBackoff(TimeSpan b) => b * 2 < MaxBackoff ? b * 2 : MaxBackoff;

    public RelayConfig Config { get; }
    public bool Connected => Volatile.Read(ref _connected);

    // After each (re)connect, on the relay task — the call state is sent again. Set before Start.
    public Action? OnConnected { get; set; }

    private readonly Uri _uri;
    private readonly Func<string> _sessions;
    private readonly Action<PhoneMessage> _phone;
    private readonly Action<byte[]>? _audio;
    private readonly CancellationTokenSource _stop = new();
    private readonly SemaphoreSlim _sendGate = new(1, 1);   // ClientWebSocket allows one send at a time
    private Task? _loop;
    private bool _connected;
    private ClientWebSocket? _ws;   // the live connection, for sends from outside the loop
    private long _lastInbound;   // UTC ticks of the last frame from the relay (receive loop → send loop)

    private RelayClient(RelayConfig config, Uri uri, Func<string> sessions, Action<PhoneMessage> phone, Action<byte[]>? audio)
    {
        Config = config;
        _uri = uri;
        _sessions = sessions;
        _phone = phone;
        _audio = audio;
    }

    // null unless the config is complete (http(s) relayUrl, room, secret). `phone` gets each
    // phone message, `audio` each binary frame (the phone's mic), both on the receive task.
    public static RelayClient? Create(RelayConfig config, Func<string> sessions, Action<PhoneMessage> phone, Action<byte[]>? audio = null) =>
        config.IsComplete && RelayLink.Socket(config) is { } uri ? new RelayClient(config, uri, sessions, phone, audio) : null;

    public Task<bool> SendTextAsync(string text) => SendOutsideAsync(Encoding.UTF8.GetBytes(text), WebSocketMessageType.Text);

    public Task<bool> SendAudioAsync(byte[] frame) => SendOutsideAsync(frame, WebSocketMessageType.Binary);

    // A send from the call (audio, `audio`, `ring`): false when not connected or it failed — the
    // connection loop notices a dead link on its own.
    private async Task<bool> SendOutsideAsync(byte[] data, WebSocketMessageType type)
    {
        var ws = Volatile.Read(ref _ws);
        if (ws is null || ws.State != WebSocketState.Open) return false;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(_stop.Token);
        timeout.CancelAfter(SendTimeout);
        try
        {
            await SendLockedAsync(ws, data, type, timeout.Token);
            return true;
        }
        catch (Exception) { return false; }
    }

    private async Task SendLockedAsync(ClientWebSocket ws, byte[] data, WebSocketMessageType type, CancellationToken ct)
    {
        await _sendGate.WaitAsync(ct);
        try { await ws.SendAsync(new ArraySegment<byte>(data), type, true, ct); }
        finally { _sendGate.Release(); }
    }

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
                Volatile.Write(ref _ws, ws);
                backoff = TimeSpan.FromSeconds(1);
                Log.Write($"relay: connected to {_uri.Host}");
                try { OnConnected?.Invoke(); }
                catch (Exception e) { Log.Write($"relay: on-connect failed: {e.Message}"); }
                try { await RunConnectedAsync(ws, ct); }
                finally { Volatile.Write(ref _ws, null); }
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
                    await SendLockedAsync(ws, Encoding.UTF8.GetBytes("ping"), WebSocketMessageType.Text, ct);
                }
                var json = _sessions();
                if (sync.Due(json, now) && RelayFrame.Sessions(json, new DateTimeOffset(now).ToUnixTimeMilliseconds()) is { } frame)
                    await SendLockedAsync(ws, Encoding.UTF8.GetBytes(frame), WebSocketMessageType.Text, ct);
                await Task.WhenAny(receive, Task.Delay(TickEvery, ct));
            }
        }
        finally
        {
            if (ct.IsCancellationRequested && ws.State == WebSocketState.Open)
            {
                using var closing = new CancellationTokenSource(TimeSpan.FromSeconds(1));
                try
                {
                    await _sendGate.WaitAsync(closing.Token);   // the close is a send too
                    try { await ws.CloseOutputAsync(WebSocketCloseStatus.EndpointUnavailable, null, closing.Token); }
                    finally { _sendGate.Release(); }
                }
                catch { }
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
            // A handler's failure must never end the connection.
            if (r.MessageType == WebSocketMessageType.Text)
            {
                if (RelayFrame.Parse(Encoding.UTF8.GetString(frame.GetBuffer(), 0, (int)frame.Length)) is { } message)
                {
                    try { _phone(message); }
                    catch (Exception e) { Log.Write($"relay: {message.GetType().Name} failed: {e.Message}"); }
                }
            }
            else if (frame.Length <= MaxAudioFrame && _audio is not null)   // binary: the phone's mic (v2)
            {
                try { _audio(frame.ToArray()); }
                catch (Exception e) { Log.Write($"relay: audio frame failed: {e.Message}"); }
            }
            frame.SetLength(0);
        }
    }
}
