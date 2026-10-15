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

    // Today's usage across all sessions (GET /sessions → today). Absent in older stats.json
    // files (→ null); only meaningful on the all-time record, where DailyStats.Shared owns it.
    [JsonPropertyName("today")] public DayStats? Today { get; set; }

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
            DailyStats.Shared.RecordTurn(recordSeconds);
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

    // Write stats.json now (DailyStats calls this when today's cost moved).
    public static void Persist() { lock (Gate) Save(); }

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
            Total.Today = DailyStats.Shared.Snapshot();   // the only writer of stats.json
            File.WriteAllText(PathFor, JsonSerializer.Serialize(Total, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }
}

// Today's usage across all sessions: voiced turns, seconds you spoke, and Claude cost. Rolls
// over at local midnight. Cost comes from the mod's cumulative per-session costUsd: only the
// increase since that session's last report counts, so restarts and repeated reports never
// double-count — the per-session baselines (costSeen) persist with the day. 1:1 with macOS.
public sealed class DayStats
{
    [JsonPropertyName("day")] public string Day { get; set; } = "";   // local "yyyy-MM-dd"
    [JsonPropertyName("turns")] public int Turns { get; set; }
    [JsonPropertyName("spokenSeconds")] public double SpokenSeconds { get; set; }
    [JsonPropertyName("costUsd")] public double CostUsd { get; set; }
    // session_id → last cumulative costUsd reported (at = epoch seconds).
    [JsonPropertyName("costSeen")] public Dictionary<string, CostMark> CostSeen { get; set; } = new();

    public DayStats Clone() => new()
    {
        Day = Day, Turns = Turns, SpokenSeconds = SpokenSeconds, CostUsd = CostUsd,
        CostSeen = new Dictionary<string, CostMark>(CostSeen),
    };
}

public sealed record CostMark(
    [property: JsonPropertyName("cost")] double Cost,
    [property: JsonPropertyName("at")] double At);

// Thread-safe owner of today's DayStats: cost arrives from /presence, turns from the
// pipeline. Persisted inside stats.json by StatsStore.Save().
public sealed class DailyStats
{
    public static readonly DailyStats Shared = new(StatsStore.Total.Today, null, StatsStore.Persist);

    private readonly object _gate = new();
    private DayStats _d;
    private readonly Func<DateTime> _now;
    private readonly Action _persist;

    public DailyStats(DayStats? day = null, Func<DateTime>? now = null, Action? persist = null)
    {
        _d = day ?? new DayStats();
        _now = now ?? (() => DateTime.UtcNow);
        _persist = persist ?? (() => { });
    }

    public void RecordTurn(double spokenSeconds)
    {
        lock (_gate) { Roll(_now()); _d.Turns++; _d.SpokenSeconds += spokenSeconds; }
    }

    // A session reported its cumulative cost. Known session → add the increase; unknown one
    // that started today → all of it accrued today; unknown and older → baseline only.
    public void AddCost(string session, double cumulative, DateTime? startedAt)
    {
        bool changed;
        lock (_gate)
        {
            var t = _now();
            Roll(t);
            if (_d.CostSeen.TryGetValue(session, out var last))
                _d.CostUsd += Math.Max(0, cumulative - last.Cost);
            else if (startedAt is { } s && s.ToLocalTime() >= t.ToLocalTime().Date)
                _d.CostUsd += Math.Max(0, cumulative);
            changed = last is null || last.Cost != cumulative;
            _d.CostSeen[session] = new CostMark(cumulative, (t - DateTime.UnixEpoch).TotalSeconds);
        }
        if (changed) _persist();   // outside the lock: Persist takes the StatsStore lock
    }

    public DayStats Snapshot()
    {
        lock (_gate) { Roll(_now()); return _d.Clone(); }
    }

    // New local day → zero the counters; keep cost baselines seen within the last 24 h.
    private void Roll(DateTime t)
    {
        var key = t.ToLocalTime().ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
        if (_d.Day == key) return;
        var nowS = (t - DateTime.UnixEpoch).TotalSeconds;
        _d = new DayStats
        {
            Day = key,
            CostSeen = _d.CostSeen.Where(kv => nowS - kv.Value.At < 86_400).ToDictionary(kv => kv.Key, kv => kv.Value),
        };
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
