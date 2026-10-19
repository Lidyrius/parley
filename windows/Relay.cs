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

// The relay settings in credentials.json. relayUrl empty = the public relay.
public sealed record RelayConfig
{
    public RelayConfig(string url, string room, string secret, string key = "")
    {
        Url = RelayLink.Normalize(url);
        Room = room;
        Secret = secret;
        Key = key;
    }

    public string Url { get; }      // relay base URL, normalized (no trailing slash)
    public string Room { get; }     // 16 random bytes, base64url
    public string Secret { get; }   // 32 random bytes, base64url — the relay keeps only its sha256
    public string Key { get; }      // 32 random bytes, base64url — end-to-end key, never sent to the relay

    public bool IsComplete => RelayLink.SocketBase(Url) is not null && Room.Length > 0 && Secret.Length > 0;

    public static RelayConfig Load()
    {
        var c = Config.Load();
        return new RelayConfig(c.RelayUrl.Length > 0 ? c.RelayUrl : RelayLink.PublicRelay, c.RelayRoom, c.RelaySecret, c.RelayKey);
    }

    // "Handy verbinden…": null without a usable (http/https) relayUrl; else the settings, with
    // room + secret created once — together, since a room is claimed by its first secret.
    public static RelayConfig? Pair()
    {
        var c = Load();
        if (RelayLink.SocketBase(c.Url) is null) return null;
        if (!c.IsComplete)
        {
            c = new RelayConfig(c.Url, RelayLink.Token(16), RelayLink.Token(32));
            if (!Config.Merge(new Dictionary<string, string> { ["relayRoom"] = c.Room, ["relaySecret"] = c.Secret }))
                return null;
            Log.Write("relay: created room + secret for pairing");
        }
        return c.WithKey();
    }

    // The end-to-end key, created once. A room paired before v5 gets one here: its phone pairs again.
    public RelayConfig WithKey()
    {
        if (!IsComplete || Key.Length > 0) return this;
        var c = new RelayConfig(Url, Room, Secret, RelayLink.Token(32));
        if (!Config.Merge(new Dictionary<string, string> { ["relayKey"] = c.Key })) return this;
        Log.Write("relay: created the end-to-end key — the phone has to pair again");
        return c;
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

    // The relay everyone can use (end-to-end encrypted); `relayUrl` points at your own instead.
    public const string PublicRelay = "https://parley-relay.sydney-d51.workers.dev";

    // parley://pair?u=<relay>&r=<room>&k=<secret>&e=<key> — what the phone scans.
    public static string Pairing(RelayConfig c) =>
        $"parley://pair?u={Encode(c.Url)}&r={Encode(c.Room)}&k={Encode(c.Secret)}" + (c.Key.Length > 0 ? $"&e={Encode(c.Key)}" : "");

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
            bool Flag(string key) => root.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.True;
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
                case "hello":
                    return new PhoneHello();
                case "barge":
                    return new PhoneBarge();
                case "palette":
                    return Str("saved") is { Length: > 0 } saved ? new PhonePaletteSaved(saved) : null;
                case "wake":
                    return new PhoneWake();
                case "push":
                    if (Str("token") is not { Length: > 0 } token) return null;
                    return Str("kind") == "alert" ? new PhoneAlert(token, Str("env") ?? "production") : new PhonePush(token, Str("env") ?? "production");
                case "silent":
                    return root.TryGetProperty("on", out var silent) && (silent.ValueKind is JsonValueKind.True or JsonValueKind.False)
                        ? new PhoneSilent(silent.ValueKind == JsonValueKind.True) : null;
                case "round":
                    return root.TryGetProperty("seconds", out var rs) && rs.TryGetInt32(out var secs) ? new PhoneRound(secs) : null;
                case "history":
                    return Str("id") is { Length: > 0 } hid ? new PhoneHistory(hid, Str("before") is { Length: > 0 } b ? b : null) : null;
                case "image":
                    return Str("id") is { Length: > 0 } iid && Str("key") is { Length: > 0 } key ? new PhoneImage(iid, key) : null;
                case "say":
                    return Str("id") is { Length: > 0 } sid && Str("text")?.Trim() is { Length: > 0 and <= 8000 } said ? new PhoneSay(sid, said) : null;
                case "later":
                    var after = root.TryGetProperty("after", out var af) && af.ValueKind == JsonValueKind.Number ? af.GetDouble() : 0;
                    return new PhoneLater(after > 0 ? Math.Clamp(after, 10, 3600) : null);
                case "activity":
                    // v4 (docs/LIVE-ACTIVITIES.md): the Live Activity's push tokens; "" = none runs.
                    static bool Hex(string s) => s.Length <= 200 && s.All(Uri.IsHexDigit);
                    var aenv = Str("env") == "development" ? "development" : "production";
                    if (Str("start") is { Length: > 0 } st && Hex(st)) return new PhoneActivityStart(st.ToLowerInvariant(), aenv);
                    if (Str("token") is { } tk && Hex(tk)) return new PhoneActivity(tk.ToLowerInvariant(), aenv);
                    return null;
                case "away":
                    return root.TryGetProperty("on", out var flag) && (flag.ValueKind is JsonValueKind.True or JsonValueKind.False)
                        ? new PhoneAway(flag.ValueKind == JsonValueKind.True) : null;
                case "snapshot":
                    // v6 (docs/IPHONE.md): Snapshots. `ids` other than a list of strings = none given (every
                    // running session), as macOS.
                    var snap = Str("id") ?? "";
                    switch (Str("op"))
                    {
                        case "save":
                            if (Str("name") is not { } sname || string.IsNullOrWhiteSpace(sname)) return null;
                            var ids = root.TryGetProperty("ids", out var ia) && ia.ValueKind == JsonValueKind.Array
                                && ia.EnumerateArray().All(v => v.ValueKind == JsonValueKind.String)
                                ? ia.EnumerateArray().Select(v => v.GetString()!).ToList() : null;
                            return new PhoneSnapshotSave(sname, ids);
                        case "open": return snap.Length > 0 ? new PhoneSnapshotOpen(snap) : null;
                        case "delete": return snap.Length > 0 ? new PhoneSnapshotDelete(snap) : null;
                        default: return null;
                    }
                case "join":   // v7: a guest on a share's room says who he is, with his share key
                    return new PhoneJoin(Str("name") ?? "", Str("device") ?? "", Str("pub") ?? "");
                case "answer": // v7: a guest answers his question, or passes it on to Sir
                    if (Str("id") is not { Length: > 0 } aid) return null;
                    return new PhoneAnswer(aid, Str("text") ?? "", Flag("pass"));
                case "share":  // v7: Sir shares a session, lets a guest in, ends a share
                    if (Str("id") is not { Length: > 0 } shid) return null;
                    return Str("op") switch
                    {
                        "create" => new PhoneShareCreate(shid),
                        "approve" => new PhoneShareApprove(shid, Str("role") ?? "", Flag("listen"), Flag("full"), Str("mine")),
                        "remove" => new PhoneShareRemove(shid),
                        _ => null,
                    };
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
public sealed record PhoneRound(int Seconds) : PhoneMessage;   // Fragerunde: how long an update waits (0 = never)
public sealed record PhoneAlert(string Token, string Env) : PhoneMessage;
public sealed record PhoneHistory(string Id, string? Before) : PhoneMessage;   // newest page, or the one before an item
public sealed record PhoneImage(string Id, string Key) : PhoneMessage;
public sealed record PhoneSay(string Id, string Text) : PhoneMessage;
// v4: the phone (re)connected; it saved and switched to a palette made by voice.
public sealed record PhoneHello : PhoneMessage { }
public sealed record PhoneBarge : PhoneMessage { }   // v4: Sir talks over Parley — stop the line, listen
public sealed record PhonePaletteSaved(string Name) : PhoneMessage;
// v4: the Live Activity's push-to-start token, and the running one's update token ("" = none).
public sealed record PhoneActivityStart(string Token, string Env) : PhoneMessage;
public sealed record PhoneActivity(string Token, string Env) : PhoneMessage;
public sealed record PhoneLater(double? After) : PhoneMessage;    // not now: ring again in n s, or null = Sir calls back
// v6: Snapshots — keep the running sessions under a name, open them again.
public sealed record PhoneSnapshotSave(string Name, IReadOnlyList<string>? Ids) : PhoneMessage;   // null ids = every running session
public sealed record PhoneSnapshotOpen(string Id) : PhoneMessage;
public sealed record PhoneSnapshotDelete(string Id) : PhoneMessage;
// v7 (docs/IPHONE.md): shared sessions — Sir's controls, and a guest saying who he is / answering.
public sealed record PhoneShareCreate(string Session) : PhoneMessage;
public sealed record PhoneShareApprove(string Id, string Role, bool Listen, bool Full, string? Mine) : PhoneMessage;
public sealed record PhoneShareRemove(string Id) : PhoneMessage;
public sealed record PhoneJoin(string Name, string Device, string Pub) : PhoneMessage;
public sealed record PhoneAnswer(string Id, string Text, bool Pass) : PhoneMessage;

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
    // End-to-end (docs/IPHONE.md → v5): null only for a config without a key.
    private readonly RelaySeal? _seal;
    private readonly ReplayGuard _replay = new();

    private static long NowMs => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    private readonly string _name;   // log prefix: "relay", or "share <id>" for a shared session's room

    private RelayClient(RelayConfig config, Uri uri, Func<string> sessions, Action<PhoneMessage> phone, Action<byte[]>? audio, string name)
    {
        _name = name;
        Config = config;
        _seal = RelaySeal.Create(config.Key);
        _uri = uri;
        _sessions = sessions;
        _phone = phone;
        _audio = audio;
    }

    // null unless the config is complete (http(s) relayUrl, room, secret). `phone` gets each
    // phone message, `audio` each binary frame (the phone's mic), both on the receive task.
    public static RelayClient? Create(RelayConfig config, Func<string> sessions, Action<PhoneMessage> phone, Action<byte[]>? audio = null,
                                      string name = "relay") =>
        config.IsComplete && RelayLink.Socket(config) is { } uri ? new RelayClient(config, uri, sessions, phone, audio, name) : null;

    public Task<bool> SendTextAsync(string text) =>
        Sealed(text) is { } s ? SendOutsideAsync(Encoding.UTF8.GetBytes(s), WebSocketMessageType.Text) : Task.FromResult(false);

    public Task<bool> SendAudioAsync(byte[] frame) =>
        SendOutsideAsync(_seal?.Binary(frame, NowMs) ?? frame, WebSocketMessageType.Binary);

    // Never in the clear with a key: a frame that can't be sealed isn't sent.
    private string? Sealed(string text) => _seal is null ? text : _seal.Text(text, NowMs);

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
        Log.Write($"{_name}: stopped");
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
                Log.Write($"{_name}: connected to {_uri.Host}");
                try { OnConnected?.Invoke(); }
                catch (Exception e) { Log.Write($"{_name}: on-connect failed: {e.Message}"); }
                try { await RunConnectedAsync(ws, ct); }
                finally { Volatile.Write(ref _ws, null); }
            }
            catch (Exception e) { error = e; }
            if (ct.IsCancellationRequested) break;
            var wasUp = Volatile.Read(ref _connected);
            Volatile.Write(ref _connected, false);
            // Quiet once at the cap: an offline PC would log every 30 s otherwise.
            if (wasUp || backoff < MaxBackoff)
                Log.Write($"{_name}: {(wasUp ? "disconnected" : "unreachable")} ({error?.Message ?? "closed"}) — retry in {(int)backoff.TotalSeconds} s");
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
                if (sync.Due(json, now) && RelayFrame.Sessions(json, new DateTimeOffset(now).ToUnixTimeMilliseconds()) is { } frame
                    && Sealed(frame) is { } wire)
                    await SendLockedAsync(ws, Encoding.UTF8.GetBytes(wire), WebSocketMessageType.Text, ct);
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

    // A phone's frame, opened: only sealed, fresh, first-seen frames count — a relay that
    // replays or forges one gets nothing in (a `say` or an utterance would reach a session).
    private string? Unseal(string text)
    {
        if (_seal is null) return text;
        return text != "pong" && _seal.OpenText(text) is { } o && _replay.Accept(o.SentMs, o.Nonce, NowMs) ? o.Json : null;
    }

    private byte[]? Unseal(byte[] data)
    {
        if (_seal is null) return data;
        return _seal.OpenBinary(data) is { } o && _replay.Accept(o.SentMs, o.Nonce, NowMs) ? o.Data : null;
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
                if (Unseal(Encoding.UTF8.GetString(frame.GetBuffer(), 0, (int)frame.Length)) is { } text
                    && RelayFrame.Parse(text) is { } message)
                {
                    try { _phone(message); }
                    catch (Exception e) { Log.Write($"{_name}: {message.GetType().Name} failed: {e.Message}"); }
                }
            }
            else if (frame.Length <= MaxAudioFrame && _audio is not null && Unseal(frame.ToArray()) is { } pcm)   // binary: the phone's mic (v2)
            {
                try { _audio(pcm); }
                catch (Exception e) { Log.Write($"{_name}: audio frame failed: {e.Message}"); }
            }
            frame.SetLength(0);
        }
    }
}
