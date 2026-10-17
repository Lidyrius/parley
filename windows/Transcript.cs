using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Parley;

// A session's history for the phone (protocol v3, docs/IPHONE.md): read from Claude Code's own
// transcript (%USERPROFILE%\.claude\projects\<folder>\<session id>.jsonl), newest part only.
// Screenshots and pasted images become `image` items; their pixels go out one by one, downscaled,
// on request. Same items as macOS (app/Sources/Parley/Transcript.swift).
public static class Transcript
{
    public sealed record Item(
        [property: JsonPropertyName("id")] string Id,
        [property: JsonPropertyName("k")] string K,
        [property: JsonPropertyName("text")] string? Text = null,
        [property: JsonPropertyName("who")] string? Who = null,
        [property: JsonPropertyName("at")] double? At = null,
        [property: JsonPropertyName("add")] int? Add = null,     // tool: lines a Write / Edit added
        [property: JsonPropertyName("del")] int? Del = null);    //       and removed

    public const int MaxItems = 60;
    public const int MaxText = 2500;
    public const int MaxFrame = 200 * 1024;     // relay limit is 256 KB
    public const int TailBytes = 3 << 20;

    private static readonly JsonSerializerOptions Json = new() { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };

    public static string Projects =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "projects");

    // The transcript of `session` (a Claude Code session id), null for Codex / unknown ids.
    public static string? File(string session, string? root = null)
    {
        if (session.Length == 0 || session.IndexOfAny(new[] { '/', '\\' }) >= 0 || session.Contains("..")) return null;
        root ??= Projects;
        if (!Directory.Exists(root)) return null;
        return Directory.EnumerateDirectories(root)
            .Select(d => Path.Combine(d, session + ".jsonl"))
            .FirstOrDefault(System.IO.File.Exists);
    }

    // The last `bytes` of the file as whole JSON lines (the first, partial one dropped).
    public static List<string> TailLines(string path, int bytes = TailBytes)
    {
        try
        {
            using var f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var start = Math.Max(0, f.Length - (long)bytes);
            f.Seek(start, SeekOrigin.Begin);
            using var r = new StreamReader(f, Encoding.UTF8);
            var lines = r.ReadToEnd().Split('\n', StringSplitOptions.RemoveEmptyEntries).ToList();
            if (start > 0 && lines.Count > 0) lines.RemoveAt(0);
            return lines;
        }
        catch { return new List<string>(); }
    }

    // ---- items -----------------------------------------------------------------------

    public static List<Item> Items(IEnumerable<string> lines)
    {
        var all = Parse(lines);
        return all.Count > MaxItems ? all.GetRange(all.Count - MaxItems, MaxItems) : all;
    }

    // One page of history: the newest (`before` null, from the 3 MB tail) or the items right
    // before the item `before`. `More` = there is older history still.
    public static (List<Item> Items, bool More) Page(string path, string? before)
    {
        if (before is null)
        {
            var size = new FileInfo(path).Length;
            var tail = Parse(TailLines(path));
            return (tail.Count > MaxItems ? tail.GetRange(tail.Count - MaxItems, MaxItems) : tail, tail.Count > MaxItems || size > TailBytes);
        }
        // ponytail: an older page parses the whole file (~0.5 s for 30 MB); read it in windows if that shows.
        var all = Parse(TailLines(path, int.MaxValue));
        var i = all.FindIndex(x => x.Id == before);
        if (i < 0) return (new List<Item>(), false);
        var from = Math.Max(0, i - MaxItems);
        return (all.GetRange(from, i - from), from > 0);
    }

    public static List<Item> Parse(IEnumerable<string> lines)
    {
        var output = new List<Item>();
        foreach (var line in lines)
        {
            JsonDocument doc;
            try { doc = JsonDocument.Parse(line); } catch { continue; }
            using (doc)
            {
                var e = doc.RootElement;
                if (e.ValueKind != JsonValueKind.Object) continue;
                var type = Str(e, "type");
                if (type is not ("user" or "assistant") || Bool(e, "isSidechain") || Bool(e, "isCompactSummary")) continue;
                if (Str(e, "uuid") is not { } uuid || !e.TryGetProperty("message", out var msg) || msg.ValueKind != JsonValueKind.Object) continue;
                double? at = Str(e, "timestamp") is { } ts && DateTimeOffset.TryParse(ts, out var d) ? d.ToUnixTimeMilliseconds() : null;
                var n = 0;
                void Add(string k, string? text = null, string? who = null, (int, int)? diff = null) =>
                    output.Add(new Item($"{uuid}#{n++}", k, text is null ? null : Clip(text), who, at, diff?.Item1, diff?.Item2));
                msg.TryGetProperty("content", out var content);

                if (type == "assistant")
                {
                    foreach (var b in Blocks(content))
                    {
                        switch (Str(b, "type"))
                        {
                            case "text":
                                var (body, spoken) = Split(Str(b, "text") ?? "");
                                if (body.Length > 0) Add("assistant", body);
                                if (spoken is not null) Add("speak", spoken);
                                break;
                            case "tool_use":
                                var input = b.TryGetProperty("input", out var inp) ? inp : default;
                                Add("tool", Tool(Str(b, "name") ?? "", input), diff: Diff(Str(b, "name") ?? "", input));
                                break;
                        }
                    }
                    continue;
                }
                // user: a typed message, a voice reply (Stop hook feedback), images, tool results.
                var meta = Bool(e, "isMeta");
                if (content.ValueKind == JsonValueKind.String)
                {
                    var s = content.GetString() ?? "";
                    if (meta) { if (VoiceReply(s) is { } voice) Add("voice", voice); }
                    else if (UserText(s) is { } text) Add("user", text);
                    continue;
                }
                foreach (var b in Blocks(content))
                {
                    switch (Str(b, "type"))
                    {
                        case "text" when !meta:
                            if (UserText(Str(b, "text") ?? "") is { } text) Add("user", text);
                            break;
                        case "image":
                            Add("image", who: "user");
                            break;
                        case "tool_result":
                            if (b.TryGetProperty("content", out var inner))
                                foreach (var c in Blocks(inner))
                                    if (Str(c, "type") == "image") Add("image", who: "assistant");
                            break;
                    }
                }
            }
        }
        return output;
    }

    // {"t":"history","id":…,"items":[…],"more":…} (+ `before` for an older page), oldest items
    // dropped until it fits a relay frame (then there is more).
    public static string HistoryFrame(string session, List<Item> items, string? before = null, bool more = false)
    {
        var list = items.ToList();
        while (true)
        {
            var json = JsonSerializer.Serialize(new { t = "history", id = session, before, more, items = list }, Json);
            if (Encoding.UTF8.GetByteCount(json) <= MaxFrame || list.Count == 0) return json;
            list.RemoveRange(0, Math.Max(1, list.Count / 4));
            more = true;
        }
    }

    // ---- past sessions (POST /past — the Zentrale looks one up to resume it) -------------

    public sealed record Past(
        [property: JsonPropertyName("id")] string Id,
        [property: JsonPropertyName("title")] string Title,
        [property: JsonPropertyName("cwd")] string Cwd,
        [property: JsonPropertyName("lastPrompt")] string? LastPrompt,
        [property: JsonPropertyName("lastAt")] double LastAt);

    // The newest sessions (up to `limit`) whose title, folder or last prompt contains `query`
    // (all of them for an empty query). Scans the `scan` most recently written transcripts.
    public static List<Past> FindPast(string? query, int limit = 10, string? root = null, int scan = 400)
    {
        root ??= Projects;
        if (!Directory.Exists(root)) return new List<Past>();
        var files = Directory.EnumerateDirectories(root)
            .SelectMany(d => Directory.EnumerateFiles(d, "*.jsonl"))
            .Select(f => new FileInfo(f))
            .OrderByDescending(f => f.LastWriteTimeUtc)
            .Take(scan);
        var q = (query ?? "").Trim();
        var output = new List<Past>();
        foreach (var f in files)
        {
            if (Summary(f.FullName) is not { } p) continue;
            if (q.Length == 0 || new[] { p.Title, p.Cwd, p.LastPrompt ?? "" }.Any(s => s.Contains(q, StringComparison.OrdinalIgnoreCase)))
                output.Add(p);
            if (output.Count >= limit) break;
        }
        return output;
    }

    // Title, folder and last prompt of one transcript; null when it has no folder (not a session).
    public static Past? Summary(string path)
    {
        string cwd = "";
        foreach (var line in HeadLines(path, 64 << 10))
            if (Field(line, "cwd") is { Length: > 0 } c) { cwd = c; break; }
        if (cwd.Length == 0) return null;
        string? title = null, prompt = null;
        var tail = TailLines(path, 256 << 10);
        for (var i = tail.Count - 1; i >= 0 && (title is null || prompt is null); i--)
        {
            title ??= Field(tail[i], "customTitle") ?? Field(tail[i], "summary");
            if (prompt is null && Field(tail[i], "lastPrompt") is { Length: > 0 } p)
            {
                var one = string.Join(" ", p.Split('\n', '\r'));
                prompt = one.Length > 120 ? one[..120] + "…" : one;
            }
        }
        var info = new FileInfo(path);
        return new Past(Path.GetFileNameWithoutExtension(path), title ?? prompt ?? Path.GetFileName(cwd.TrimEnd('/', '\\')),
            cwd, prompt, Math.Round(new DateTimeOffset(info.LastWriteTimeUtc).ToUnixTimeMilliseconds() * 1.0));
    }

    public static string PastJson(List<Past> list) => JsonSerializer.Serialize(new { sessions = list }, Json);

    // The first `bytes` of the file as whole JSON lines (the last, partial one dropped).
    public static List<string> HeadLines(string path, int bytes)
    {
        try
        {
            using var f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var buffer = new byte[bytes];
            var n = f.Read(buffer, 0, bytes);
            var lines = Encoding.UTF8.GetString(buffer, 0, n).Split('\n', StringSplitOptions.RemoveEmptyEntries).ToList();
            if (n == bytes && lines.Count > 0) lines.RemoveAt(lines.Count - 1);
            return lines;
        }
        catch { return new List<string>(); }
    }

    // A Claude Code session id, safe to put on a command line.
    public static bool IsSessionId(string s) => s.Length is >= 8 and <= 64 && s.All(c => char.IsAsciiLetterOrDigit(c) || c == '-');

    private static string? Field(string line, string key)
    {
        try
        {
            using var doc = JsonDocument.Parse(line);
            return doc.RootElement.ValueKind == JsonValueKind.Object && Str(doc.RootElement, key) is { Length: > 0 } v ? v : null;
        }
        catch { return null; }
    }

    // ---- images ----------------------------------------------------------------------

    // The image `key` ("<uuid>#<n>", as in the items) as a JPEG that fits a relay frame.
    public static byte[]? Image(string path, string key)
    {
        var parts = key.Split('#');
        if (parts.Length != 2 || !int.TryParse(parts[1], out var n)) return null;
        var needle = $"\"uuid\":\"{parts[0]}\"";
        try
        {
            foreach (var line in System.IO.File.ReadLines(path))
            {
                if (!line.Contains(needle)) continue;
                var entry = Items(new[] { line });
                if (n >= entry.Count || entry[n].K != "image") return null;
                var index = entry.Take(n).Count(i => i.K == "image");
                using var doc = JsonDocument.Parse(line);
                var b64 = Images(doc.RootElement).Skip(index).FirstOrDefault();
                return b64 is null ? null : Jpeg(Convert.FromBase64String(b64));
            }
        }
        catch (Exception e) { Log.Write($"transcript: image {key} failed ({e.Message})"); }
        return null;
    }

    // The base64 payloads of an entry's images, in item order.
    private static IEnumerable<string> Images(JsonElement e)
    {
        if (!e.TryGetProperty("message", out var msg) || !msg.TryGetProperty("content", out var content)) yield break;
        foreach (var b in Blocks(content))
        {
            var images = Str(b, "type") == "image" ? new[] { b }
                : b.TryGetProperty("content", out var inner) ? Blocks(inner).Where(c => Str(c, "type") == "image").ToArray()
                : Array.Empty<JsonElement>();
            foreach (var img in images)
                if (img.TryGetProperty("source", out var src) && Str(src, "data") is { } data) yield return data;
        }
    }

    // Downscaled JPEG (≤ 1280 px, smaller until it fits a frame as base64).
    public static byte[]? Jpeg(byte[] raw)
    {
        using var input = new MemoryStream(raw);
        using var src = System.Drawing.Image.FromStream(input);
        var codec = ImageCodecInfo.GetImageEncoders().First(c => c.FormatID == ImageFormat.Jpeg.Guid);
        foreach (var (px, q) in new[] { (1280, 70L), (960, 60L), (640, 50L) })
        {
            var scale = Math.Min(1.0, (double)px / Math.Max(src.Width, src.Height));
            using var bmp = new Bitmap(Math.Max(1, (int)(src.Width * scale)), Math.Max(1, (int)(src.Height * scale)));
            using (var g = Graphics.FromImage(bmp))
            {
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.Clear(Color.White);   // transparent PNG → white, not black
                g.DrawImage(src, 0, 0, bmp.Width, bmp.Height);
            }
            using var output = new MemoryStream();
            using var p = new EncoderParameters(1);
            p.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, q);
            bmp.Save(output, codec, p);
            if (output.Length * 4 / 3 < MaxFrame - 1024) return output.ToArray();
        }
        return null;
    }

    public static string ImageFrame(string key, byte[]? jpeg) =>
        JsonSerializer.Serialize(new { t = "image", key, mime = "image/jpeg", data = jpeg is null ? null : Convert.ToBase64String(jpeg) }, Json);

    // ---- text ------------------------------------------------------------------------

    private static readonly Regex ReplyLine = new(@"(?m)^\s*<reply\b[^>]*>.*?</reply>\s*$\n?");
    private static readonly Regex SpeakTail = new(@"<speak(?:-end)?>(?:(?!</speak)[\s\S])*(?:</speak(?:-end)?>)?\s*$");
    private static readonly Regex SpeakTag = new(@"</?speak(?:-end)?>");

    // Assistant text without the voice plumbing: <reply> lines dropped, the final <speak> /
    // <speak-end> line returned on its own.
    public static (string Body, string? Spoken) Split(string text)
    {
        var body = ReplyLine.Replace(text, "");
        string? spoken = null;
        var last = body.LastIndexOf("<speak", StringComparison.Ordinal);   // earlier mentions are prose
        if (last >= 0 && SpeakTail.Match(body, last) is { Success: true } m)
        {
            spoken = SpeakTag.Replace(m.Value, "").Trim();
            body = body.Remove(m.Index, m.Length);
        }
        return (body.Trim(), string.IsNullOrEmpty(spoken) ? null : spoken);
    }

    // A voice reply ("Stop hook feedback:\n…") without Parley's own notes; null for other meta.
    public static string? VoiceReply(string s)
    {
        const string prefix = "Stop hook feedback:\n";
        if (!s.Replace("\r\n", "\n").StartsWith(prefix, StringComparison.Ordinal)) return null;
        var text = string.Join("\n", s.Replace("\r\n", "\n")[prefix.Length..].Split('\n')
            .Where(l => !l.StartsWith("[Parley ", StringComparison.Ordinal))).Trim();
        return text.Length == 0 ? null : text;
    }

    // What the user typed; slash commands as "/name args"; system-injected blocks dropped.
    public static string? UserText(string s)
    {
        var t = s.Trim();
        if (Tag("command-name", t) is { } name)
        {
            var args = Tag("command-args", t) ?? "";
            return args.Length == 0 ? name : $"{name} {args}";
        }
        return t.Length == 0 || t.StartsWith('<') ? null : t;
    }

    private static string? Tag(string name, string s)
    {
        var m = Regex.Match(s, $@"<{name}>([\s\S]*?)</{name}>");
        return m.Success ? m.Groups[1].Value.Trim() : null;
    }

    // "Bash · git status" — the tool's short name and what it was for.
    public static string Tool(string name, JsonElement input)
    {
        var shortName = name.Split("__").Last();   // mcp__server__tool → tool
        string? detail = null;
        if (input.ValueKind == JsonValueKind.Object)
            foreach (var key in new[] { "description", "command", "file_path", "pattern", "url", "query", "action", "prompt" })
                if (Str(input, key) is { Length: > 0 } v) { detail = v; break; }
        if (detail is null) return shortName;
        if (detail.StartsWith('/') || detail.Contains(":\\")) detail = Path.GetFileName(detail.Replace('\\', '/').TrimEnd('/')) is { Length: > 0 } f ? f : detail;
        var line = detail.Split('\n')[0];
        return $"{shortName} · {(line.Length > 90 ? line[..90] + "…" : line)}";
    }

    // Lines a file tool added / removed (the phone's "+62 −0"), null for other tools.
    public static (int Add, int Del)? Diff(string name, JsonElement input)
    {
        if (input.ValueKind != JsonValueKind.Object) return null;
        static int Lines(string? s) => string.IsNullOrEmpty(s) ? 0 : s.Split('\n').Length - (s.EndsWith('\n') ? 1 : 0);
        switch (name)
        {
            case "Write": return (Lines(Str(input, "content")), 0);
            case "Edit": return (Lines(Str(input, "new_string")), Lines(Str(input, "old_string")));
            case "MultiEdit":
                var edits = input.TryGetProperty("edits", out var e) ? Blocks(e).ToList() : new List<JsonElement>();
                return (edits.Sum(x => Lines(Str(x, "new_string"))), edits.Sum(x => Lines(Str(x, "old_string"))));
            default: return null;
        }
    }

    private static string Clip(string s) => s.Length > MaxText ? s[..MaxText] + "…" : s;

    private static IEnumerable<JsonElement> Blocks(JsonElement e) =>
        e.ValueKind == JsonValueKind.Array ? e.EnumerateArray().Where(b => b.ValueKind == JsonValueKind.Object) : Enumerable.Empty<JsonElement>();

    private static string? Str(JsonElement e, string key) =>
        e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static bool Bool(JsonElement e, string key) =>
        e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.True;
}
