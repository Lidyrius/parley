using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Parley;

// Slides in a call (docs/CALL-SLIDES.md): `<slide …/>` markers in the spoken line (the Stop hook
// strips them and keeps the word each precedes). Each slide shows when that word is spoken — the
// caption times — so the phone gets one `slides` frame per line and the images as `image`
// frames keyed by slide id. Same as macOS (app/Sources/Parley/Slides.swift).
public sealed class SlideSpec
{
    [JsonPropertyName("word")] public int Word { get; set; }
    [JsonPropertyName("image")] public string? Image { get; set; }     // "last", "last-2", or an image file path
    [JsonPropertyName("chart")] public string? Chart { get; set; }     // bar | line | pie
    [JsonPropertyName("labels")] public string? Labels { get; set; }   // "Mo,Di,Mi"
    [JsonPropertyName("values")] public string? Values { get; set; }   // "3,5.5,2" (dot decimals)
    [JsonPropertyName("metric")] public string? Metric { get; set; }
    [JsonPropertyName("text")] public string? Text { get; set; }
    [JsonPropertyName("title")] public string? Title { get; set; }
    [JsonPropertyName("unit")] public string? Unit { get; set; }
    [JsonPropertyName("note")] public string? Note { get; set; }
    [JsonPropertyName("focus")] public string? Focus { get; set; }     // v12, image slides: "x,y,w,h" (fractions, or percent)
}

public static class Slides
{
    private static readonly JsonSerializerOptions Json = new() { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };
    private static readonly string[] ImageExtensions = { ".png", ".jpg", ".jpeg", ".gif", ".webp", ".tiff", ".bmp" };

    public sealed record Out(
        [property: JsonPropertyName("id")] string Id,
        [property: JsonPropertyName("at")] double At,
        [property: JsonPropertyName("kind")] string Kind,
        [property: JsonPropertyName("title")] string? Title,
        [property: JsonPropertyName("text")] string? Text,
        [property: JsonPropertyName("chart")] string? Chart,
        [property: JsonPropertyName("labels")] string[]? Labels,
        [property: JsonPropertyName("values")] double[]? Values,
        [property: JsonPropertyName("unit")] string? Unit,
        [property: JsonPropertyName("metric")] string? Metric,
        [property: JsonPropertyName("note")] string? Note,
        [property: JsonPropertyName("focus")] double[]? Focus = null,   // v12: [x, y, w, h], fractions, origin top left
        [property: JsonPropertyName("ref")] string? Ref = null);         // v12: an earlier slide with the same image

    // "x,y,w,h" as fractions (or percent, when any value is above 1) → a rect inside the image;
    // null when it isn't four numbers or is too small to mean anything. Pure; as macOS.
    public static double[]? Focus(string? s)
    {
        if (s is null) return null;
        var v = s.Split(',').Select(x => double.TryParse(x.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? (double?)d : null).ToList();
        if (v.Count != 4 || v.Any(d => d is null || d < 0)) return null;
        var f = v.Select(d => d!.Value).ToArray();
        if (f.Any(d => d > 1)) f = f.Select(d => d / 100).ToArray();
        var x = Math.Min(f[0], 1); var y = Math.Min(f[1], 1);
        var w = Math.Min(f[2], 1 - x); var h = Math.Min(f[3], 1 - y);
        if (w < 0.02 || h < 0.02) return null;
        return new[] { x, y, w, h }.Select(d => Math.Round(d * 1000) / 1000).ToArray();
    }

    // The sharp close-up of a focus: the rect with a margin, still inside the image.
    public static double[] CloseUp(double[] f)
    {
        var m = 0.12 * Math.Max(f[2], f[3]);
        double x = Math.Max(0, f[0] - m), y = Math.Max(0, f[1] - m);
        return new[] { x, y, Math.Min(1, f[0] + f[2] + m) - x, Math.Min(1, f[1] + f[3] + m) - y };
    }

    // The `image` frames for a line: each image once (a `ref` slide has none), plus a close-up
    // `<id>.hd` for every focus.
    public static List<(string Key, string Source, double[]? Crop)> ImageJobs(IReadOnlyList<SlideSpec> specs, List<Out> items) =>
        specs.Zip(items).Where(p => p.First.Image is not null).SelectMany(p =>
        {
            var jobs = new List<(string, string, double[]?)>();
            if (p.Second.Ref is null) jobs.Add((p.Second.Id, p.First.Image!, null));
            if (p.Second.Focus is { } f) jobs.Add((p.Second.Id + ".hd", p.First.Image!, CloseUp(f)));
            return jobs;
        }).ToList();

    // The slides with their times (the start of the word each precedes; 0 without captions).
    public static List<Out> Items(IReadOnlyList<SlideSpec> specs, Captions.Timed? timed, string prefix)
    {
        var first = new Dictionary<string, string>();   // image source → the first slide id showing it
        return specs.Select((s, n) =>
        {
            var at = timed is null ? 0 : s.Word < timed.Starts.Length ? timed.Starts[Math.Max(0, s.Word)] : timed.End;
            var kind = s.Image is not null ? "image" : s.Chart is not null ? "chart" : s.Metric is not null ? "metric" : "text";
            var labels = s.Labels?.Split(',').Select(x => x.Trim()).ToArray();
            var values = s.Values?.Split(',')
                .Select(x => double.TryParse(x.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? (double?)v : null)
                .Where(v => v is not null).Select(v => v!.Value).ToArray();
            var id = $"{prefix}-{n}";
            string? reference = null;
            if (s.Image is { } img) { if (first.TryGetValue(img, out var earlier)) reference = earlier; else first[img] = id; }
            return new Out(id, Math.Round(at, 2), kind, s.Title, s.Text, kind == "chart" ? s.Chart : null,
                labels, values, s.Unit, s.Metric, s.Note, kind == "image" ? Focus(s.Focus) : null, reference);
        }).ToList();
    }

    public static string Frame(List<Out> items) => JsonSerializer.Serialize(new { t = "slides", items }, Json);

    // An image slide's pixels as a frame-sized JPEG: "last" / "last-N" = the N-th newest image in
    // the session's transcript (screenshots Claude took), else an image file's path.
    public static byte[]? Image(string source, string session, double[]? crop = null) =>
        Raw(source, session) is { } raw ? Transcript.Jpeg(raw, crop) : null;

    public static byte[]? Raw(string source, string session)
    {
        try
        {
            if (source == "last" || source.StartsWith("last-", StringComparison.Ordinal))
            {
                var n = source == "last" ? 1 : int.TryParse(source[5..], out var k) ? k : 1;
                if (Transcript.File(session) is not { } path) return null;
                var images = Transcript.Parse(Transcript.TailLines(path)).Where(i => i.K == "image").ToList();
                return images.Count >= n ? Transcript.RawImage(path, images[^n].Id) : null;
            }
            var file = Environment.ExpandEnvironmentVariables(source);
            if (!ImageExtensions.Contains(Path.GetExtension(file).ToLowerInvariant()) || !File.Exists(file)
                || new FileInfo(file).Length > 30 << 20) return null;
            return File.ReadAllBytes(file);
        }
        catch (Exception e)
        {
            Log.Write($"slides: image {source} failed ({e.Message})");
            return null;
        }
    }

    // A line's slides to the phone: the timed list now, each image as it is ready.
    // `line`: a guest's call line (Shares.cs), else Sir's.
    public static async Task Send(IReadOnlyList<SlideSpec> specs, Captions.Timed? timed, string session, PhoneLine? line = null)
    {
        Func<string, Task> reply = line is null ? PhoneCall.Reply : line.Reply;
        var items = Items(specs, timed, $"slide-{Guid.NewGuid().ToString("N")[..8]}");
        await reply(Frame(items));
        Log.Write($"phone: {items.Count} slide(s) for this line");
        var jobs = ImageJobs(specs, items);
        if (jobs.Count == 0) return;
        _ = Task.Run(async () =>
        {
            foreach (var (key, source, crop) in jobs)
            {
                var jpeg = Image(source, session, crop);
                if (crop is not null && jpeg is null) continue;   // no close-up: the phone zooms the image itself
                await reply(Transcript.ImageFrame(key, jpeg));
            }
        });
    }
}
