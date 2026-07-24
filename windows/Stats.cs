using System.Text.Json;
using System.Text.Json.Serialization;

namespace Parley;

// Usage statistics — port of the macOS StatsData/StatsStore. All-time record persists to
// %APPDATA%\Parley\stats.json; the session record resets on /ready. Monthly TTS-character
// accounting (Google Chirp3 HD: first 1M chars/month free, then $30/1M).
public sealed class StatsData
{
    public const int FreeCharsPerMonth = 1_000_000;
    public const double DollarsPerMillionChars = 30.0;

    [JsonPropertyName("turns")] public int Turns { get; set; }
    [JsonPropertyName("charsSpoken")] public int CharsSpoken { get; set; }
    [JsonPropertyName("parleyWords")] public int ParleyWords { get; set; }
    [JsonPropertyName("userWords")] public int UserWords { get; set; }
    [JsonPropertyName("userSpeakingSeconds")] public double UserSpeakingSeconds { get; set; }
    [JsonPropertyName("timeSavedSeconds")] public double TimeSavedSeconds { get; set; }
    [JsonPropertyName("activeSeconds")] public double ActiveSeconds { get; set; }
    [JsonPropertyName("sessions")] public int Sessions { get; set; }
    [JsonPropertyName("intents")] public Dictionary<string, int> Intents { get; set; } = new();
    [JsonPropertyName("projectTurns")] public Dictionary<string, int> ProjectTurns { get; set; } = new();
    [JsonPropertyName("charMonth")] public string CharMonth { get; set; } = "";
    [JsonPropertyName("charsThisMonth")] public int CharsThisMonth { get; set; }

    [JsonIgnore] public int BillableCharsThisMonth => Math.Max(0, CharsThisMonth - FreeCharsPerMonth);
    [JsonIgnore] public double EstimatedDollarsThisMonth => BillableCharsThisMonth / 1_000_000.0 * DollarsPerMillionChars;

    public void Record(string speak, string transcript, double recordSeconds, string intent, string project, string month)
    {
        Turns++;
        CharsSpoken += speak.Length;
        ParleyWords += WordCount(speak);
        var uw = WordCount(transcript);
        UserWords += uw;
        UserSpeakingSeconds += recordSeconds;
        TimeSavedSeconds += Math.Max(0, uw / 40.0 * 60.0 - recordSeconds);   // typing at 40 wpm
        Intents[intent] = Intents.GetValueOrDefault(intent) + 1;
        if (project.Length > 0) ProjectTurns[project] = ProjectTurns.GetValueOrDefault(project) + 1;
        if (CharMonth != month) { CharMonth = month; CharsThisMonth = 0; }
        CharsThisMonth += speak.Length;
    }

    private static int WordCount(string s) =>
        s.Split(' ', '\t', '\n', '\r').Count(w => w.Length > 0);
}

public static class StatsStore
{
    private static readonly object Gate = new();
    public static StatsData Total { get; private set; } = LoadFromDisk();
    public static StatsData Session { get; private set; } = new();

    private static string PathFor => Path.Combine(Config.Dir, "stats.json");

    public static void StartSession()
    {
        lock (Gate)
        {
            Session = new StatsData { Sessions = 1 };
            Total.Sessions++;
            Save();
        }
    }

    private static string _costWarnedMonth = "";

    public static void RecordTurn(string speak, string transcript, double recordSeconds, string intent, string project)
    {
        var month = DateTime.UtcNow.ToString("yyyy-MM");
        lock (Gate)
        {
            Total.Record(speak, transcript, recordSeconds, intent, project, month);
            Session.Record(speak, transcript, recordSeconds, intent, project, month);
            Save();

            // Cost warning at 90% of the free monthly TTS-character tier — once per month.
            var threshold = (int)(StatsData.FreeCharsPerMonth * 0.9);
            if (Total.CharsThisMonth >= threshold && _costWarnedMonth != month)
            {
                _costWarnedMonth = month;
                var pct = (int)(Total.CharsThisMonth / (double)StatsData.FreeCharsPerMonth * 100);
                Notifier.Notify("Parley — Kosten",
                    $"Google-Gratiskontingent zu {pct}% genutzt ({Total.CharsThisMonth} / {StatsData.FreeCharsPerMonth} Zeichen).");
            }
        }
    }

    private static StatsData LoadFromDisk()
    {
        try { return JsonSerializer.Deserialize<StatsData>(File.ReadAllText(PathFor)) ?? new(); }
        catch { return new(); }
    }

    private static void Save()
    {
        try
        {
            Directory.CreateDirectory(Config.Dir);
            File.WriteAllText(PathFor, JsonSerializer.Serialize(Total, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }
}

// Learned TTS synthesis-latency model (EWMA seconds-per-char) — port of TTSTiming.
public static class TtsTiming
{
    private static string PathFor => Path.Combine(Config.Dir, "tts-timing.txt");

    public static double Predict(int chars)
    {
        double spc = 0.012;
        try
        {
            if (double.TryParse(File.ReadAllText(PathFor),
                System.Globalization.CultureInfo.InvariantCulture, out var v) && v > 0) spc = v;
        }
        catch { }
        return Math.Clamp(spc * Math.Max(chars, 1), 0.3, 8.0);
    }

    public static void Record(int chars, double seconds)
    {
        if (chars <= 0 || seconds < 0.05 || seconds > 30) return;
        var sample = seconds / chars;
        double old = 0;
        try
        {
            double.TryParse(File.ReadAllText(PathFor),
                System.Globalization.CultureInfo.InvariantCulture, out old);
        }
        catch { }
        var updated = old > 0 ? old * 0.7 + sample * 0.3 : sample;
        try
        {
            Directory.CreateDirectory(Config.Dir);
            File.WriteAllText(PathFor, updated.ToString(System.Globalization.CultureInfo.InvariantCulture));
        }
        catch { }
    }
}

// Live-session tracking for multi-instance announcements ("more than one project running").
public static class SessionTracker
{
    private static readonly object Gate = new();
    private static readonly Dictionary<string, DateTime> LastActive = new();   // project → last seen

    public static void Touch(string project)
    {
        if (project.Length == 0) return;
        lock (Gate) LastActive[project] = DateTime.UtcNow;
    }

    /// Distinct projects seen within the last 5 minutes.
    public static int LiveProjectCount()
    {
        var cutoff = DateTime.UtcNow.AddMinutes(-5);
        lock (Gate) return LastActive.Count(kv => kv.Value > cutoff);
    }
}
