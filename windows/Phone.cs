using System.Buffers.Binary;
using System.Diagnostics;

namespace Parley;

// Calls through the iPhone (docs/IPHONE.md, protocol v2), 1:1 with the macOS host. While the
// phone's CallKit call is connected, ALL of Parley's audio goes through it: TTS, beep, clips
// and permission questions out as paced 20 ms frames, listening in from the phone's mic — the
// PC's speaker and mic stay quiet. The phone learns what the host does from `audio` frames.

// The call audio format, pure: raw PCM 16-bit LE, mono, 16 kHz, one frame per 20 ms (640 bytes).
public static class PhoneAudio
{
    public const int SampleRate = 16000;
    public const int FrameMs = 20;
    public const int FrameSamples = SampleRate * FrameMs / 1000;   // 320
    public const int FrameBytes = FrameSamples * 2;                 // 640
    // A phone that asks for it (`call start` with "down":24000) gets Parley's voice at the TTS's
    // own 24 kHz — no resampling, the full band; older phones get 16 kHz. The mic stays 16 kHz.
    public const int HiFiRate = 24000;

    public static short[] ToSamples(ReadOnlySpan<byte> pcm)
    {
        var samples = new short[pcm.Length / 2];
        for (var i = 0; i < samples.Length; i++)
            samples[i] = BinaryPrimitives.ReadInt16LittleEndian(pcm.Slice(i * 2, 2));
        return samples;
    }

    public static byte[] ToBytes(ReadOnlySpan<short> samples)
    {
        var pcm = new byte[samples.Length * 2];
        for (var i = 0; i < samples.Length; i++)
            BinaryPrimitives.WriteInt16LittleEndian(pcm.AsSpan(i * 2, 2), samples[i]);
        return pcm;
    }

    // Linear interpolation, like the mic path's resampler — fine for speech. The TTS runs at
    // 24 kHz; 24 → 16 kHz keeps everything below 8 kHz, which is all a call carries anyway.
    public static short[] Resample(ReadOnlySpan<short> input, int fromRate, int toRate)
    {
        if (fromRate == toRate || input.Length == 0 || fromRate <= 0 || toRate <= 0) return input.ToArray();
        var output = new short[(int)((long)input.Length * toRate / fromRate)];
        var step = (double)fromRate / toRate;
        for (var i = 0; i < output.Length; i++)
        {
            var pos = i * step;
            var j = Math.Min((int)pos, input.Length - 1);
            var a = input[j];
            var b = j + 1 < input.Length ? input[j + 1] : a;
            // Between a and b → always inside the short range.
            output[i] = (short)Math.Round(a + (b - a) * (pos - j));
        }
        return output;
    }

    // Whole 20 ms frames at `rate`; the last one is zero-padded, so every frame is whole
    // (640 bytes at 16 kHz, 960 at 24 kHz).
    public static List<byte[]> Frames(ReadOnlySpan<short> samples, int rate = SampleRate)
    {
        var size = rate * FrameMs / 1000;
        var frames = new List<byte[]>((samples.Length + size - 1) / size);
        for (var start = 0; start < samples.Length; start += size)
        {
            var frame = new byte[size * 2];
            var count = Math.Min(size, samples.Length - start);
            for (var i = 0; i < count; i++)
                BinaryPrimitives.WriteInt16LittleEndian(frame.AsSpan(i * 2, 2), samples[start + i]);
            frames.Add(frame);
        }
        return frames;
    }

    // PCM at `sampleRate` (16-bit LE mono) → the call's 20 ms frames at `outRate`.
    public static List<byte[]> FramesFor(byte[] pcm, int sampleRate, int outRate = SampleRate) =>
        Frames(Resample(ToSamples(pcm), sampleRate, outRate), outRate);

    // What frame `frame` on is in the input (`pcm` at `sampleRate`): the part a dropped call never played.
    public static byte[] Rest(byte[] pcm, int sampleRate, int frame) =>
        pcm[Math.Min(pcm.Length, (int)((long)frame * sampleRate * FrameMs / 1000) * 2)..];

    public static float Rms(ReadOnlySpan<short> samples)
    {
        if (samples.Length == 0) return 0;
        double sum = 0;
        foreach (var s in samples)
        {
            var v = s / 32768.0;
            sum += v * v;
        }
        return (float)Math.Sqrt(sum / samples.Length);
    }

    // dB → 0…1, the same mapping as the mic and speaker meters.
    public static float Level(float db) => Math.Clamp((db + 55f) / 45f, 0f, 1f);
}

// The call itself: connected or not, the phone's audio in, Parley's audio out, the `audio`
// state frames, and the phone's Unterwegs-Modus + VoIP push token (kept in credentials.json, so
// ringing works after a restart while the phone sleeps). Static like AudioOut / LiveStatus —
// there is one phone call at most.
public static class PhoneCall
{
    // No phone audio for this long while "in a call" → the phone is gone (its `call end` was
    // lost with its link): Parley uses the PC's speaker and mic until frames arrive again. The
    // phone streams its mic all through a call, so a healthy call never gets near this.
    public static readonly TimeSpan AudioSilentLimit = TimeSpan.FromSeconds(10);
    private const int LeadFrames = 12;  // sent 240 ms ahead of real time: absorbs timer + mobile network jitter

    private static readonly object Gate = new();
    private static readonly SemaphoreSlim StateGate = new(1, 1);   // `audio` frames go out one at a time, latest wins
    private static RelayClient? _relay;
    private static bool _call;                 // the phone said `call start` (and not `call end` since)
    private static DateTime _audioAt;          // last phone frame, or the call start
    private static Action<byte[]>? _sink;      // the recorder, while it listens on the phone
    private static int _holds;                 // turns / dialogs / acks in progress (0 = idle)
    private static string _audio = "idle";     // speaking | listening | idle
    private static string? _speaker;           // the session voiced now — rides on every `audio` frame
    private static string? _sent;              // the state|speaker the phone has (null = unknown → send)
    private static bool _away;
    private static bool _silent;
    private static int _downRate = PhoneAudio.SampleRate;   // the call's voice rate: 16 or 24 kHz
    private static string _alertToken = "";
    private static string _pushToken = "", _pushEnv = "production";
    private static string _activityStart = "", _activityToken = "";

    // ---- relay seam ------------------------------------------------------------------

    public static void Attach(RelayClient? relay)
    {
        lock (Gate)
        {
            _relay = relay;
            _sent = null;
        }
    }

    // In a call right now: the phone says so, the relay is up, and its audio is flowing.
    public static bool Active
    {
        get { lock (Gate) return ActiveLocked(DateTime.UtcNow); }
    }

    private static bool ActiveLocked(DateTime now) =>
        _call && _relay?.Connected == true && now - _audioAt < AudioSilentLimit;

    // Unterwegs: chosen on the phone, or the PC locked for a minute (with that setting on).
    public static bool Away
    {
        get { lock (Gate) return _away || _lockedAway; }
    }

    private static bool _lockedAway;
    private static DateTime? _lastCallEnd;

    // When the last call ended (a Fragerunde gathers for a few minutes after it).
    public static DateTime? LastCallEnd
    {
        get { lock (Gate) return _lastCallEnd; }
    }

    public static void SetLockedAway(bool on)
    {
        lock (Gate)
        {
            if (_lockedAway == on) return;
            _lockedAway = on;
        }
        Log.Write(on ? "PC gesperrt → Unterwegs" : "PC entsperrt → zurück am PC");
    }

    public static int DownRate
    {
        get { lock (Gate) return _downRate; }
    }

    public static bool Silent
    {
        get { lock (Gate) return _silent; }
    }

    // Where a notification goes: the alert token and the push environment (same app build).
    public static (string Token, string Env) Alert
    {
        get { lock (Gate) return (_alertToken, _pushEnv); }
    }

    // A text frame to the phone (v3 answers: history, image), whether or not a call is up.
    public static async Task Reply(string frame)
    {
        RelayClient? relay;
        lock (Gate) relay = _relay;
        if (relay is not null) await relay.SendTextAsync(frame);
    }

    public static (string Token, string Env) Push
    {
        get { lock (Gate) return (_pushToken, _pushEnv); }
    }

    // The Live Activity: its push-to-start token, and the running one's update token ("" = none).
    public static (string Token, string Env) ActivityStart
    {
        get { lock (Gate) return (_activityStart, _pushEnv); }
    }

    public static (string Token, string Env) Activity
    {
        get { lock (Gate) return (_activityToken, _pushEnv); }
    }

    // `call` start / end from the phone.
    // The phone repeats its call state on every (re)connect, so only a change is logged.
    public static void OnCall(bool started, int down = PhoneAudio.SampleRate)
    {
        bool changed;
        lock (Gate)
        {
            changed = _call != started;
            if (!started && !_call) _declined = true;
            if (changed) { _barge = false; _recent.Clear(); }
            if (!started && _call) _lastCallEnd = DateTime.UtcNow;
            _call = started;
            if (started) _downRate = down;
            _audioAt = DateTime.UtcNow;   // grace until its first frame arrives
            _sent = null;                 // a (re)joined call learns the current state
        }
        if (changed) Log.Write(started ? $"phone: call started (voice at {down / 1000} kHz)" : "phone: call ended");
        if (!started) return;
        if (changed) Clips.PrerenderGreet(Config.Load());   // the first "Hey Parley" answers at once
        _ = PushState();
    }

    // A binary frame from the phone: its microphone.
    public static void OnAudio(byte[] frame)
    {
        Action<byte[]>? sink;
        lock (Gate)
        {
            _audioAt = DateTime.UtcNow;
            sink = _sink;
            _recent.Enqueue(frame);
            while (_recent.Count > PrerollFrames) _recent.Dequeue();
        }
        sink?.Invoke(frame);
    }

    // ---- barge-in (as macOS): Sir talks over Parley -----------------------------------

    public const int PrerollFrames = 100;   // 2 s of the phone's mic (20 ms frames)
    private static readonly Queue<byte[]> _recent = new();
    private static bool _barge;

    // The phone heard Sir talk over Parley: the line stops; the listener starts with RecentMic().
    public static void OnBarge()
    {
        lock (Gate)
        {
            if (!_call) return;
            _barge = true;
        }
        Log.Write("phone: Sir interrupts — stopping the line");
    }

    public static bool Barged
    {
        get { lock (Gate) return _barge; }
    }

    public static bool TakeBarge()
    {
        lock (Gate)
        {
            var b = _barge;
            _barge = false;
            return b;
        }
    }

    // The last 2 s of the phone's mic — what Sir said before the PC listened.
    public static byte[][] RecentMic()
    {
        lock (Gate) return _recent.ToArray();
    }

    // The relay (re)connected: the phone gets the current state again.
    public static void Resync()
    {
        lock (Gate) _sent = null;
        _ = PushState();
    }

    // ---- what the host is doing with the call audio (`audio` frames) -----------------

    // Held by everything that voices or listens (turns, dialogs, the ack after a reply) from
    // the moment it queues until it is done: the phone only listens for "Hey Parley" while
    // nothing holds. The last release reports `idle`.
    public static IDisposable Hold()
    {
        lock (Gate)
        {
            if (_holds++ == 0) _audio = "speaking";
        }
        _ = PushState();
        return new Release(ReleaseHold);
    }

    // A hold only when the call is connected and nothing else holds — atomically, so two
    // `wake` frames can't both start a greeting.
    public static IDisposable? HoldIfIdle()
    {
        lock (Gate)
        {
            if (_holds != 0 || !ActiveLocked(DateTime.UtcNow)) return null;
            _holds++;
            _audio = "speaking";
        }
        _ = PushState();
        return new Release(ReleaseHold);
    }

    private static void ReleaseHold()
    {
        lock (Gate)
        {
            if (--_holds > 0) return;
            _holds = 0;
            _audio = "idle";
        }
        _ = PushState();
    }

    public static void SetAudio(string state)
    {
        lock (Gate)
        {
            if (_audio == state) return;
            _audio = state;
        }
        _ = PushState();
    }

    // The session whose turn is voiced now: the phone's call screen (and CallKit) names it.
    public static void SetSpeaker(string label)
    {
        lock (Gate)
        {
            if (_speaker == label) return;
            _speaker = label;
        }
        _ = PushState();
    }

    // Sends the CURRENT state if the phone doesn't have it yet. One sender at a time and the
    // state is read after the gate, so quick changes can't arrive out of order.
    private static async Task PushState()
    {
        await StateGate.WaitAsync();
        try
        {
            string state, key;
            string? speaker;
            RelayClient? relay;
            lock (Gate)
            {
                key = $"{_audio}|{_speaker}";
                if (!_call || _relay is null || key == _sent) return;
                state = _audio;
                speaker = _speaker;
                relay = _relay;
            }
            var ok = await relay.SendTextAsync(RelayFrame.Audio(state, speaker));
            lock (Gate) _sent = ok ? key : null;
        }
        catch (Exception e) { Log.Write($"phone: state frame failed: {e.Message}"); }
        finally { StateGate.Release(); }
    }

    // ---- audio out / in --------------------------------------------------------------

    // Parley's voice to the phone, in real time (a few frames ahead), so "done" means the
    // phone has played it and beep → record keeps the speaker's timing. Returns what is left
    // (PCM at `sampleRate`) when the call drops midway — the caller plays it on the PC's speaker
    // — or null once everything went out (or the playback was cancelled).
    public static async Task<byte[]?> PlayAsync(byte[] pcm, int sampleRate, CancellationToken ct = default)
    {
        var frames = PhoneAudio.FramesFor(pcm, sampleRate, DownRate);
        RelayClient? relay;
        lock (Gate) relay = _relay;
        if (relay is null) return pcm;
        using var hold = Hold();
        SetAudio("speaking");
        var clock = Stopwatch.StartNew();
        try
        {
            for (var i = 0; i < frames.Count; i++)
            {
                if (!Active) return PhoneAudio.Rest(pcm, sampleRate, Math.Max(0, i - LeadFrames));
                if (Barged) return null;   // barge-in: stop at once, nothing of it on the PC's speaker
                var due = TimeSpan.FromMilliseconds((i - LeadFrames) * PhoneAudio.FrameMs) - clock.Elapsed;
                if (due > TimeSpan.Zero) await Task.Delay(due, ct);
                await relay.SendAudioAsync(frames[i]);
                // Output level for GET /status, as the speaker path meters it.
                LiveStatus.Push(PhoneAudio.Level(Vad.Db(PhoneAudio.Rms(PhoneAudio.ToSamples(frames[i])))));
            }
            var tail = TimeSpan.FromMilliseconds(frames.Count * PhoneAudio.FrameMs) - clock.Elapsed;
            if (tail > TimeSpan.Zero) await Task.Delay(tail, ct);
        }
        catch (OperationCanceledException) { }
        return null;
    }

    // Route the phone's microphone frames to `sink` until the returned handle is disposed.
    public static IDisposable Listen(Action<byte[]> sink)
    {
        lock (Gate) _sink = sink;
        return new Release(() =>
        {
            lock (Gate)
            {
                if (_sink == sink) _sink = null;
            }
        });
    }

    // ---- ringing (Unterwegs-Modus) ---------------------------------------------------

    // The `ring` frame next to the VoIP push: a phone that is open in the foreground shows
    // its own incoming call from it. true = handed to the relay.
    public static async Task<bool> SendRing(string label)
    {
        RelayClient? relay;
        lock (Gate) relay = _relay;
        return relay is not null && relay.Connected && await relay.SendTextAsync(RelayFrame.Ring(label));
    }

    // The ringing phone's "not now": ring again in n s, or (null) Sir calls back himself.
    private static (bool Set, double? After) _later;
    private static bool _declined;   // `call end` with no call: the ring was declined

    /// A declined ring, once (the phone may still send a "not now" from its notification).
    public static bool TakeDeclined()
    {
        lock (Gate)
        {
            var d = _declined;
            _declined = false;
            return d;
        }
    }

    public static void SetLater(double? after)
    {
        lock (Gate) _later = (true, after);
        Log.Write(after is double s ? $"phone: not now — ring again in {(int)s} s" : "phone: not now — Sir calls back");
    }

    /// Takes the "not now", once.
    public static bool TakeLater(out double? after)
    {
        lock (Gate)
        {
            (var set, after) = _later;
            _later = (false, null);
            return set;
        }
    }

    // Polls for the call (every 200 ms) until it is connected or `limit` has passed.
    public static async Task<bool> WaitForCall(TimeSpan limit)
    {
        var until = DateTime.UtcNow + limit;
        while (DateTime.UtcNow < until)
        {
            if (Active) return true;
            await Task.Delay(200);
        }
        return Active;
    }

    // ---- the phone's settings --------------------------------------------------------

    public static void LoadSettings(Config c)
    {
        lock (Gate)
        {
            _away = c.PhoneAway;
            _silent = c.PhoneSilent;
            _alertToken = c.PhoneAlertToken;
            _pushToken = c.PhonePushToken;
            _pushEnv = c.PhonePushEnv;
            _activityStart = c.PhoneActivityStart;
            _activityToken = c.PhoneActivityToken;
        }
    }

    // `activity` with `start`: the push-to-start token ("" drops it — APNs no longer knows it).
    public static void SetActivityStart(string token, string env)
    {
        env = env == "development" ? "development" : "production";
        lock (Gate)
        {
            if (_activityStart == token) return;
            _activityStart = token;
            if (token.Length > 0) _pushEnv = env;
        }
        Config.Merge(token.Length > 0
            ? new Dictionary<string, string> { ["phoneActivityStart"] = token, ["phonePushEnv"] = env }
            : new Dictionary<string, string> { ["phoneActivityStart"] = "" });
        Log.Write(token.Length > 0 ? $"phone: Live Activity push-to-start token stored ({env})" : "phone: Live Activity push-to-start token dropped");
    }

    // `activity` with `token`: the running Live Activity's update token; "" = it ended.
    public static void SetActivity(string token, string env)
    {
        env = env == "development" ? "development" : "production";
        lock (Gate)
        {
            if (_activityToken == token) return;
            _activityToken = token;
            if (token.Length > 0) _pushEnv = env;
        }
        Config.Merge(token.Length > 0
            ? new Dictionary<string, string> { ["phoneActivityToken"] = token, ["phonePushEnv"] = env }
            : new Dictionary<string, string> { ["phoneActivityToken"] = "" });
        Log.Write(token.Length > 0 ? $"phone: Live Activity update token stored ({env})" : "phone: Live Activity ended");
    }

    // `away`: Unterwegs-Modus on / off, kept across restarts.
    public static void SetAway(bool on)
    {
        lock (Gate)
        {
            if (_away == on) return;
            _away = on;
        }
        Config.Merge(new Dictionary<string, string> { ["phoneAway"] = on ? "1" : "0" });
        Log.Write($"phone: Unterwegs-Modus {(on ? "an" : "aus")}");
    }

    // `silent`: Stumm on / off (with Unterwegs: a notification instead of a call), kept.
    public static void SetSilent(bool on)
    {
        lock (Gate)
        {
            if (_silent == on) return;
            _silent = on;
        }
        Config.Merge(new Dictionary<string, string> { ["phoneSilent"] = on ? "1" : "0" });
        Log.Write($"phone: Stumm {(on ? "an" : "aus")}");
    }

    // `push` with kind "alert": the notification token, kept across restarts.
    public static void SetAlert(string token, string env)
    {
        token = token.Trim().ToLowerInvariant();
        if (!Apns.ValidToken(token)) { Log.Write("phone: ignored a malformed notification token"); return; }
        lock (Gate)
        {
            if (_alertToken == token) return;
            _alertToken = token;
            _pushEnv = env == "development" ? "development" : "production";
        }
        Config.Merge(new Dictionary<string, string> { ["phoneAlertToken"] = token, ["phonePushEnv"] = env == "development" ? "development" : "production" });
        Log.Write("phone: notification push token stored");
    }

    // `push`: the phone's VoIP token (hex) and APNs environment, kept across restarts.
    public static void SetPush(string token, string env)
    {
        token = token.Trim();
        if (!Apns.ValidToken(token))
        {
            Log.Write("phone: ignored a malformed VoIP push token");
            return;
        }
        env = env == "development" ? "development" : "production";
        lock (Gate)
        {
            if (_pushToken == token && _pushEnv == env) return;
            _pushToken = token;
            _pushEnv = env;
        }
        Config.Merge(new Dictionary<string, string> { ["phonePushToken"] = token, ["phonePushEnv"] = env });
        Log.Write($"phone: VoIP push token stored ({env})");
    }

    private sealed class Release : IDisposable
    {
        private Action? _action;
        public Release(Action action) => _action = action;
        public void Dispose() => Interlocked.Exchange(ref _action, null)?.Invoke();
    }
}

// Unterwegs-Modus (docs/IPHONE.md, v2): while `away` is on and no call is connected, a turn
// that is about to be voiced rings the phone — VoIP push + `ring` frame — and waits up to 45 s
// for `call start`. Answered → it is voiced over the phone; else on the PC's speaker as before.
public static class Ringer
{
    public static readonly TimeSpan AnswerWait = TimeSpan.FromSeconds(45);

    // Answered = in a call now; Later = the phone's "not now" (After: ring again in n s, null = Sir calls back).
    public static async Task<RingOutcome> Ring(string label)
    {
        if (PhoneCall.Active) return new RingOutcome(RingKind.Answered);
        if (!PhoneCall.Away || PhoneCall.Silent) return new RingOutcome(RingKind.Missed);   // Stumm: the turn sends a notification instead
        PhoneCall.TakeLater(out _);   // an old "not now" or decline is not this ring's
        PhoneCall.TakeDeclined();
        var pushed = await Apns.SendVoip(label);
        var rang = await PhoneCall.SendRing(label);
        if (!pushed && !rang)
        {
            Log.Write("ring: neither the push nor the relay reached the phone → speaker");
            return new RingOutcome(RingKind.Missed);
        }
        Log.Write($"ring: {label} (push {(pushed ? "sent" : "not sent")}, relay {(rang ? "sent" : "not sent")}) — waiting up to {(int)AnswerWait.TotalSeconds} s");
        var until = DateTime.UtcNow + AnswerWait;
        while (!PhoneCall.Active)
        {
            if (PhoneCall.TakeLater(out var after)) return new RingOutcome(RingKind.Later, after);
            // Declined on the lock screen: its notification offers "later" — give it a minute.
            if (PhoneCall.TakeDeclined())
            {
                var minute = DateTime.UtcNow.AddSeconds(60);
                if (minute > until) until = minute;
                Log.Write("ring: declined — a minute for a \"later\" from the notification");
            }
            if (DateTime.UtcNow >= until)
            {
                Log.Write("ring: no answer → speaker");
                return new RingOutcome(RingKind.Missed);
            }
            await Task.Delay(100);
        }
        Log.Write("ring: answered → voiced over the phone");
        return new RingOutcome(RingKind.Answered);
    }
}

public enum RingKind { Answered, Missed, Later }

public sealed record RingOutcome(RingKind Kind, double? After = null);
