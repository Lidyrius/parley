using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Parley;

// The PC as a GUEST of someone else's shared session (docs/MULTIPLAYER.md, protocol v7 in
// docs/IPHONE.md) — as macOS Guest.swift: join with the invite link, Sir lets him in, the session
// shows in the tray panel with "Anrufen"; a call runs on the PC's mic and speaker.

/// One joined (or joining) share, kept in guests.json (user-only, as shares.json).
public sealed class GuestShare
{
    [JsonPropertyName("id")] public string Id { get; set; } = Guid.NewGuid().ToString();
    [JsonPropertyName("relay")] public string Relay { get; set; } = "";
    [JsonPropertyName("room")] public string Room { get; set; } = "";
    [JsonPropertyName("secret")] public string Secret { get; set; } = "";       // the relay bearer
    [JsonPropertyName("key")] public string Key { get; set; } = "";             // the end-to-end key
    [JsonPropertyName("label")] public string Label { get; set; } = "";         // the session's name
    [JsonPropertyName("host")] public string Host { get; set; } = "";           // who shared it
    [JsonPropertyName("name")] public string Name { get; set; } = "";           // how the guest called himself
    [JsonPropertyName("privateKey")] public string PrivateKey { get; set; } = ""; // P-256, PKCS#8 base64 — for the sealed move (S1)
    [JsonPropertyName("active")] public bool Active { get; set; }               // false: still in the invite room
    [JsonPropertyName("share")] public string Share { get; set; } = "";         // the host's share id (after the move)
    [JsonPropertyName("role")] public string Role { get; set; } = "";
    [JsonPropertyName("listen")] public bool Listen { get; set; }               // only listening: nothing to say

    public static string File => Path.Combine(Config.Dir, "guests.json");

    [JsonIgnore]
    public string Pub
    {
        get
        {
            try
            {
                using var k = ECDiffieHellman.Create();
                k.ImportPkcs8PrivateKey(Convert.FromBase64String(PrivateKey), out _);
                var q = k.ExportParameters(false).Q;
                var raw = new byte[65];
                raw[0] = 0x04;
                q.X!.CopyTo(raw, 1 + 32 - q.X!.Length);
                q.Y!.CopyTo(raw, 33 + 32 - q.Y!.Length);
                return RelayLink.Base64Url(raw);
            }
            catch { return ""; }
        }
    }

    [JsonIgnore] public string Code => Shares.Code(Pub);

    /// `https://<relay>/join#<parley://join?u&r&k&e&s&h>` or the bare parley:// link.
    public static GuestShare? Parse(string link, string name)
    {
        var raw = link.Trim();
        var hash = raw.IndexOf('#');
        if (raw.StartsWith("https://", StringComparison.OrdinalIgnoreCase) && hash > 0
            && Uri.TryCreate(raw[..hash], UriKind.Absolute, out var page) && page.AbsolutePath == "/join")
            raw = Uri.UnescapeDataString(raw[(hash + 1)..]);
        if (!raw.StartsWith("parley://join?", StringComparison.Ordinal)) return null;
        var q = new Dictionary<string, string>();
        foreach (var part in raw["parley://join?".Length..].Split('&'))
        {
            var eq = part.IndexOf('=');
            if (eq > 0) q[part[..eq]] = Uri.UnescapeDataString(part[(eq + 1)..].Replace('+', ' '));
        }
        string Q(string k) => q.TryGetValue(k, out var v) ? v : "";
        var relay = RelayLink.Normalize(Q("u"));
        var room = Q("r"); var secret = Q("k"); var key = Q("e");
        if (!relay.StartsWith("https://", StringComparison.OrdinalIgnoreCase) || room.Length is < 16 or > 64
            || secret.Length is < 16 or > 128 || key.Length != 43 || RelaySeal.Create(key) is null) return null;
        using var mine = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        return new GuestShare
        {
            Relay = relay, Room = room, Secret = secret, Key = key,
            Label = Cut(Q("s"), 60), Host = Cut(Q("h"), 60),
            Name = Shares.CleanName(name),
            PrivateKey = Convert.ToBase64String(mine.ExportPkcs8PrivateKey()),
        };
    }

    private static string Cut(string s, int n) => s.Length > n ? s[..n] : s;

    /// The host's `move`: the fresh room, sealed to our key (ECDH + HKDF → AES-GCM, no AAD).
    public (string Room, string Secret, string Key)? OpenMove(string pub, string box, string share)
    {
        if (Shares.PublicKey(pub) is not { } theirs || RelaySeal.FromBase64Url(box) is not { Length: > 28 } sealedBox) return null;
        try
        {
            using var mine = ECDiffieHellman.Create();
            mine.ImportPkcs8PrivateKey(Convert.FromBase64String(PrivateKey), out _);
            using var other = ECDiffieHellman.Create(theirs);
            var key = Shares.MoveKey(mine.DeriveRawSecretAgreement(other.PublicKey), share);
            var plain = new byte[sealedBox.Length - 28];
            using (var gcm = new AesGcm(key, 16))
                gcm.Decrypt(sealedBox.AsSpan(0, 12), sealedBox.AsSpan(12, plain.Length), sealedBox.AsSpan(12 + plain.Length, 16), plain);
            using var doc = JsonDocument.Parse(plain);
            var r = doc.RootElement;
            return (r.GetProperty("r").GetString() ?? "", r.GetProperty("k").GetString() ?? "", r.GetProperty("e").GetString() ?? "");
        }
        catch { return null; }
    }

    public static List<GuestShare> Load()
    {
        try { return System.IO.File.Exists(File) ? JsonSerializer.Deserialize<List<GuestShare>>(System.IO.File.ReadAllText(File)) ?? new() : new(); }
        catch { return new(); }
    }

    public static void Save(List<GuestShare> list)
    {
        try
        {
            Directory.CreateDirectory(Config.Dir);
            var tmp = File + ".tmp";
            System.IO.File.WriteAllText(tmp, JsonSerializer.Serialize(list));
            Shares.OwnerOnly(tmp);
            System.IO.File.Move(tmp, File, overwrite: true);
        }
        catch (Exception e) { Log.Write($"guest: not saved ({e.Message})"); }
    }
}

/// The share's relay room as the phone side (`role=phone`): sealed frames both ways, `hello`
/// first, a ping every 25 s, redial with backoff. No replay guard: the relay replays `sessions`.
public sealed class GuestLink
{
    public Action<JsonElement>? OnFrame;
    public Action<byte[]>? OnAudio;
    public Action? OnOpen;
    public Action? OnGone;   // 404: the room is no more (invite used / expired)

    private readonly GuestShare _share;
    private readonly RelaySeal _seal;
    private readonly CancellationTokenSource _stop = new();
    private readonly SemaphoreSlim _send = new(1, 1);
    private ClientWebSocket? _ws;

    private GuestLink(GuestShare share, RelaySeal seal) { _share = share; _seal = seal; }

    public static GuestLink? Create(GuestShare share) =>
        RelaySeal.Create(share.Key) is { } seal ? new GuestLink(share, seal) : null;

    private static long Now => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    public void Start() => _ = Task.Run(Run);

    public void Stop()
    {
        _stop.Cancel();
        try { _ws?.Abort(); } catch { }
    }

    public void Send(object frame)
    {
        if (_seal.Text(JsonSerializer.Serialize(frame), Now) is { } wire) _ = SendRaw(Encoding.UTF8.GetBytes(wire), WebSocketMessageType.Text);
    }

    public void SendAudio(byte[] pcm) => _ = SendRaw(_seal.Binary(pcm, Now), WebSocketMessageType.Binary);

    private async Task SendRaw(byte[] data, WebSocketMessageType type)
    {
        var ws = _ws;
        if (ws is null || ws.State != WebSocketState.Open) return;
        await _send.WaitAsync();
        try { await ws.SendAsync(data, type, true, _stop.Token); }
        catch { }
        finally { _send.Release(); }
    }

    private async Task Run()
    {
        var backoff = 1.0;
        while (!_stop.IsCancellationRequested)
        {
            if (RelayLink.SocketBase(_share.Relay) is not { } b
                || !Uri.TryCreate($"{b}/v1/room/{RelayLink.Encode(_share.Room)}?role=phone", UriKind.Absolute, out var url)) return;
            using var ws = new ClientWebSocket();
            ws.Options.SetRequestHeader("Authorization", $"Bearer {_share.Secret}");
            ws.Options.CollectHttpResponseDetails = true;
            try
            {
                await ws.ConnectAsync(url, _stop.Token);
                _ws = ws;
                Send(new { t = "hello", device = Environment.MachineName });
                backoff = 1;
                OnOpen?.Invoke();
                using var ping = new System.Threading.Timer(_ => _ = SendRaw(Encoding.UTF8.GetBytes("ping"), WebSocketMessageType.Text),
                                                            null, TimeSpan.FromSeconds(25), TimeSpan.FromSeconds(25));
                await Receive(ws);
            }
            catch (Exception) when (!_stop.IsCancellationRequested)
            {
                if (ws.HttpStatusCode == System.Net.HttpStatusCode.NotFound) OnGone?.Invoke();
            }
            catch { return; }
            _ws = null;
            if (_stop.IsCancellationRequested) return;
            try { await Task.Delay(TimeSpan.FromSeconds(backoff), _stop.Token); } catch { return; }
            backoff = Math.Min(30, backoff * 2);
        }
    }

    private async Task Receive(ClientWebSocket ws)
    {
        var buffer = new byte[64 * 1024];
        using var message = new MemoryStream();
        while (ws.State == WebSocketState.Open && !_stop.IsCancellationRequested)
        {
            var r = await ws.ReceiveAsync(buffer, _stop.Token);
            if (r.MessageType == WebSocketMessageType.Close) return;
            message.Write(buffer, 0, r.Count);
            if (!r.EndOfMessage) continue;
            var bytes = message.ToArray();
            message.SetLength(0);
            if (r.MessageType == WebSocketMessageType.Binary)
            {
                if (_seal.OpenBinary(bytes) is { } audio) OnAudio?.Invoke(audio.Data);
                continue;
            }
            var text = Encoding.UTF8.GetString(bytes);
            if (text == "pong" || _seal.OpenText(text) is not { } opened) continue;
            try
            {
                using var doc = JsonDocument.Parse(opened.Json);
                OnFrame?.Invoke(doc.RootElement.Clone());
            }
            catch (JsonException) { }
        }
    }
}

/// A call on the PC: the mic as 16 kHz PCM16 frames of 20 ms up, Parley's 24 kHz voice down into
/// a buffered player. (No echo cancellation on Windows, as the host's own barge-in.)
public sealed class GuestCallAudio : IDisposable
{
    private const double UpRate = 16000.0;
    private readonly WasapiCapture _capture = new();
    private readonly BufferedWaveProvider _down = new(new WaveFormat(24000, 16, 1))
    {
        BufferLength = 24000 * 2 * 60,
        DiscardOnBufferOverflow = true,
        ReadFully = true,   // silence while nothing is queued: the player keeps running
    };
    private readonly WasapiOut _out = new(AudioClientShareMode.Shared, 100);

    public void Start(Action<byte[]> send)
    {
        var fmt = _capture.WaveFormat;
        var ratio = fmt.SampleRate / UpRate;
        double pos = 0;
        float prev = 0;
        var pending = new List<byte>();
        _capture.DataAvailable += (_, e) =>
        {
            var mono = MicCapture.ToMonoFloats(e.Buffer, e.BytesRecorded, fmt, fmt.Channels);
            foreach (var f in mono)
            {
                while (pos < 1.0)
                {
                    var s = (short)Math.Clamp((prev + (f - prev) * (float)pos) * short.MaxValue, short.MinValue, short.MaxValue);
                    pending.Add((byte)s);
                    pending.Add((byte)(s >> 8));
                    pos += ratio;
                }
                pos -= 1.0;
                prev = f;
            }
            while (pending.Count >= 640)
            {
                send(pending.GetRange(0, 640).ToArray());
                pending.RemoveRange(0, 640);
            }
        };
        _out.Init(_down);
        _out.Play();
        _capture.StartRecording();
    }

    /// One frame of Parley's voice: 960 bytes = 24 kHz, 640 = 16 kHz (an older host).
    public void Play(byte[] pcm)
    {
        if (pcm.Length == 640) pcm = Up16To24(pcm);
        _down.AddSamples(pcm, 0, pcm.Length);
    }

    public bool Drained => _down.BufferedBytes == 0;

    private static byte[] Up16To24(byte[] pcm)
    {
        var n = pcm.Length / 2;
        var outN = n * 3 / 2;
        var o = new byte[outN * 2];
        for (var i = 0; i < outN; i++)
        {
            var src = i * 2.0 / 3.0;
            var a = (int)src;
            var b = Math.Min(n - 1, a + 1);
            var sa = BitConverter.ToInt16(pcm, a * 2);
            var sb = BitConverter.ToInt16(pcm, b * 2);
            var v = (short)(sa + (sb - sa) * (src - a));
            o[i * 2] = (byte)v;
            o[i * 2 + 1] = (byte)(v >> 8);
        }
        return o;
    }

    public void Dispose()
    {
        try { _capture.StopRecording(); } catch { }
        try { _out.Stop(); } catch { }
        _capture.Dispose();
        _out.Dispose();
    }
}

/// The guest side for the tray panel: the shares, their session rows, ringing and the one call.
/// Frames arrive on socket threads; everything here is under one lock, the panel reads it on paint.
public static class GuestHub
{
    private static readonly object Gate = new();
    private static readonly List<GuestShare> List = GuestShare.Load();
    private static readonly Dictionary<string, GuestLink> Links = new();
    private static readonly Dictionary<string, JsonElement> RowsById = new();   // share id → its session row
    private static readonly Dictionary<string, DateTime> RingingSince = new();
    private static GuestCallAudio? _audio;
    private static string _hostAudio = "idle";

    public static string? InCall { get; private set; }
    public static string? Notice { get; private set; }

    public static List<GuestShare> Shares { get { lock (Gate) return List.ToList(); } }
    public static JsonElement? Row(string id) { lock (Gate) return RowsById.TryGetValue(id, out var r) ? r : null; }
    public static bool Ringing(string id)
    {
        lock (Gate) return RingingSince.TryGetValue(id, out var at) && DateTime.UtcNow - at < TimeSpan.FromSeconds(40);
    }

    public static void Start()
    {
        foreach (var s in Shares) Connect(s);
    }

    // ---- join / leave ----------------------------------------------------------------------

    /// The panel's "Beitreten": the invite link and a name.
    public static void AskToJoin()
    {
        var clip = "";
        try { if (Clipboard.ContainsText() && Clipboard.GetText().Contains("join")) clip = Clipboard.GetText().Trim(); } catch { }
        using var form = new Form
        {
            Text = "Geteilte Session beitreten",
            FormBorderStyle = FormBorderStyle.FixedDialog,
            StartPosition = FormStartPosition.CenterScreen,
            MinimizeBox = false, MaximizeBox = false, ShowInTaskbar = false, TopMost = true,
            AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
            AutoScaleMode = AutoScaleMode.Dpi, AutoScaleDimensions = new SizeF(96f, 96f),
        };
        var layout = new TableLayoutPanel { AutoSize = true, ColumnCount = 1, Padding = new Padding(12) };
        layout.Controls.Add(new Label { Text = "Füge den Einladungslink ein, den du bekommen hast.", AutoSize = true, Margin = new Padding(0, 0, 0, 8) });
        var link = new TextBox { PlaceholderText = "https://…/join#…", Width = 360, Text = clip, Margin = new Padding(0, 0, 0, 8) };
        var name = new TextBox { PlaceholderText = "Dein Name", Width = 360, Text = Environment.UserName, Margin = new Padding(0, 0, 0, 12) };
        layout.Controls.Add(link);
        layout.Controls.Add(name);
        var buttons = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.RightToLeft, Anchor = AnchorStyles.Right, Margin = Padding.Empty };
        var no = new Button { Text = "Abbrechen", DialogResult = DialogResult.Cancel, AutoSize = true };
        var yes = new Button { Text = "Beitreten", DialogResult = DialogResult.OK, AutoSize = true };
        buttons.Controls.Add(no);
        buttons.Controls.Add(yes);
        layout.Controls.Add(buttons);
        form.Controls.Add(layout);
        form.AcceptButton = yes;
        form.CancelButton = no;
        if (form.ShowDialog() != DialogResult.OK) return;
        if (GuestShare.Parse(link.Text, name.Text) is not { } s)
        {
            Notice = "Das ist kein gültiger Einladungslink.";
            return;
        }
        Notice = null;
        lock (Gate) List.Add(s);
        GuestShare.Save(Shares);
        Log.Write($"guest: joining {s.Label}");
        Connect(s);
    }

    public static void Leave(string id)
    {
        if (InCall == id) EndCall();
        GuestLink? link;
        lock (Gate)
        {
            Links.Remove(id, out link);
            List.RemoveAll(s => s.Id == id);
            RowsById.Remove(id);
            RingingSince.Remove(id);
        }
        link?.Stop();
        GuestShare.Save(Shares);
    }

    // ---- the room --------------------------------------------------------------------------

    private static void Connect(GuestShare s)
    {
        if (GuestLink.Create(s) is not { } link) return;
        var id = s.Id;
        link.OnOpen = () => Opened(id);
        link.OnFrame = f => Frame(id, f);
        link.OnAudio = pcm => { if (InCall == id) _audio?.Play(pcm); };
        link.OnGone = () =>
        {
            if (Find(id) is not { Active: false } g) return;
            Notice = $"Einladung für „{g.Label}“ abgelaufen oder schon benutzt.";
            Leave(id);
        };
        lock (Gate) Links[id] = link;
        link.Start();
    }

    private static GuestShare? Find(string id) { lock (Gate) return List.FirstOrDefault(s => s.Id == id); }
    private static GuestLink? LinkOf(string id) { lock (Gate) return Links.TryGetValue(id, out var l) ? l : null; }

    private static void Opened(string id)
    {
        if (Find(id) is not { } s) return;
        if (!s.Active)
            LinkOf(id)?.Send(new { t = "join", name = s.Name, device = Environment.MachineName, pub = s.Pub, who = Who });
        else if (InCall == id)
            LinkOf(id)?.Send(new { t = "call", state = "start", down = 24000 });   // a redial mid-call keeps the call
    }

    private static string? Str(JsonElement f, string key) =>
        f.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static void Frame(string id, JsonElement f)
    {
        switch (Str(f, "t"))
        {
            case "move":
            {
                if (Find(id) is not { Active: false } s || Str(f, "pub") is not { } pub || Str(f, "box") is not { } box
                    || Str(f, "share") is not { } share || s.OpenMove(pub, box, share) is not { } room) return;
                lock (Gate)
                {
                    s.Room = room.Room; s.Secret = room.Secret; s.Key = room.Key;
                    s.Share = share;
                    s.Role = Str(f, "role") ?? "";
                    s.Listen = f.TryGetProperty("listen", out var l) && l.ValueKind == JsonValueKind.True;
                    s.Active = true;
                }
                GuestShare.Save(Shares);
                Log.Write($"guest: {s.Label} — let in");
                GuestLink? old;
                lock (Gate) Links.Remove(id, out old);
                old?.Stop();
                Connect(s);
                break;
            }
            case "share-end":
                if (Find(id) is { } g) Notice = $"{(g.Host.Length == 0 ? "Der Gastgeber" : g.Host)} hat die Freigabe für „{g.Label}“ beendet.";
                Leave(id);
                break;
            case "sessions":
                if (f.TryGetProperty("sessions", out var list) && list.ValueKind == JsonValueKind.Array)
                    lock (Gate)
                    {
                        if (list.GetArrayLength() > 0) RowsById[id] = list[0].Clone();
                        else RowsById.Remove(id);
                    }
                break;
            case "ring":
                if (InCall is not null) return;
                lock (Gate) RingingSince[id] = DateTime.UtcNow;
                Notifier.Notify($"Parley · {Str(f, "label") ?? "Anruf"}", "Im Parley-Panel annehmen");
                break;
            case "audio":
            {
                var state = Str(f, "state") ?? "idle";
                var was = _hostAudio;
                _hostAudio = state;
                if (InCall == id && state == "idle" && was != "idle") HangUpWhenPlayed();
                break;
            }
            case "notice":
                Notice = Str(f, "text");
                break;
        }
    }

    // ---- the call --------------------------------------------------------------------------

    /// "Anrufen" (or "Annehmen" while it rings).
    public static void Call(string id)
    {
        if (InCall is not null || LinkOf(id) is not { } link || Find(id) is not { Active: true }) return;
        var audio = new GuestCallAudio();
        try { audio.Start(link.SendAudio); }
        catch (Exception e)
        {
            audio.Dispose();
            Notice = $"Mikrofon nicht verfügbar: {e.Message}";
            return;
        }
        _audio = audio;
        InCall = id;
        lock (Gate) RingingSince.Remove(id);
        _hostAudio = "idle";
        link.Send(new { t = "call", state = "start", down = 24000 });
        Log.Write("guest: call started");
    }

    public static void Decline(string id)
    {
        lock (Gate) RingingSince.Remove(id);
        LinkOf(id)?.Send(new { t = "call", state = "end" });
    }

    public static void EndCall()
    {
        if (InCall is not { } id) return;
        LinkOf(id)?.Send(new { t = "call", state = "end" });
        _audio?.Dispose();
        _audio = null;
        InCall = null;
        Log.Write("guest: call ended");
    }

    // Parley is done (audio idle after speaking): hang up once the last frame has played.
    private static void HangUpWhenPlayed() => _ = Task.Run(async () =>
    {
        for (var i = 0; i < 100; i++)
        {
            if (InCall is null || _hostAudio != "idle") return;
            if (_audio?.Drained != false) { EndCall(); return; }
            await Task.Delay(50);
        }
        EndCall();
    });

    // The same "who" on every join (S3: Sir's phone offers his roles of before).
    private static string Who
    {
        get
        {
            var file = Path.Combine(Config.Dir, "guest-who.txt");
            try { if (System.IO.File.Exists(file)) return System.IO.File.ReadAllText(file).Trim(); } catch { }
            var w = Guid.NewGuid().ToString();
            try { Directory.CreateDirectory(Config.Dir); System.IO.File.WriteAllText(file, w); } catch { }
            return w;
        }
    }
}
