using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Parley;

// Protocol v10 (docs/IPHONE.md): Hinweise — lines in `alertsFile` that need Sir outside any session
// (a lost login in a server's browser) — and the desktops (VNC) the phone opens through the relay
// to fix them. 1:1 with the macOS host.
public static class Alerts
{
    public sealed record Alert(string Id, string Text, long Since, string? Desktop);

    private static readonly object Gate = new();
    private static Dictionary<string, Alert> _now = new();
    private static List<string> _desktops = new();
    private static bool _checking;
    private static Action<string, string>? _push;

    // `[saf] Teams LOGIN NÖTIG` → desktop "saf"; a line without brackets has none. Pure.
    public static Alert? Parse(string line, long since)
    {
        line = line.Trim();
        if (line.Length == 0) return null;
        var id = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(line)))[..16].ToLowerInvariant();
        var m = Regex.Match(line, @"^\[([^\]\s]+)\]\s*(.*)$");
        return m.Success && m.Groups[2].Value.Length > 0
            ? new Alert(id, m.Groups[2].Value, since, m.Groups[1].Value)
            : new Alert(id, line, since, null);
    }

    // The Wachhund's 30 s tick: read the file, push each line not seen before (`push(title, body)`).
    public static void Tick(Config c, Action<string, string> push)
    {
        _push = push;
        var lines = new List<string>();
        if (c.AlertsFile.Length > 0)
            try { if (File.Exists(c.AlertsFile)) lines.AddRange(File.ReadAllLines(c.AlertsFile)); }
            catch (IOException) { return; }   // being rewritten: next tick
        var now = (long)(DateTime.UtcNow - DateTime.UnixEpoch).TotalMilliseconds;
        var fresh = new List<Alert>();
        lock (Gate)
        {
            _desktops = c.Vnc.Keys.OrderBy(k => k, StringComparer.Ordinal).ToList();
            var next = new Dictionary<string, Alert>();
            foreach (var line in lines)
            {
                if (Parse(line, now) is not { } a || next.ContainsKey(a.Id)) continue;
                if (_now.TryGetValue(a.Id, out var seen)) next[a.Id] = seen;
                else { next[a.Id] = a; fresh.Add(a); }
            }
            _now = next;
        }
        foreach (var a in fresh)
        {
            Log.Write($"alerts: {a.Text}");
            push($"Parley · {c.HostName}", a.Text);
        }
    }

    // Phone `{"t":"alerts","op":"check"}`: run `alertsCheck` once in the background.
    public static void Check(Config c)
    {
        if (c.AlertsCheck.Length == 0) return;
        lock (Gate) { if (_checking) return; _checking = true; }
        _ = Task.Run(() =>
        {
            try
            {
                var shell = OperatingSystem.IsWindows() ? ("cmd.exe", "/c") : ("/bin/sh", "-c");
                var psi = new System.Diagnostics.ProcessStartInfo(shell.Item1) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
                psi.ArgumentList.Add(shell.Item2);
                psi.ArgumentList.Add(c.AlertsCheck);
                using var p = System.Diagnostics.Process.Start(psi);
                if (p is not null)
                {
                    _ = p.StandardOutput.ReadToEndAsync(); _ = p.StandardError.ReadToEndAsync();
                    if (!p.WaitForExit(TimeSpan.FromMinutes(10))) p.Kill(true);
                }
            }
            catch (Exception e) { Log.Write($"alerts: check failed: {e.Message}"); }
            finally
            {
                lock (Gate) _checking = false;
                if (_push is { } push) Tick(Config.Load(), push);   // the result shows in the next sessions frame
            }
        });
    }

    // For /sessions: (alerts or null, checking or null, desktops or null) — null = omitted.
    public static (List<object>? Alerts, bool? Checking, List<string>? Desktops) Wire()
    {
        lock (Gate)
            return (_now.Count > 0 ? _now.Values.OrderBy(a => a.Since).Select(a => (object)(a.Desktop is null
                        ? new { id = a.Id, text = a.Text, since = a.Since }
                        : new { id = a.Id, text = a.Text, since = a.Since, desktop = a.Desktop })).ToList() : null,
                    _checking ? true : null,
                    _desktops.Count > 0 ? _desktops : null);
    }
}

// The phone's desktop channels: RFB bytes between `vnc` frames and a websockify (ws://) or plain
// RFB (tcp://) endpoint. At most 2 channels; 10 min without the phone's data closes one.
public static class Desktops
{
    public static Func<string, Task>? Send;   // a text frame to the phones (sealed by the relay client)

    private const int Chunk = 48 * 1024;
    private static readonly object Gate = new();
    private static readonly List<Tunnel> Open = new();

    private sealed class Tunnel
    {
        public required string Ch;
        public DateTime LastIn = DateTime.UtcNow;
        public readonly CancellationTokenSource Cts = new();
        public readonly System.Threading.Channels.Channel<byte[]> ToDesktop = System.Threading.Channels.Channel.CreateUnbounded<byte[]>();
    }

    public static bool ValidChannel(string ch) => Regex.IsMatch(ch, "^[A-Za-z0-9]{8,32}$");

    private static Task Reply(object frame) => Send?.Invoke(JsonSerializer.Serialize(frame)) ?? Task.CompletedTask;

    public static void OnPhone(PhoneVnc v, Func<Config> config)
    {
        if (!ValidChannel(v.Ch)) return;
        switch (v.Op)
        {
            case "open": OpenChannel(v.Ch, v.Desktop ?? "", config()); break;
            case "close": Close(v.Ch, tell: false); break;
            default:
                Tunnel? t;
                lock (Gate) t = Open.Find(x => x.Ch == v.Ch);
                if (t is null || v.Data is null) return;
                t.LastIn = DateTime.UtcNow;
                t.ToDesktop.Writer.TryWrite(v.Data);
                break;
        }
    }

    private static void OpenChannel(string ch, string desktop, Config c)
    {
        if (!c.Vnc.TryGetValue(desktop, out var target))
        {
            _ = Reply(new { t = "vnc", op = "open", ch, ok = false, error = "Diesen Desktop gibt es hier nicht." });
            return;
        }
        Tunnel tunnel;
        lock (Gate)
        {
            if (Open.Any(x => x.Ch == ch)) return;
            while (Open.Count >= 2) { var old = Open[0]; Open.RemoveAt(0); Stop(old, tell: true); }
            tunnel = new Tunnel { Ch = ch };
            Open.Add(tunnel);
        }
        Log.Write($"vnc: {desktop} opened");
        _ = Task.Run(() => Run(tunnel, target));
    }

    private static async Task Run(Tunnel t, VncTarget target)
    {
        var token = t.Cts.Token;
        ClientWebSocket? ws = null; TcpClient? tcp = null;
        try
        {
            Func<byte[], Task> write; Func<byte[], Task<int>> read;
            var uri = new Uri(target.Url);
            using var connect = CancellationTokenSource.CreateLinkedTokenSource(token);
            connect.CancelAfter(TimeSpan.FromSeconds(10));
            if (uri.Scheme is "ws" or "wss")
            {
                ws = new ClientWebSocket();
                ws.Options.AddSubProtocol("binary");
                await ws.ConnectAsync(uri, connect.Token);
                write = b => ws.SendAsync(b, WebSocketMessageType.Binary, true, token);
                read = async b =>
                {
                    var r = await ws.ReceiveAsync(b, token);
                    return r.MessageType == WebSocketMessageType.Close ? 0 : r.Count;
                };
            }
            else if (uri.Scheme == "tcp")
            {
                tcp = new TcpClient();
                await tcp.ConnectAsync(uri.Host, uri.Port, connect.Token);
                var stream = tcp.GetStream();
                write = b => stream.WriteAsync(b, token).AsTask();
                read = b => stream.ReadAsync(b, token).AsTask();
            }
            else throw new InvalidOperationException($"unknown scheme {uri.Scheme}");

            await Reply(new { t = "vnc", op = "open", ch = t.Ch, ok = true, password = target.Password });
            var pump = Task.Run(async () =>
            {
                await foreach (var b in t.ToDesktop.Reader.ReadAllAsync(token)) await write(b);
            }, token);
            var buf = new byte[Chunk];
            while (!token.IsCancellationRequested)
            {
                var n = await read(buf);
                if (n <= 0) break;
                await Reply(new { t = "vnc", ch = t.Ch, d = Convert.ToBase64String(buf, 0, n) });
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { return; }
        catch (Exception e)
        {
            Log.Write($"vnc: {e.Message}");
            bool fresh;
            lock (Gate) fresh = Open.Contains(t);
            if (fresh) await Reply(new { t = "vnc", op = "open", ch = t.Ch, ok = false, error = "Desktop nicht erreichbar." });
        }
        finally
        {
            ws?.Dispose(); tcp?.Dispose();
            Close(t.Ch, tell: true);
        }
    }

    public static void Close(string ch, bool tell)
    {
        Tunnel? t;
        lock (Gate) { t = Open.Find(x => x.Ch == ch); if (t is not null) Open.Remove(t); }
        if (t is not null) Stop(t, tell);
    }

    private static void Stop(Tunnel t, bool tell)
    {
        t.Cts.Cancel();
        t.ToDesktop.Writer.TryComplete();
        if (tell) _ = Reply(new { t = "vnc", op = "close", ch = t.Ch });
        Log.Write("vnc: closed");
    }

    // The relay connection came (back): the phone's side of every channel is gone.
    public static void CloseAll()
    {
        List<Tunnel> all;
        lock (Gate) { all = Open.ToList(); Open.Clear(); }
        foreach (var t in all) Stop(t, tell: false);
    }

    // The 30 s tick: a channel the phone stopped feeding for 10 min closes.
    public static void Tick()
    {
        List<Tunnel> idle;
        lock (Gate) { idle = Open.Where(t => DateTime.UtcNow - t.LastIn > TimeSpan.FromMinutes(10)).ToList(); Open.RemoveAll(idle.Contains); }
        foreach (var t in idle) Stop(t, tell: true);
    }
}

public sealed record VncTarget(string Url, string Password);
