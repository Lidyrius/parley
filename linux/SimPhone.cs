using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;

namespace Parley;

// A stand-in phone for tests (`parley sim-phone <parley://pair?…>`): joins the pairing link's
// relay room as role=phone — sealed with the same RelaySeal as the host and the real apps — says
// hello and prints what the host sends.
//   --say <session id or name> <text>   writes to that session once it is listed (the phone's text field)
//   --answer                            takes a ringing call; hangs up when the host is done (`audio` idle)
//   --mic-say <text>                    (takes the call, and) once the host listens, says <text> into the
//                                       call's microphone — Google TTS, as the host's own voice — then is silent
//   --mic-say @<file>                   the same with a recording (raw PCM16 mono 16 kHz, or a --save .wav): no key needed
//   --save <file>                       the host's voice as heard on the call: raw PCM16 mono 16 kHz, or a
//                                       WAV when the name ends in .wav
//   --seconds N                         give up after N s (20; 180 with a call)
// The call is a plain one (no "v":8): the host streams its voice in 20 ms frames and takes the
// microphone as a stream of 20 ms frames, unnumbered — what phones before v8 do.
// Exit 1: the room could not be joined, the session to write to never showed up, no ring came,
// the host never listened, or --mic-say could not be synthesized (no Google key).
internal static class SimPhone
{
    public static async Task<int> Run(string[] args)
    {
        if (args.Length == 0 || Parse(args[0]) is not { } c || RelaySeal.Create(c.Key) is not { } seal || RelayLink.SocketBase(c.Url) is not { } socket)
        {
            Console.Error.WriteLine("sim-phone: give the pairing link (parley://pair?u=…&r=…&k=…&e=…) as `parley pair` prints it");
            return 2;
        }
        System.Globalization.CultureInfo.CurrentCulture = System.Globalization.CultureInfo.InvariantCulture;   // "2.5 s" whatever the locale
        int? limit = null;
        string? sayTo = null, sayText = null, micSay = null, save = null;
        var answer = false;
        for (var i = 1; i < args.Length; i++)
        {
            if (args[i] == "--seconds" && i + 1 < args.Length && int.TryParse(args[i + 1], out var n)) { limit = n; i++; }
            else if (args[i] == "--say" && i + 2 < args.Length) { sayTo = args[i + 1]; sayText = args[i + 2]; i += 2; }
            else if (args[i] == "--mic-say" && i + 1 < args.Length) { micSay = args[++i]; answer = true; }
            else if (args[i] == "--save" && i + 1 < args.Length) save = args[++i];
            else if (args[i] == "--answer") answer = true;
            else { Console.Error.WriteLine($"sim-phone: don't know {args[i]}"); return 2; }
        }
        var seconds = limit ?? (answer ? 180 : 20);

        // What the phone will say, ready before it joins: its microphone's 20 ms frames at 16 kHz.
        List<byte[]>? speech = null;
        if (micSay is { Length: > 1 } && micSay[0] == '@')   // a recording instead: raw PCM16 mono 16 kHz, or a --save .wav
        {
            byte[] recorded;
            try { recorded = File.ReadAllBytes(micSay[1..]); }
            catch (Exception e)
            {
                Console.WriteLine($"sim-phone: --mic-say {micSay}: {e.Message}. Nothing sent.");
                return 1;
            }
            if (recorded.Length > 44 && Encoding.ASCII.GetString(recorded, 0, 4) == "RIFF") recorded = recorded[44..];
            speech = PhoneAudio.Frames(PhoneAudio.ToSamples(recorded));
            Console.WriteLine($"sim-phone: {micSay[1..]} is {speech.Count * PhoneAudio.FrameMs / 1000.0:0.0} s of sound");
        }
        else if (micSay is not null)
        {
            var config = Config.Load();
            if (!config.UseGoogle)
            {
                Console.WriteLine($"sim-phone: --mic-say needs the Google TTS key — there is no googleAPIKey in {Config.CredentialsPath}. Nothing sent.");
                return 1;
            }
            if (await GoogleTts.Synthesize(micSay, config) is not { } tts)
            {
                Console.WriteLine("sim-phone: Google TTS gave no audio for --mic-say (why is in debug.log). Nothing sent.");
                return 1;
            }
            speech = PhoneAudio.FramesFor(tts, GoogleTts.SampleRate);
            Console.WriteLine($"sim-phone: \"{micSay}\" is {speech.Count * PhoneAudio.FrameMs / 1000.0:0.0} s of speech");
        }

        var uri = new Uri($"{socket}/v1/room/{RelayLink.Encode(c.Room)}?role=phone");
        using var ws = new ClientWebSocket();
        ws.Options.SetRequestHeader("Authorization", "Bearer " + c.Secret);
        try
        {
            using var connect = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            await ws.ConnectAsync(uri, connect.Token);
        }
        catch (Exception e)
        {
            Console.WriteLine($"sim-phone: could not join the room on {uri.Host} ({e.Message}) — does `parley run` have it open?");
            return 1;
        }
        Console.WriteLine($"sim-phone: in the room on {uri.Host} as a phone, for up to {seconds} s");

        using var gate = new SemaphoreSlim(1, 1);   // one send at a time: frames and the call's microphone
        long Now() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        async Task Send(byte[] data, WebSocketMessageType type)
        {
            await gate.WaitAsync();
            try { await ws.SendAsync(new ArraySegment<byte>(data), type, true, CancellationToken.None); }
            finally { gate.Release(); }
        }
        Task Frame(string json)
        {
            Console.WriteLine("→ " + json);
            return Send(Encoding.UTF8.GetBytes(seal.Text(json, Now())!), WebSocketMessageType.Text);
        }
        string Str(JsonElement e, string k) => e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString()! : "";

        var deadline = DateTime.UtcNow.AddSeconds(seconds);
        var said = sayTo is null;
        var busy = false;    // the host spoke or listened on this call
        var spoke = false;   // --mic-say went into the microphone
        var done = false;    // the host went idle after that: the turn is over
        int frames = 0, clips = 0;
        using var voice = new MemoryStream();   // the host's voice, as it arrived
        var toSay = new ConcurrentQueue<byte[]>();
        using var hangUp = new CancellationTokenSource();
        Task? microphone = null;
        try
        {
            await Frame(JsonSerializer.Serialize(new { t = "hello", device = "sim-phone" }));
            var buffer = new byte[64 * 1024];
            using var frame = new MemoryStream();
            while (!done)
            {
                var receive = ws.ReceiveAsync(new ArraySegment<byte>(buffer), CancellationToken.None);
                var left = deadline - DateTime.UtcNow;
                if (left <= TimeSpan.Zero || await Task.WhenAny(receive, Task.Delay(left)) != receive)
                {
                    Console.WriteLine($"sim-phone: {seconds} s are over");
                    break;
                }
                var r = await receive;
                if (r.MessageType == WebSocketMessageType.Close)
                {
                    Console.WriteLine($"sim-phone: the relay closed the room ({r.CloseStatus} {r.CloseStatusDescription})");
                    return 1;
                }
                frame.Write(buffer, 0, r.Count);
                if (!r.EndOfMessage) continue;
                var bytes = frame.ToArray();
                frame.SetLength(0);

                if (r.MessageType == WebSocketMessageType.Binary)   // the host's voice: 20 ms PCM frames
                {
                    if (seal.OpenBinary(bytes) is not { } pcm) continue;
                    voice.Write(pcm.Data);
                    if (++frames == 1 || frames % 50 == 0) Console.WriteLine($"← voice: frame {frames} ({pcm.Data.Length} bytes PCM)");
                    continue;
                }
                var text = Encoding.UTF8.GetString(bytes);
                if (text == "pong") continue;
                if (seal.OpenText(text) is not { } opened)   // the relay's own frames (`peer`) are not sealed
                {
                    Console.WriteLine("← (relay) " + Clip(text));
                    continue;
                }
                using var doc = JsonDocument.Parse(opened.Json);
                var root = doc.RootElement;
                switch (Str(root, "t"))
                {
                    case "sessions":
                        var rows = root.TryGetProperty("sessions", out var list) ? list.EnumerateArray().ToList() : new List<JsonElement>();
                        Console.WriteLine($"← sessions: {rows.Count}" + string.Concat(rows.Select(s => $"\n    {Str(s, "state"),-10} {Str(s, "label"),-24} {Str(s, "id")}")));
                        if (said) break;
                        var target = rows.FirstOrDefault(s => Str(s, "id") == sayTo || string.Equals(Str(s, "label"), sayTo, StringComparison.OrdinalIgnoreCase));
                        if (target.ValueKind != JsonValueKind.Object) break;   // not listed yet: the next overview may have it
                        said = true;
                        await Frame(JsonSerializer.Serialize(new { t = "say", id = Str(target, "id"), text = sayText }));
                        break;
                    case "ring":
                        Console.WriteLine("← " + opened.Json);
                        if (!answer || microphone is not null) break;
                        await Frame("{\"t\":\"call\",\"state\":\"start\"}");
                        // In a call the phone streams its microphone all the time, 20 ms a frame at
                        // the wall clock's pace: what it has to say, else silence.
                        microphone = Task.Run(async () =>
                        {
                            var clock = Stopwatch.StartNew();
                            var silence = new byte[PhoneAudio.FrameBytes];
                            for (long sent = 1; !hangUp.IsCancellationRequested; sent++)
                            {
                                var speaking = toSay.TryDequeue(out var words);
                                await Send(seal.Binary(speaking ? words! : silence, Now()), WebSocketMessageType.Binary);
                                if (speaking && toSay.IsEmpty) Console.WriteLine("→ microphone: said — silent now (the host's VAD ends the reply)");
                                var wait = sent * PhoneAudio.FrameMs - clock.ElapsedMilliseconds;
                                if (wait > 0) await Task.Delay((int)wait);
                            }
                        });
                        break;
                    case "audio":   // what the host does with the call: speaking | listening | idle
                        Console.WriteLine("← " + opened.Json);
                        if (microphone is null) break;
                        var state = Str(root, "state");
                        if (state != "idle") busy = true;
                        if (state == "listening" && speech is not null && !spoke)
                        {
                            spoke = true;
                            Console.WriteLine($"→ microphone: \"{micSay}\"");
                            foreach (var f in speech) toSay.Enqueue(f);
                        }
                        if (state == "idle" && busy)
                        {
                            Console.WriteLine("sim-phone: the host is done with the call — hanging up");
                            done = true;
                        }
                        break;
                    case "caption":   // the line the host speaks next, word by word
                        var line = root.TryGetProperty("words", out var w) && w.ValueKind == JsonValueKind.Array
                            ? string.Join(" ", w.EnumerateArray().Select(x => x.GetString())) : "";
                        Console.WriteLine($"← caption: \"{line}\"{(root.TryGetProperty("last", out var l) && l.ValueKind == JsonValueKind.True ? " (last)" : "")}");
                        break;
                    case "clip":
                        clips++;
                        Console.WriteLine("← " + opened.Json);
                        break;
                    default:
                        Console.WriteLine("← " + Clip(opened.Json));
                        break;
                }
            }
        }
        catch (Exception e)
        {
            Console.WriteLine($"sim-phone: the connection broke ({e.Message})");
            return 1;
        }
        finally
        {
            hangUp.Cancel();
            try
            {
                if (microphone is not null)
                {
                    await microphone;
                    await Frame("{\"t\":\"call\",\"state\":\"end\"}");
                }
                using var closing = new CancellationTokenSource(TimeSpan.FromSeconds(2));
                await ws.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, null, closing.Token);
            }
            catch (Exception) { /* the room is gone already */ }
        }

        if (microphone is not null)
            Console.WriteLine($"sim-phone: the host's voice on the call — {frames} frames (streamed; {clips} clips), {voice.Length} bytes PCM16 mono at " +
                $"{PhoneAudio.SampleRate} Hz = {voice.Length / 2.0 / PhoneAudio.SampleRate:0.00} s");
        if (save is not null && voice.Length > 0)
        {
            var wav = save.EndsWith(".wav", StringComparison.OrdinalIgnoreCase);
            File.WriteAllBytes(save, wav ? Wav.Encode(PhoneAudio.ToSamples(voice.ToArray()), PhoneAudio.SampleRate) : voice.ToArray());
            Console.WriteLine($"sim-phone: saved to {save}" + (wav ? "" : $" (ffplay -f s16le -ar {PhoneAudio.SampleRate} -ac 1 {save})"));
        }
        var failed = false;
        void Fail(string why) { failed = true; Console.WriteLine("sim-phone: " + why); }
        if (!said) Fail($"no session \"{sayTo}\" was listed — nothing sent");
        if (answer && microphone is null) Fail("no ring came");
        if (speech is not null && microphone is not null && !spoke) Fail("the host never listened — nothing said");
        return failed ? 1 : 0;
    }

    // parley://pair?u=<relay>&r=<room>&k=<secret>&e=<key> (RelayLink.Pairing) → its settings.
    private static RelayConfig? Parse(string link)
    {
        var q = link.IndexOf('?');
        if (q < 0 || !link.StartsWith("parley://pair", StringComparison.Ordinal)) return null;
        var p = link[(q + 1)..].Split('&').Select(kv => kv.Split('=', 2)).Where(kv => kv.Length == 2)
            .GroupBy(kv => kv[0]).ToDictionary(g => g.Key, g => Uri.UnescapeDataString(g.First()[1]));
        return p.TryGetValue("u", out var u) && p.TryGetValue("r", out var r) && p.TryGetValue("k", out var k)
            ? new RelayConfig(u, r, k, p.GetValueOrDefault("e", "")) : null;
    }

    private static string Clip(string s) => s.Length > 300 ? s[..300] + "…" : s;
}
