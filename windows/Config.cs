using System.Text.Json;

namespace Parley;

// Same contract as the macOS app: a plain JSON credential file, same key names, so the
// docs and the Claude-Code install prompt work identically on both platforms.
// Location: %APPDATA%\Parley\credentials.json
public sealed class Config
{
    public string GoogleKey { get; init; } = "";
    public string GoogleVoice { get; init; } = "de-DE-Chirp3-HD-Alnilam";
    public string GroqKey { get; init; } = "";
    public string Language { get; init; } = "Deutsch";
    public double SpeakingRate { get; init; } = 1.0;
    public bool NotifyInPill { get; init; }

    public bool UseGoogle => GoogleKey.Length > 0;
    public bool SttReady => GroqKey.Length > 0;

    public static string Dir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Parley");

    public static string CredentialsPath => Path.Combine(Dir, "credentials.json");

    public static Config Load()
    {
        try
        {
            var json = File.ReadAllText(CredentialsPath);
            var d = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(json) ?? new();
            string S(string k, string fallback = "") =>
                d.TryGetValue(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? fallback : fallback;
            var rateStr = S("speakingRate", "1.0");
            double.TryParse(rateStr, System.Globalization.CultureInfo.InvariantCulture, out var rate);
            if (rate <= 0) rate = 1.0;
            var voice = S("googleVoice");
            return new Config
            {
                GoogleKey = S("googleAPIKey"),
                GoogleVoice = voice.Length > 0 ? voice : "de-DE-Chirp3-HD-Alnilam",
                GroqKey = S("groqAPIKey"),
                Language = S("language", "Deutsch"),
                SpeakingRate = Math.Clamp(rate, 0.5, 2.0),
                NotifyInPill = S("notifyInPill") == "1",
            };
        }
        catch
        {
            return new Config();
        }
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
