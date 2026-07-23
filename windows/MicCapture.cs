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

    /// Record until trailing silence (or timeout); returns 16 kHz mono 16-bit WAV bytes.
    public async Task<byte[]> Record()
    {
        var vad = new Vad();
        var samples = new List<short>(16000 * 30);
        var done = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        WasapiCapture? capture = null;
        double totalDuration = 0;
        double resamplePos = 0;
        float prevSample = 0;

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

            var reason = await Task.WhenAny(done.Task, Task.Delay(TimeSpan.FromSeconds(MaxListenSeconds)))
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
        return Wav.Encode(System.Runtime.InteropServices.CollectionsMarshal.AsSpan(samples));
    }

    private static float[] ToMonoFloats(byte[] buffer, int bytes, WaveFormat fmt, int channels)
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
