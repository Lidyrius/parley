namespace Parley;

// Silence-timer VAD — direct port of the macOS SilenceVAD (same thresholds).
public sealed class Vad
{
    public float SpeechThresholdDb { get; init; } = -50f;
    public double TrailingSilence { get; init; } = 0.9;

    public bool Started { get; private set; }
    private double _silenceElapsed;

    public enum Decision { Waiting, Speaking, Ended }

    public Decision Process(float rmsDb, double duration)
    {
        if (rmsDb >= SpeechThresholdDb)
        {
            Started = true;
            _silenceElapsed = 0;
            return Decision.Speaking;
        }
        if (!Started) return Decision.Waiting;
        _silenceElapsed += duration;
        return _silenceElapsed >= TrailingSilence ? Decision.Ended : Decision.Speaking;
    }

    public void Reset()
    {
        Started = false;
        _silenceElapsed = 0;
    }

    public static float Rms(ReadOnlySpan<float> samples)
    {
        if (samples.Length == 0) return 0;
        double sum = 0;
        foreach (var s in samples) sum += s * s;
        return (float)Math.Sqrt(sum / samples.Length);
    }

    public static float Db(float rms) => rms > 0 ? MathF.Max(-120f, 20f * MathF.Log10(rms)) : -120f;
}

public static class Wav
{
    /// 16 kHz mono 16-bit PCM → WAV bytes (44-byte header + data).
    public static byte[] Encode(ReadOnlySpan<short> samples, int sampleRate = 16000)
    {
        var dataLen = samples.Length * 2;
        using var ms = new MemoryStream(44 + dataLen);
        using var w = new BinaryWriter(ms);
        w.Write("RIFF"u8); w.Write(36 + dataLen); w.Write("WAVE"u8);
        w.Write("fmt "u8); w.Write(16); w.Write((short)1); w.Write((short)1);
        w.Write(sampleRate); w.Write(sampleRate * 2); w.Write((short)2); w.Write((short)16);
        w.Write("data"u8); w.Write(dataLen);
        foreach (var s in samples) w.Write(s);
        return ms.ToArray();
    }
}
