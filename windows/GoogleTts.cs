using System.Text;
using System.Text.Json;

namespace Parley;

// Google Cloud Text-to-Speech (Chirp3 HD) — identical request shape to the macOS app.
// Returns raw 16-bit LE mono PCM at 24 kHz (WAV header stripped).
public static class GoogleTts
{
    public const int SampleRate = 24000;
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };

    public static async Task<byte[]?> Synthesize(string text, Config config)
    {
        if (!config.UseGoogle) return null;
        var lang = string.Join("-", config.GoogleVoice.Split('-').Take(2));
        var payload = new
        {
            input = new { text },
            voice = new { languageCode = lang, name = config.GoogleVoice },
            audioConfig = new { audioEncoding = "LINEAR16", sampleRateHertz = SampleRate },
        };
        using var req = new HttpRequestMessage(HttpMethod.Post,
            "https://texttospeech.googleapis.com/v1/text:synthesize");
        req.Headers.Add("X-Goog-Api-Key", config.GoogleKey);
        req.Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json");
        try
        {
            using var resp = await Http.SendAsync(req);
            var body = await resp.Content.ReadAsStringAsync();
            if (!resp.IsSuccessStatusCode)
            {
                Log.Write($"google tts http {(int)resp.StatusCode}: {body[..Math.Min(200, body.Length)]}");
                return null;
            }
            using var doc = JsonDocument.Parse(body);
            if (!doc.RootElement.TryGetProperty("audioContent", out var b64)) return null;
            var audio = Convert.FromBase64String(b64.GetString() ?? "");
            // Strip the 44-byte WAV header if present.
            if (audio.Length > 44 && audio[0] == (byte)'R' && audio[1] == (byte)'I' &&
                audio[2] == (byte)'F' && audio[3] == (byte)'F')
                return audio[44..];
            return audio;
        }
        catch (Exception e)
        {
            Log.Write($"google tts error: {e.Message}");
            return null;
        }
    }
}
