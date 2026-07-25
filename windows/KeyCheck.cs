using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace Parley;

// Live API-key verification for onboarding — a tiny request each.
public static class KeyCheck
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(10) };

    public static async Task<(bool ok, string msg)> Google(string key, string voice)
    {
        if (string.IsNullOrEmpty(key)) return (false, "kein Schlüssel");
        var lang = string.Join("-", voice.Split('-').Take(2));
        var payload = new
        {
            input = new { text = "Hallo" },
            voice = new { languageCode = lang, name = voice },
            audioConfig = new { audioEncoding = "LINEAR16", sampleRateHertz = 24000 },
        };
        using var req = new HttpRequestMessage(HttpMethod.Post, "https://texttospeech.googleapis.com/v1/text:synthesize");
        req.Headers.Add("X-Goog-Api-Key", key);
        req.Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json");
        try
        {
            using var r = await Http.SendAsync(req);
            var c = (int)r.StatusCode;
            return c switch { 200 => (true, "gültig"), 403 => (false, "HTTP 403 — API aktiviert?"), 400 => (false, "HTTP 400 — Schlüssel/Stimme?"), _ => (false, $"HTTP {c}") };
        }
        catch { return (false, "Netzwerkfehler"); }
    }

    public static async Task<(bool ok, string msg)> Groq(string key)
    {
        if (string.IsNullOrEmpty(key)) return (false, "kein Schlüssel");
        using var req = new HttpRequestMessage(HttpMethod.Get, "https://api.groq.com/openai/v1/models");
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        try
        {
            using var r = await Http.SendAsync(req);
            var c = (int)r.StatusCode;
            return c switch { 200 => (true, "gültig"), 401 => (false, "HTTP 401 — Schlüssel ungültig"), _ => (false, $"HTTP {c}") };
        }
        catch { return (false, "Netzwerkfehler"); }
    }
}
