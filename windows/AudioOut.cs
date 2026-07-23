using NAudio.Wave;

namespace Parley;

// PCM playback for TTS output + tone synthesis. Fresh WasapiOut per playback (mirrors
// the macOS fresh-player pattern); Play() then wait until the buffer drains.
public static class AudioOut
{
    /// Play raw 16-bit LE mono PCM at `sampleRate`, blocking until done.
    public static async Task PlayPcm(byte[] pcm, int sampleRate = GoogleTts.SampleRate)
    {
        if (pcm.Length < 2) return;
        var format = new WaveFormat(sampleRate, 16, 1);
        var provider = new BufferedWaveProvider(format)
        {
            BufferLength = Math.Max(pcm.Length + 65536, 1 << 20),
            ReadFully = false,   // report end-of-stream once the buffer is drained
        };
        provider.AddSamples(pcm, 0, pcm.Length);
        using var output = new NAudio.Wave.WasapiOut(NAudio.CoreAudioApi.AudioClientShareMode.Shared, 100);
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        output.PlaybackStopped += (_, _) => done.TrySetResult();
        output.Init(provider);
        output.Play();
        await Task.WhenAny(done.Task, Task.Delay(TimeSpan.FromSeconds(pcm.Length / (double)(sampleRate * 2) + 5)));
        output.Stop();
    }

    /// The "you can talk now" cue — same 880 Hz character as macOS.
    public static Task PlayBeep(double frequency = 880, double seconds = 0.18, double amplitude = 0.3)
        => PlayPcm(Tone(frequency, seconds, amplitude));

    /// Soft two-tone "done" chime (ack fallback), C5 → G5 as on macOS.
    public static async Task PlayChime()
    {
        await PlayPcm(Chime(523.25, 0.32, 0.4, 8));
        await PlayPcm(Chime(783.99, 0.6, 0.4, 5.5));
    }

    private static byte[] Tone(double freq, double seconds, double amplitude)
    {
        var n = (int)(GoogleTts.SampleRate * seconds);
        var pcm = new byte[n * 2];
        var w = 2.0 * Math.PI * freq / GoogleTts.SampleRate;
        for (var i = 0; i < n; i++)
        {
            var s = (short)(amplitude * Math.Sin(i * w) * short.MaxValue);
            pcm[i * 2] = (byte)(s & 0xff);
            pcm[i * 2 + 1] = (byte)((s >> 8) & 0xff);
        }
        return pcm;
    }

    private static byte[] Chime(double freq, double seconds, double amplitude, double decay)
    {
        var sr = (double)GoogleTts.SampleRate;
        var n = (int)(sr * seconds);
        var pcm = new byte[n * 2];
        var w1 = 2.0 * Math.PI * freq / sr;
        var w2 = w1 * 2.0;
        const double norm = 1.0 / 1.15;
        for (var i = 0; i < n; i++)
        {
            var t = i / sr;
            var attack = Math.Min(1.0, t / 0.014);
            var env = attack * Math.Exp(-t * decay);
            var v = Math.Sin(i * w1) + 0.15 * Math.Sin(i * w2);
            var s = (short)(amplitude * env * v * norm * short.MaxValue);
            pcm[i * 2] = (byte)(s & 0xff);
            pcm[i * 2 + 1] = (byte)((s >> 8) & 0xff);
        }
        return pcm;
    }
}
