using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Parley;

// Groq Whisper transcription + intent classification — same models and prompts as macOS.
public static class Groq
{
    // ~0.2 s with reasoning off. Groq retires models without notice — a 4xx shows up in the
    // log as "groq classify http 400". Same model as macOS.
    private const string Model = "qwen/qwen3.8-27b";

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
            var text = body.Trim();
            var clean = CleanTranscript(text);
            if (clean.Length == 0 && text.Length > 0) Log.Write($"stt: dropped Whisper hallucination \"{text}\"");
            return clean;
        }
        catch (Exception e)
        {
            Log.Write($"stt error: {e.Message}");
            Notifier.Notify("Parley — Fehler", "Groq nicht erreichbar (Netzwerk/VPN?).");
            return "";
        }
    }

    // Whisper invents these on silence / background noise (YouTube-subtitle training data).
    // Compared after lowercasing and collapsing punctuation + whitespace — same list as macOS.
    // ponytail: whole-transcript exact match; repeats ("Thank you. Thank you.") slip through.
    private static readonly HashSet<string> Hallucinations = new()
    {
        "you", "thank you", "thank you very much", "thanks for watching",
        "thank you for watching", "thanks for watching and see you next time", "please subscribe",
        "danke", "vielen dank", "danke fürs zuschauen", "vielen dank fürs zuschauen",
        "untertitel der amara org community", "untertitel im auftrag des zdf",
        "untertitelung im auftrag des zdf", "untertitel im auftrag des zdf für funk 2017",
        "untertitelung des zdf für funk 2017",
    };

    /// The transcript, or "" when it's only a known Whisper hallucination (or no words at all),
    /// so silence takes the normal "no reply" path instead of being injected as speech.
    public static string CleanTranscript(string text)
    {
        var norm = Regex.Replace(text.ToLowerInvariant(), @"[^\p{L}\p{N}]+", " ").Trim();
        return norm.Length == 0 || Hallucinations.Contains(norm) ? "" : text;
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
                model = Model,
                reasoning_effort = "none",
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

    // Which predicted answer (<reply>) the transcript is: the 1-based option number, 0 = none.
    private const string ReplySystem =
        "A developer answered a coding assistant by voice. The assistant predicted these kinds of " +
        "answer, numbered. Output ONLY the number of the one the answer clearly is, or 0 if none " +
        "fits well (e.g. it adds a new request or says something else). Output only the integer.";

    /// The matched option's index; null = none / no key / failed.
    public static async Task<int?> PickReply(string text, IReadOnlyList<string> options, Config config)
    {
        if (!config.SttReady || text.Length == 0 || options.Count == 0) return null;
        try
        {
            var list = string.Join("\n", options.Select((o, i) => $"{i + 1}. {o}"));
            var payload = new
            {
                model = Model,
                reasoning_effort = "none",
                temperature = 0,
                max_tokens = 4,
                messages = new object[]
                {
                    new { role = "system", content = ReplySystem },
                    new { role = "user", content = $"{list}\n\nAnswer: {text}" },
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
            return int.TryParse(new string(content.Where(char.IsDigit).ToArray()), out var n) && n >= 1 && n <= options.Count
                ? n - 1 : null;
        }
        catch { return null; }
    }

    public static async Task<Intent> Classify(string text, Config config)
    {
        if (!config.SttReady || text.Length == 0) return Intent.Other;
        try
        {
            var payload = new
            {
                model = Model,
                reasoning_effort = "none",
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
            if (!resp.IsSuccessStatusCode)
            {
                var err = await resp.Content.ReadAsStringAsync();
                Log.Write($"groq classify http {(int)resp.StatusCode}: {err[..Math.Min(160, err.Length)]}");
                return Intent.Other;
            }
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

    // "Hey Parley" routing (docs/IPHONE.md, v2): which running session the utterance is for
    // (labels), else the Zentrale. null = no key / failed / an answer naming something else —
    // the caller falls back to Routing.Fallback (label substring match).
    public static async Task<RouteResult?> Route(string text, IReadOnlyList<string> labels, Config config)
    {
        if (!config.SttReady || text.Length == 0 || labels.Count == 0) return null;
        try
        {
            var payload = new
            {
                model = Model,
                reasoning_effort = "none",
                temperature = 0,
                max_tokens = 300,
                response_format = new { type = "json_object" },
                messages = new object[]
                {
                    new { role = "system", content = Routing.SystemPrompt(labels) },
                    new { role = "user", content = text },
                },
            };
            using var req = new HttpRequestMessage(HttpMethod.Post,
                "https://api.groq.com/openai/v1/chat/completions");
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", config.GroqKey);
            req.Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json");
            // The caller is waiting on a call — fail over to the substring match quickly.
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            using var resp = await Http.SendAsync(req, cts.Token);
            if (!resp.IsSuccessStatusCode)
            {
                Log.Write($"route: groq http {(int)resp.StatusCode}");
                return null;
            }
            using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync());
            var content = doc.RootElement.GetProperty("choices")[0]
                .GetProperty("message").GetProperty("content").GetString() ?? "";
            return Routing.Parse(content, labels, text);
        }
        catch (Exception e)
        {
            Log.Write($"route: groq failed ({e.Message})");
            return null;
        }
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
                model = Model,
                reasoning_effort = "none",
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
