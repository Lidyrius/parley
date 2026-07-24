using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace Parley;

// Groq Whisper transcription + intent classification — same models and prompts as macOS.
public static class Groq
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };

    /// wav: 16 kHz mono 16-bit WAV bytes. Returns "" on failure (never an error body).
    public static async Task<string> Transcribe(byte[] wav, Config config)
    {
        if (!config.SttReady) return "";
        try
        {
            using var form = new MultipartFormDataContent();
            var file = new ByteArrayContent(wav);
            file.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
            form.Add(file, "file", "reply.wav");
            form.Add(new StringContent("whisper-large-v3-turbo"), "model");
            form.Add(new StringContent("text"), "response_format");
            using var req = new HttpRequestMessage(HttpMethod.Post,
                "https://api.groq.com/openai/v1/audio/transcriptions");
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", config.GroqKey);
            req.Content = form;
            using var resp = await Http.SendAsync(req);
            var body = await resp.Content.ReadAsStringAsync();
            if (!resp.IsSuccessStatusCode)
            {
                var code = (int)resp.StatusCode;
                Log.Write($"stt http {code}: {body[..Math.Min(200, body.Length)]}");
                Notifier.Notify("Parley — Fehler", $"Transkription fehlgeschlagen (HTTP {code}).");
                return "";
            }
            return body.Trim();
        }
        catch (Exception e)
        {
            Log.Write($"stt error: {e.Message}");
            return "";
        }
    }

    public enum Intent { Feature, Bug, Research, Question, Stop, Continue, FeatureResearch, BugFeature, Other }

    private const string ClassifierSystem =
        "You classify a user's spoken reply to a coding assistant into exactly one category. " +
        "Reply with ONLY the category word. Categories: FEATURE (asks to build/add something), " +
        "BUG (reports something broken to fix), RESEARCH (asks to research/investigate), " +
        "QUESTION (asks a question expecting an answer), STOP (wants to stop/end the session), " +
        "CONTINUE (says to continue/proceed), FEATURE_RESEARCH (research then build), " +
        "BUG_FEATURE (fix a bug and build something), OTHER (anything else).";

    public static async Task<Intent> Classify(string text, Config config)
    {
        if (!config.SttReady || text.Length == 0) return Intent.Other;
        try
        {
            var payload = new
            {
                model = "llama-3.3-70b-versatile",
                temperature = 0,
                max_tokens = 8,
                messages = new object[]
                {
                    new { role = "system", content = ClassifierSystem },
                    new { role = "user", content = text },
                },
            };
            using var req = new HttpRequestMessage(HttpMethod.Post,
                "https://api.groq.com/openai/v1/chat/completions");
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", config.GroqKey);
            req.Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json");
            using var resp = await Http.SendAsync(req);
            if (!resp.IsSuccessStatusCode) return Intent.Other;
            using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync());
            var content = doc.RootElement.GetProperty("choices")[0]
                .GetProperty("message").GetProperty("content").GetString() ?? "";
            var u = content.ToUpperInvariant();
            // combos before substrings — same match order as macOS
            if (u.Contains("FEATURE_RESEARCH")) return Intent.FeatureResearch;
            if (u.Contains("BUG_FEATURE")) return Intent.BugFeature;
            if (u.Contains("FEATURE")) return Intent.Feature;
            if (u.Contains("BUG")) return Intent.Bug;
            if (u.Contains("RESEARCH")) return Intent.Research;
            if (u.Contains("QUESTION")) return Intent.Question;
            if (u.Contains("STOP")) return Intent.Stop;
            if (u.Contains("CONTINUE")) return Intent.Continue;
            return Intent.Other;
        }
        catch { return Intent.Other; }
    }
}
