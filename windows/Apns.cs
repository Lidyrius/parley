using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Parley;

// Ringing the iPhone (docs/IPHONE.md, v2): a VoIP push through APNs wakes the phone's app,
// which shows a CallKit incoming call. 1:1 with the macOS host. Credentials in credentials.json:
// apnsKeyId, apnsTeamId (384887N3UL), apnsKeyP8 (the .p8 PEM text) — chosen via the tray's
// "Push-Schlüssel wählen…".

// The APNs provider token, pure: an ES256 JWT {alg,kid}.{iss,iat} signed with the .p8 key.
public static class ApnsJwt
{
    // AuthKey_<KEYID>.p8 → KEYID (Apple names the downloaded key file like this); else null.
    public static string? KeyIdFromFileName(string fileName)
    {
        var m = Regex.Match(fileName, @"^AuthKey_([A-Za-z0-9]+)\.p8$", RegexOptions.IgnoreCase);
        return m.Success ? m.Groups[1].Value : null;
    }

    // The DER bytes of a PEM "PRIVATE KEY" (PKCS#8): header/footer lines and whitespace dropped
    // (also a key pasted with literal "\n").
    public static byte[] PemBody(string pem)
    {
        var body = new StringBuilder();
        foreach (var raw in pem.Replace("\\n", "\n").Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith("-----", StringComparison.Ordinal)) continue;
            body.Append(line);
        }
        return Convert.FromBase64String(body.ToString());
    }

    // issuedAt = epoch seconds. Throws when the key isn't a usable P-256 PKCS#8 key.
    public static string Build(string keyId, string teamId, string p8, long issuedAt)
    {
        var header = RelayLink.Base64Url(JsonSerializer.SerializeToUtf8Bytes(new { alg = "ES256", kid = keyId }));
        var claims = RelayLink.Base64Url(JsonSerializer.SerializeToUtf8Bytes(new { iss = teamId, iat = issuedAt }));
        var input = header + "." + claims;
        using var key = ECDsa.Create();
        key.ImportPkcs8PrivateKey(PemBody(p8), out _);
        // JWS ES256 wants r‖s (IEEE P1363), not the DER sequence.
        var signature = key.SignData(Encoding.ASCII.GetBytes(input), HashAlgorithmName.SHA256,
            DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
        return input + "." + RelayLink.Base64Url(signature);
    }
}

// The push itself: HTTP/2 POST /3/device/<token> to api.push.apple.com (api.sandbox… for a
// development build), topic de.developaway.parley.mobile.voip, push type voip, payload {"label"}.
public static class Apns
{
    public const string DefaultTeamId = "384887N3UL";
    public const string Topic = "de.developaway.parley.mobile.voip";

    // APNs rejects a provider token older than 1 h and throttles refreshing it more often than
    // every 20 min → one token is reused for 50 min.
    private static readonly TimeSpan TokenLife = TimeSpan.FromMinutes(50);

    // APNs speaks HTTP/2 only.
    private static readonly HttpClient Http = new(new SocketsHttpHandler { PooledConnectionIdleTimeout = TimeSpan.FromMinutes(10) })
    {
        DefaultRequestVersion = HttpVersion.Version20,
        DefaultVersionPolicy = HttpVersionPolicy.RequestVersionExact,
        Timeout = TimeSpan.FromSeconds(15),
    };

    private static readonly object Gate = new();
    private static (string Key, string Jwt, DateTime At)? _token;

    public static string Host(string env) => env == "development" ? "api.sandbox.push.apple.com" : "api.push.apple.com";

    // A VoIP token is hex (32 bytes today); it ends up in the request path, so nothing else passes.
    public static bool ValidToken(string token) => token.Length is >= 32 and <= 200 && token.All(Uri.IsHexDigit);

    // A new key was chosen (or APNs called the token expired) → sign a fresh one next time.
    public static void ResetToken()
    {
        lock (Gate) _token = null;
    }

    private static string ProviderToken(string keyId, string teamId, string p8)
    {
        var cacheKey = keyId + "/" + teamId;
        lock (Gate)
        {
            if (_token is { } t && t.Key == cacheKey && DateTime.UtcNow - t.At < TokenLife) return t.Jwt;
            var jwt = ApnsJwt.Build(keyId, teamId, p8, DateTimeOffset.UtcNow.ToUnixTimeSeconds());
            _token = (cacheKey, jwt, DateTime.UtcNow);
            return jwt;
        }
    }

    // A visible notification (Unterwegs + Stumm): "Parley · Tippfrei" + the spoken line; tapping
    // it opens that session on the phone. Grouped per session.
    public const string AlertTopic = "de.developaway.parley.mobile";

    public static async Task<bool> SendAlert(string title, string body, string session)
    {
        var (token, env) = PhoneCall.Alert;
        if (token.Length == 0)
        {
            Log.Write("apns: no notification token from the phone yet — open the app once with Stumm on");
            return false;
        }
        var payload = new Dictionary<string, object>
        {
            ["aps"] = new Dictionary<string, object>
            {
                ["alert"] = new { title, body },
                ["sound"] = "default",
                ["thread-id"] = session,
            },
            ["session"] = session,
        };
        return await Send(token, env, AlertTopic, "alert", JsonSerializer.Serialize(payload), expiration: null);
    }

    // true = APNs accepted it (200). Every outcome is logged; nothing throws.
    public static async Task<bool> SendVoip(string label)
    {
        var (token, env) = PhoneCall.Push;
        if (token.Length == 0)
        {
            Log.Write("apns: no VoIP token from the phone yet");
            return false;
        }
        // Ring now or never: a call that arrives after the 45 s wait would ring for nothing.
        return await Send(token, env, Topic, "voip", JsonSerializer.Serialize(new { label }), expiration: "0");
    }

    // The Parley Live Activity (docs/LIVE-ACTIVITIES.md): push-to-start, update, end. `json` is the
    // whole payload (LiveActivity.Payload); priority 5 is not budgeted, 10 is. The status and
    // APNs' reason come back: 410 / BadDeviceToken = that activity or token is gone.
    public const string ActivityTopic = "de.developaway.parley.mobile.push-type.liveactivity";

    public static Task<(int Status, string Body)> SendActivity(string token, string env, string json, int priority) =>
        Post(token, env, ActivityTopic, "liveactivity", json, expiration: null, priority);

    private static async Task<bool> Send(string token, string env, string topic, string pushType, string json, string? expiration) =>
        (await Post(token, env, topic, pushType, json, expiration, 10)).Status is >= 200 and < 300;

    // Every outcome is logged; nothing throws. Status -1 = not sent.
    private static async Task<(int Status, string Body)> Post(string token, string env, string topic, string pushType, string json,
                                                               string? expiration, int priority)
    {
        var c = Config.Load();
        if (c.ApnsKeyId.Length == 0 || c.ApnsKeyP8.Length == 0)
        {
            Log.Write("apns: no push key — choose one via the tray (Push-Schlüssel wählen…)");
            return (-1, "");
        }
        string jwt;
        try { jwt = ProviderToken(c.ApnsKeyId, c.ApnsTeamId, c.ApnsKeyP8); }
        catch (Exception e)
        {
            Log.Write($"apns: push key unusable ({e.Message})");
            return (-1, "");
        }
        using var req = new HttpRequestMessage(HttpMethod.Post, $"https://{Host(env)}/3/device/{token}")
        {
            // Per request too: DefaultRequestVersion only applies to HttpClient's own helpers.
            Version = HttpVersion.Version20,
            VersionPolicy = HttpVersionPolicy.RequestVersionExact,
            Content = new StringContent(json, Encoding.UTF8, "application/json"),
        };
        req.Headers.Authorization = new AuthenticationHeaderValue("bearer", jwt);
        req.Headers.TryAddWithoutValidation("apns-topic", topic);
        req.Headers.TryAddWithoutValidation("apns-push-type", pushType);
        req.Headers.TryAddWithoutValidation("apns-priority", priority.ToString(System.Globalization.CultureInfo.InvariantCulture));
        if (expiration is not null) req.Headers.TryAddWithoutValidation("apns-expiration", expiration);
        try
        {
            using var resp = await Http.SendAsync(req);
            var body = await resp.Content.ReadAsStringAsync();
            var id = resp.Headers.TryGetValues("apns-id", out var ids) ? ids.FirstOrDefault() : null;
            Log.Write($"apns: {pushType} HTTP {(int)resp.StatusCode} ({env}) apns-id={id ?? "-"} {body}".TrimEnd());
            if (resp.StatusCode == HttpStatusCode.Forbidden && body.Contains("ExpiredProviderToken")) ResetToken();
            return ((int)resp.StatusCode, body);
        }
        catch (Exception e)
        {
            Log.Write($"apns: send failed ({e.Message})");
            return (-1, "");
        }
    }
}
