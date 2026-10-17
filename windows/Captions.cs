using System.Text.Json;

namespace Parley;

// Live captions for a call (protocol v3, docs/IPHONE.md): when each word of a spoken line
// starts, read off the synthesized audio itself — one pass over it, no extra TTS request. The
// voice's pauses (≥ 120 ms clearly below the line's level) are matched to the text's
// punctuation; the words between two anchors share that stretch by their length. Same as macOS
// (app/Sources/Parley/Captions.swift).
public static class Captions
{
    public sealed record Timed(string[] Words, double[] Starts, double End);

    private const string Breaks = ".,;:!?–—…";

    // `pcm`: 16-bit LE mono at `sampleRate`, exactly as it will be heard. null for empty text or silence.
    public static Timed? Timings(string text, byte[] pcm, int sampleRate)
    {
        var words = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        var hop = Math.Max(1, sampleRate / 100);   // 10 ms
        var n = pcm.Length / 2 / hop;
        if (words.Length == 0 || n == 0) return null;
        var rms = new float[n];
        for (var i = 0; i < n; i++)
        {
            float sum = 0;
            for (var j = i * hop; j < (i + 1) * hop; j++)
            {
                var v = BitConverter.ToInt16(pcm, j * 2) / 32768f;
                sum += v * v;
            }
            rms[i] = MathF.Sqrt(sum / hop);
        }
        var peak = rms.Max();
        if (peak <= 0) return null;
        var voiced = rms.Select(r => r > peak * 0.06f).ToArray();   // ≈ −24 dB under the loudest 10 ms
        var first = Array.IndexOf(voiced, true);
        var last = Array.LastIndexOf(voiced, true);
        if (first < 0) return null;

        var pauses = new List<(int From, int To)>();   // [from, to) in 10 ms frames
        for (var i = first; i <= last;)
        {
            if (voiced[i]) { i++; continue; }
            var j = i;
            while (j <= last && !voiced[j]) j++;
            if (j - i >= 12) pauses.Add((i, j));
            i = j;
        }

        // Where each word boundary would be if time followed the characters; punctuated ones
        // snap to the nearest later pause within 0.8 s.
        var weights = words.Select(w => w.Length + 1.0).ToArray();
        var total = weights.Sum();
        var span = (double)(last + 1 - first);
        var anchors = new List<(int Word, int End, int Start)>();
        double acc = 0;
        var floor = first;
        for (var k = 1; k < words.Length; k++)
        {
            acc += weights[k - 1];
            if (!Breaks.Contains(words[k - 1][^1])) continue;
            var expected = first + acc / total * span;
            var candidates = pauses.Where(p => p.From > floor).ToList();
            if (candidates.Count == 0) continue;
            var near = candidates.MinBy(p => Math.Abs((p.From + p.To) / 2.0 - expected));
            if (Math.Abs((near.From + near.To) / 2.0 - expected) >= 80) continue;
            anchors.Add((k, near.From, near.To));
            floor = near.To;
        }

        var starts = new double[words.Length];
        int segStart = first, from = 0;
        foreach (var (to, segEnd, next) in anchors.Append((words.Length, last + 1, last + 1)))
        {
            var w = 0.0;
            for (var k = from; k < to; k++) w += weights[k];
            double t = segStart;
            for (var k = from; k < to; k++)
            {
                starts[k] = t;
                t += weights[k] / w * (segEnd - segStart);
            }
            segStart = next;
            from = to;
        }
        return new Timed(words, starts.Select(s => s * 0.01).ToArray(), (last + 1) * 0.01);
    }

    // {"t":"caption","words":[…],"at":[…],"end":…,"last":…} — sent just before the line's first
    // frame. `last`: nothing follows on this call (a speak-end line, no other turn waiting) — a
    // phone that hangs up after the talk starts leaving before the line ends.
    public static string Frame(Timed t, bool last = false) => JsonSerializer.Serialize(new
    {
        t = "caption",
        words = t.Words,
        at = t.Starts.Select(s => Math.Round(s, 2)).ToArray(),
        end = Math.Round(t.End, 2),
        last,
    });
}
