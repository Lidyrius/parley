using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Parley;

// Mic capture + silence VAD. WASAPI shared-mode capture from the default input device,
// converted to 16 kHz mono s16 (channel-average + linear resample — fine for speech).
// Same behavior contract as macOS: 8 s no-speech timeout, 90 s cap, 0.9 s trailing
// silence, 0.5 s grace so the ready-beep can't arm the VAD.
public sealed class MicCapture
{
    private const double TargetRate = 16000.0;
    private const double NoSpeechTimeout = 8.0;
    private const double MaxListenSeconds = 90.0;
    private const double VadGraceSeconds = 0.5;

    public Action<float>? OnLevel;   // 0…1 live level for a future waveform UI
    private TaskCompletionSource<string>? _done;   // the recording under way, for Abandon

    /// Sir typed instead (POST /turn/cancel): the recording under way ends now, with nothing heard.
    public void Abandon() => _done?.TrySetResult("abandoned");

    /// Record until trailing silence (or timeout); returns 16 kHz mono 16-bit WAV bytes.
    /// In an iPhone call the phone's microphone is the input.
    /// `preroll`: barge-in — Sir already started talking, so the last seconds of mic (the phone's
    /// or this PC's, 16 kHz frames) count too.
    public async Task<byte[]> Record(IReadOnlyList<byte[]>? preroll = null)
    {
        if (PhoneCall.Active)
        {
            var phone = await RecordFromPhone(PhoneCall.Line, preroll ?? Array.Empty<byte[]>());
            if (phone is not null) return phone;
            Log.Write("mic: call ended before any speech → local mic");
        }
        // Unterwegs: the PC never listens (only a call does).
        if (PhoneCall.Away)
        {
            Log.Write("Unterwegs → no listening on the PC");
            return Array.Empty<byte>();
        }
        var vad = new Vad();
        var samples = new List<short>(16000 * 30);
        var done = _done = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        WasapiCapture? capture = null;
        double totalDuration = 0;
        double resamplePos = 0;
        float prevSample = 0;
        var reason = "error";
        foreach (var frame in preroll ?? Array.Empty<byte[]>())
        {
            var chunk = PhoneAudio.ToSamples(frame);
            samples.AddRange(chunk);
            totalDuration += chunk.Length / TargetRate;
            if (totalDuration >= VadGraceSeconds) vad.Process(Vad.Db(PhoneAudio.Rms(chunk)), chunk.Length / TargetRate);
        }

        try
        {
            capture = new WasapiCapture();   // default input device, its mix format
            var fmt = capture.WaveFormat;    // typically IEEE float, 44.1/48 kHz, 1-2 ch
            var channels = fmt.Channels;
            var ratio = fmt.SampleRate / TargetRate;

            capture.DataAvailable += (_, e) =>
            {
                if (done.Task.IsCompleted) return;
                // bytes → mono float frames
                var mono = ToMonoFloats(e.Buffer, e.BytesRecorded, fmt, channels);
                if (mono.Length == 0) return;
                // linear resample to 16 kHz + s16
                var outFloats = new List<float>(mono.Length);
                foreach (var f in mono)
                {
                    while (resamplePos < 1.0)
                    {
                        var interp = prevSample + (f - prevSample) * (float)resamplePos;
                        outFloats.Add(interp);
                        samples.Add((short)Math.Clamp(interp * short.MaxValue, short.MinValue, short.MaxValue));
                        resamplePos += ratio;
                    }
                    resamplePos -= 1.0;
                    prevSample = f;
                }
                if (outFloats.Count == 0) return;
                var duration = outFloats.Count / TargetRate;
                totalDuration += duration;
                var db = Vad.Db(Vad.Rms(System.Runtime.InteropServices.CollectionsMarshal.AsSpan(outFloats)));
                OnLevel?.Invoke(Math.Clamp((db + 55f) / 45f, 0f, 1f));

                if (totalDuration < VadGraceSeconds) return;
                var decision = vad.Process(db, duration);
                if (decision == Vad.Decision.Waiting && totalDuration >= NoSpeechTimeout)
                    done.TrySetResult("no-speech");
                else if (decision == Vad.Decision.Ended)
                    done.TrySetResult("vad-silence");
            };
            capture.RecordingStopped += (_, _) => done.TrySetResult("stopped");
            capture.StartRecording();
            Log.Write($"mic: capture started ({fmt.SampleRate}Hz, {channels}ch)");

            reason = await Task.WhenAny(done.Task, Task.Delay(TimeSpan.FromSeconds(MaxListenSeconds)))
                == done.Task ? done.Task.Result : "max-cap";
            Log.Write($"mic: finished reason={reason} samples={samples.Count}");
        }
        catch (Exception e)
        {
            Log.Write($"mic: error {e.Message}");
        }
        finally
        {
            try { capture?.StopRecording(); } catch { }
            capture?.Dispose();
        }
        // VAD never heard speech → send nothing; Whisper turns pure silence into "Thank you.".
        if (reason is "no-speech" or "abandoned") samples.Clear();
        return Wav.Encode(System.Runtime.InteropServices.CollectionsMarshal.AsSpan(samples));
    }

    // The phone's microphone (docs/IPHONE.md, v2): its 16 kHz frames from the relay through the
    // same VAD, grace and limits as the local mic. null = the call ended before anything was
    // said → the caller listens on the local mic instead; once speech started, what was heard
    // is used. `line`: Sir's call, or a guest's (Shares.cs — his spoken answer).
    public async Task<byte[]?> RecordFromPhone(PhoneLine line, IReadOnlyList<byte[]> preroll)
    {
        var vad = new Vad();
        var samples = new List<short>(16000 * 30);
        var gate = new object();
        double totalDuration = 0;
        var done = _done = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var hold = line.Hold();
        line.SetAudio("listening");
        Log.Write("mic: listening on the phone");
        void Feed(byte[] frame)
        {
            lock (gate)
            {
                if (done.Task.IsCompleted) return;
                var chunk = PhoneAudio.ToSamples(frame);
                if (chunk.Length == 0) return;
                samples.AddRange(chunk);
                var duration = chunk.Length / TargetRate;
                totalDuration += duration;
                var db = Vad.Db(PhoneAudio.Rms(chunk));
                OnLevel?.Invoke(PhoneAudio.Level(db));
                if (totalDuration < VadGraceSeconds) return;
                var decision = vad.Process(db, duration);
                if (decision == Vad.Decision.Waiting && totalDuration >= NoSpeechTimeout)
                    done.TrySetResult("no-speech");
                else if (decision == Vad.Decision.Ended)
                    done.TrySetResult("vad-silence");
            }
        }
        foreach (var frame in preroll) Feed(frame);
        using (line.Listen(Feed))
        {
            // Wall clock for the cap and the call: frames may simply stop coming.
            var start = DateTime.UtcNow;
            while (!done.Task.IsCompleted)
            {
                if (!line.Active) done.TrySetResult("call-ended");
                else if ((DateTime.UtcNow - start).TotalSeconds >= MaxListenSeconds) done.TrySetResult("max-cap");
                else await Task.WhenAny(done.Task, Task.Delay(200));
            }
        }
        var reason = await done.Task;
        short[] captured;
        bool heard;
        lock (gate)
        {
            captured = samples.ToArray();
            heard = vad.Started;
        }
        Log.Write($"mic: phone finished reason={reason} samples={captured.Length}");
        if (reason == "call-ended" && !heard) return null;
        // VAD never heard speech → send nothing; Whisper turns pure silence into "Thank you.".
        if (reason is "no-speech" or "abandoned") captured = Array.Empty<short>();
        return Wav.Encode(captured);
    }

    internal static float[] ToMonoFloats(byte[] buffer, int bytes, WaveFormat fmt, int channels)
    {
        if (fmt.Encoding == WaveFormatEncoding.IeeeFloat || fmt.Encoding == WaveFormatEncoding.Extensible)
        {
            var frames = bytes / 4 / channels;
            var mono = new float[frames];
            for (var i = 0; i < frames; i++)
            {
                float sum = 0;
                for (var c = 0; c < channels; c++)
                    sum += BitConverter.ToSingle(buffer, (i * channels + c) * 4);
                mono[i] = sum / channels;
            }
            return mono;
        }
        if (fmt.Encoding == WaveFormatEncoding.Pcm && fmt.BitsPerSample == 16)
        {
            var frames = bytes / 2 / channels;
            var mono = new float[frames];
            for (var i = 0; i < frames; i++)
            {
                float sum = 0;
                for (var c = 0; c < channels; c++)
                    sum += BitConverter.ToInt16(buffer, (i * channels + c) * 2) / 32768f;
                mono[i] = sum / channels;
            }
            return mono;
        }
        return Array.Empty<float>();
    }
}
