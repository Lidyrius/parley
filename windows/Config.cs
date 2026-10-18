using System.Text.Json;

namespace Parley;

// Same contract as the macOS app: a plain JSON credential file, same key names, so the
// docs and the Claude-Code install prompt work identically on both platforms.
// Location: %APPDATA%\Parley\credentials.json
public sealed class Config
{
    public string GoogleKey { get; init; } = "";
    public string GoogleVoice { get; set; } = "de-DE-Chirp3-HD-Alnilam";
    public string GroqKey { get; init; } = "";
    public string Language { get; init; } = "Deutsch";
    public double SpeakingRate { get; init; } = 1.0;
    public string NotifyMode { get; init; } = "pill";   // "pill" | "system" | "none"
    public bool DetectedClaudeCode { get; init; }
    public bool DetectedCodex { get; init; }
    public bool? ClaudeCodeEnabled { get; init; }
    public bool? CodexEnabled { get; init; }
    public string SourceDir { get; init; } = "";
    public string RelayUrl { get; init; } = "";      // iPhone relay base URL (docs/IPHONE.md); empty = no iPhone connection
    public string RelayRoom { get; init; } = "";     // the relay room (16 random bytes, base64url), created on first pairing
    public string RelaySecret { get; init; } = "";   // the room's secret (32 random bytes, base64url)
    // iPhone protocol v2 (docs/IPHONE.md): the Zentrale's folder, where it creates projects, the
    // APNs key for ringing, and what the phone told us (VoIP token, Unterwegs-Modus).
    public string ZentraleDir { get; init; } = DefaultZentraleDir;
    public string ProjectsDir { get; init; } = DefaultProjectsDir;
    public string ApnsKeyId { get; init; } = "";
    public string ApnsTeamId { get; init; } = Apns.DefaultTeamId;
    public string ApnsKeyP8 { get; init; } = "";     // the .p8 PEM text
    public string PhonePushToken { get; init; } = "";
    public string PhonePushEnv { get; init; } = "production";   // production | development
    public bool PhoneAway { get; init; }
    public bool PhoneSilent { get; init; }          // Unterwegs + Stumm: a notification instead of a call
    public string PhoneAlertToken { get; init; } = "";   // notification push token (hex)
    public string PhoneActivityStart { get; init; } = "";   // Live Activity push-to-start token (hex)
    public string PhoneActivityToken { get; init; } = "";   // the running Live Activity's update token; "" = none
    public bool AutoAwayOnLock { get; init; }   // the PC locked for a minute counts as Unterwegs
    public bool BargeIn { get; init; } = true;  // talking over Parley stops it and it listens
    public string AppIcon { get; init; } = "porzellan";   // tray → App-Symbol (AppIcon.Choices id)

    public bool UseGoogle => GoogleKey.Length > 0;
    public bool SttReady => GroqKey.Length > 0;

    private static string ResolveNotifyMode(string mode, string legacy)
    {
        if (mode is "pill" or "system" or "none") return mode;
        return legacy == "0" ? "system" : "pill";
    }

    public static string Dir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Parley");

    public static string CredentialsPath => Path.Combine(Dir, "credentials.json");

    private static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    public static string DefaultProjectsDir => Path.Combine(Home, "workspace", "privat");
    public static string DefaultZentraleDir => Path.Combine(Home, "workspace", "privat", "parley-zentrale");

    // The Parley checkout (integration scripts, the zentrale\ template): sourceDir, else where
    // the installer puts it.
    public string ResolvedSourceDir =>
        SourceDir.Trim().Length > 0 ? SourceDir.Trim() : Path.Combine(Home, ".parley", "src");

    public static Config Load()
    {
        try
        {
            var json = File.ReadAllText(CredentialsPath);
            var d = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(json) ?? new();
            string S(string k, string fallback = "") =>
                d.TryGetValue(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? fallback : fallback;
            bool? B(string k)
            {
                var value = S(k);
                return value switch { "1" => true, "0" => false, _ => null };
            }
            var rateStr = S("speakingRate", "1.0");
            double.TryParse(rateStr, System.Globalization.CultureInfo.InvariantCulture, out var rate);
            if (rate <= 0) rate = 1.0;
            var voice = S("googleVoice");
            string Or(string key, string fallback) => S(key).Trim() is { Length: > 0 } v ? v : fallback;
            return new Config
            {
                GoogleKey = S("googleAPIKey"),
                GoogleVoice = voice.Length > 0 ? voice : "de-DE-Chirp3-HD-Alnilam",
                GroqKey = S("groqAPIKey"),
                Language = S("language", "Deutsch"),
                SpeakingRate = Math.Clamp(rate, 0.5, 2.0),
                NotifyMode = ResolveNotifyMode(S("notifyMode"), S("notifyInPill")),
                DetectedClaudeCode = S("detectedClaudeCode") == "1",
                DetectedCodex = S("detectedCodex") == "1",
                ClaudeCodeEnabled = B("claudeCodeEnabled"),
                CodexEnabled = B("codexEnabled"),
                SourceDir = S("sourceDir"),
                RelayUrl = S("relayUrl"),
                RelayRoom = S("relayRoom"),
                RelaySecret = S("relaySecret"),
                ZentraleDir = Or("zentraleDir", DefaultZentraleDir),
                ProjectsDir = Or("projectsDir", DefaultProjectsDir),
                ApnsKeyId = S("apnsKeyId").Trim(),
                ApnsTeamId = Or("apnsTeamId", Apns.DefaultTeamId),
                ApnsKeyP8 = S("apnsKeyP8"),
                PhonePushToken = S("phonePushToken").Trim(),
                PhonePushEnv = S("phonePushEnv") == "development" ? "development" : "production",
                PhoneAway = S("phoneAway") == "1",
                PhoneSilent = S("phoneSilent") == "1",
                PhoneAlertToken = S("phoneAlertToken").Trim(),
                PhoneActivityStart = S("phoneActivityStart").Trim(),
                PhoneActivityToken = S("phoneActivityToken").Trim(),
                AutoAwayOnLock = S("autoAwayOnLock") == "1",
                BargeIn = S("bargeIn") != "0",
                AppIcon = S("appIcon", "porzellan"),
            };
        }
        catch
        {
            return new Config();
        }
    }

    // Merge string values into credentials.json (indented, like the settings forms); every other
    // key survives as it was. False if an existing file can't be read — it stays untouched.
    public static bool Merge(IReadOnlyDictionary<string, string> values)
    {
        Dictionary<string, JsonElement> d = new();
        try
        {
            if (File.Exists(CredentialsPath))
                d = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(File.ReadAllText(CredentialsPath)) ?? new();
        }
        catch (Exception e)
        {
            Log.Write($"credentials.json unreadable, left as is: {e.Message}");
            return false;
        }
        foreach (var kv in values) d[kv.Key] = JsonSerializer.SerializeToElement(kv.Value);
        Directory.CreateDirectory(Dir);
        File.WriteAllText(CredentialsPath, JsonSerializer.Serialize(d, new JsonSerializerOptions { WriteIndented = true }));
        return true;
    }
}

public static class IntegrationSync
{
    public static void Apply()
    {
        var cfg = Config.Load();
        var source = cfg.SourceDir;
        if (string.IsNullOrWhiteSpace(source))
            source = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".parley", "src");
        var script = Path.Combine(source, "windows", "sync-integrations.ps1");
        if (!File.Exists(script)) return;
        try
        {
            using var p = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-NoProfile -ExecutionPolicy Bypass -File \"{script}\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            });
            p?.WaitForExit(30000);
        }
        catch { }
    }
}

public static class Log
{
    private static readonly object Gate = new();
    private static string PathFor => System.IO.Path.Combine(Config.Dir, "debug.log");

    public static void Write(string message)
    {
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(Config.Dir);
                File.AppendAllText(PathFor, $"{DateTime.UtcNow:yyyy-MM-ddTHH:mm:ss.fffZ} {message}\r\n");
            }
        }
        catch { /* logging must never throw */ }
    }
}
