using System.Text.Json;

namespace Parley;

// Protocol v13 (docs/IPHONE.md): the phone says its build in `hello`; the newest TestFlight build
// and what each build brought come from ios/whats-new.json on main. Sir hears once per build, at
// the start of a call, what is new in his app — or that a newer one is waiting. 1:1 with macOS.
public static class AppNews
{
    public const string Url = "https://raw.githubusercontent.com/Lidyrius/parley/main/ios/whats-new.json";

    public sealed record Build(int Number, string Text);

    private static readonly object Gate = new();
    private static int? _phone;                  // the phone's build, from its last hello
    private static int _latest;
    private static List<Build> _builds = new();
    private static DateTime _fetched = DateTime.MinValue;
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(10) };
    private static string StatePath => Path.Combine(Config.Dir, "news.json");

    // whats-new.json → (latest, builds newest first). Pure.
    public static (int Latest, List<Build> Builds) Parse(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        var builds = new List<Build>();
        if (root.TryGetProperty("builds", out var bs) && bs.ValueKind == JsonValueKind.Array)
            foreach (var b in bs.EnumerateArray())
                if (b.TryGetProperty("build", out var n) && n.TryGetInt32(out var num)
                    && b.TryGetProperty("text", out var t) && t.GetString() is { Length: > 0 } text)
                    builds.Add(new Build(num, text));
        builds.Sort((a, b) => b.Number.CompareTo(a.Number));
        var latest = root.TryGetProperty("latest", out var l) && l.TryGetInt32(out var lv) ? lv : builds.FirstOrDefault()?.Number ?? 0;
        return (latest, builds);
    }

    // hello: remember the build, refresh the notes (at most every 6 h).
    public static void OnHello(int? build)
    {
        if (build is null) return;
        lock (Gate) _phone = build;
        if (DateTime.UtcNow - _fetched > TimeSpan.FromHours(6)) _ = Fetch();
    }

    private static async Task Fetch()
    {
        _fetched = DateTime.UtcNow;
        try
        {
            var (latest, builds) = Parse(await Http.GetStringAsync(Url));
            lock (Gate) { _latest = latest; _builds = builds; }
        }
        catch (Exception e) { Log.Write($"news: not fetched: {e.Message}"); }
    }

    // For /sessions: {latest, news} while the phone is behind, else null (omitted).
    public static object? Wire()
    {
        lock (Gate)
        {
            if (_phone is not { } phone || _latest <= phone) return null;
            return new { latest = _latest, news = _builds.Where(b => b.Number > phone).Take(5).Select(b => new { build = b.Number, text = b.Text }).ToList() };
        }
    }

    // The line before the first update of a call, or null. Pure: (phone, latest, builds, told, offered).
    public static (string? Line, int Told, int Offered) Next(int phone, int latest, List<Build> builds, int? told, int offered)
    {
        var since = told ?? phone - 1;   // never told: what this build brought, once
        if (phone > since)
        {
            var news = builds.Where(b => b.Number > since && b.Number <= phone).Take(3).Select(b => b.Text).ToList();
            if (news.Count > 0)
                return ($"Kurz vorweg, Sir: Ihre App ist aktualisiert. Neu: {string.Join(" ", news)}", phone, Math.Max(offered, phone));
            return (null, phone, offered);
        }
        if (latest > phone && latest > offered)
        {
            var news = builds.Where(b => b.Number > phone && b.Number <= latest).Take(3).Select(b => b.Text).ToList();
            var tail = news.Count > 0 ? " Neu darin: " + string.Join(" ", news) : "";
            return ($"Kurz vorweg, Sir: In TestFlight wartet eine neue Version Ihrer App.{tail}", phone, latest);
        }
        return (null, since, offered);
    }

    // Call start: the line to speak once (and remember it was said), or null.
    public static string? TakeLine(Config c)
    {
        if (c.Language != "Deutsch") return null;   // ponytail: notes are German only
        int phone, latest; List<Build> builds;
        lock (Gate)
        {
            if (_phone is not { } p || _builds.Count == 0) return null;
            phone = p; latest = _latest; builds = _builds;
        }
        int? told = null; var offered = 0;
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(StatePath));
            if (doc.RootElement.TryGetProperty("told", out var t) && t.TryGetInt32(out var tv)) told = tv;
            if (doc.RootElement.TryGetProperty("offered", out var o) && o.TryGetInt32(out var ov)) offered = ov;
        }
        catch { }
        var (line, newTold, newOffered) = Next(phone, latest, builds, told, offered);
        if (newTold != told || newOffered != offered)
            try { File.WriteAllText(StatePath, JsonSerializer.Serialize(new { told = newTold, offered = newOffered })); }
            catch (Exception e) { Log.Write($"news: state not saved: {e.Message}"); }
        if (line is not null) Log.Write($"news: telling Sir (phone {phone}, latest {latest})");
        return line;
    }
}
