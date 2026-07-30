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
            // Fail fast instead of hanging the hook — VPN/blocked networks otherwise stall.
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(20));
            using var resp = await Http.SendAsync(req, cts.Token);
            var body = await resp.Content.ReadAsStringAsync();
            if (!resp.IsSuccessStatusCode)
            {
                var code = (int)resp.StatusCode;
                Log.Write($"stt http {code}: {body[..Math.Min(200, body.Length)]}");
                // Groq blocks VPN / datacenter IPs with a 403 "check your network settings".
                Notifier.Notify("Parley — Fehler",
                    code == 403 ? "Groq blockt dieses Netzwerk — VPN aus?" : $"Transkription fehlgeschlagen (HTTP {code}).");
                return "";
            }
            return body.Trim();
        }
        catch (Exception e)
        {
            Log.Write($"stt error: {e.Message}");
            Notifier.Notify("Parley — Fehler", "Groq nicht erreichbar (Netzwerk/VPN?).");
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

    private const string WaitSystem =
        "The user speaks to a coding assistant. If they ask you to WAIT or PAUSE for a " +
        "duration before continuing (e.g. \"warte 5 Minuten\", \"mach 10 Minuten Pause\", " +
        "\"in einer halben Stunde\", \"wait 30 seconds\"), output ONLY the total number of " +
        "SECONDS as a plain integer. If they are NOT asking to wait for a set duration, " +
        "output 0. Output only the integer, nothing else.";

    /// Seconds the user asked to wait (0 = not a wait request; clamped 0…3600).
    public static async Task<int> ClassifyWait(string text, Config config)
    {
        if (!config.SttReady || text.Length == 0) return 0;
        try
        {
            var payload = new
            {
                model = "llama-3.3-70b-versatile",
                temperature = 0,
                max_tokens = 8,
                messages = new object[]
                {
                    new { role = "system", content = WaitSystem },
                    new { role = "user", content = text },
                },
            };
            using var req = new HttpRequestMessage(HttpMethod.Post,
                "https://api.groq.com/openai/v1/chat/completions");
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", config.GroqKey);
            req.Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json");
            using var resp = await Http.SendAsync(req);
            if (!resp.IsSuccessStatusCode) return 0;
            using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync());
            var content = doc.RootElement.GetProperty("choices")[0]
                .GetProperty("message").GetProperty("content").GetString() ?? "";
            var digits = new string(content.Where(char.IsDigit).ToArray());
            var n = int.TryParse(digits, out var v) ? v : 0;
            return n < 5 ? 0 : Math.Min(3600, n);
        }
        catch { return 0; }
    }

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

    public readonly record struct ControlResult(bool Resume, string Target, string Instruction);

    // Detects whether a spoken reply is a Parley CONTROL command (resume a paused project
    // by voice) rather than a normal reply. Only called when paused sessions exist.
    public static async Task<ControlResult?> DetectControlCommand(string text, IReadOnlyList<string> labels, Config config)
    {
        if (!config.SttReady || text.Length == 0 || labels.Count == 0) return null;
        var sys =
            "You route a spoken utterance in a voice coding assistant. Some projects are PAUSED " +
            "and can be resumed by voice. Paused projects: " + string.Join(", ", labels) + ". " +
            "If the user asks to RESUME / continue / wake / pick up one of these PAUSED projects, " +
            "reply with JSON {\"resume\":true,\"target\":\"<exact paused project name from the list>\"," +
            "\"instruction\":\"<what they want that project to do next, or empty string>\"}. The target " +
            "MUST be one of the paused project names. If the utterance is just a normal reply to the " +
            "CURRENT session and not about resuming a paused project, reply " +
            "{\"resume\":false,\"target\":\"\",\"instruction\":\"\"}. Output ONLY the JSON object.";
        try
        {
            var payload = new
            {
                model = "llama-3.3-70b-versatile",
                temperature = 0,
                max_tokens = 160,
                response_format = new { type = "json_object" },
                messages = new object[]
                {
                    new { role = "system", content = sys },
                    new { role = "user", content = text },
                },
            };
            using var req = new HttpRequestMessage(HttpMethod.Post,
                "https://api.groq.com/openai/v1/chat/completions");
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", config.GroqKey);
            req.Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json");
            using var resp = await Http.SendAsync(req);
            if (!resp.IsSuccessStatusCode) return null;
            using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync());
            var content = doc.RootElement.GetProperty("choices")[0]
                .GetProperty("message").GetProperty("content").GetString() ?? "";
            using var inner = JsonDocument.Parse(content);
            var root = inner.RootElement;
            return new ControlResult(
                root.TryGetProperty("resume", out var r) && r.ValueKind == JsonValueKind.True,
                root.TryGetProperty("target", out var t) ? t.GetString() ?? "" : "",
                root.TryGetProperty("instruction", out var i) ? i.GetString() ?? "" : "");
        }
        catch { return null; }
    }
}
