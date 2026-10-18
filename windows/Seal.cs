using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Parley;

// End-to-end encryption between the host and the phones (docs/IPHONE.md → v5), 1:1 with the
// macOS Seal.swift: AES-256-GCM under the pairing key, which only travels in the QR code — the
// relay can neither read nor forge a frame. Sealed bytes: nonce ‖ ciphertext ‖ tag; plaintext:
// sender clock (8 bytes BE, epoch ms) ‖ payload. Text frames keep their `t` readable outside.
public sealed class RelaySeal
{
    public static readonly TimeSpan Window = TimeSpan.FromSeconds(120);
    private readonly byte[] _key;

    private RelaySeal(byte[] key) => _key = key;

    // The pairing key (32 bytes, base64url); null when it isn't one.
    public static RelaySeal? Create(string key)
    {
        var bytes = FromBase64Url(key);
        return bytes is { Length: 32 } ? new RelaySeal(bytes) : null;
    }

    // `{"t":"<t>","e":"<sealed>"}`; null for a frame without a string `t`.
    public string? Text(string json, long nowMs)
    {
        if (TypeOf(json) is not { } t) return null;
        var sealedBytes = Seal(Encoding.UTF8.GetBytes(json), "parley1/text/" + t, nowMs);
        return new JsonObject { ["t"] = t, ["e"] = Convert.ToBase64String(sealedBytes) }.ToJsonString();
    }

    public byte[] Binary(byte[] data, long nowMs) => Seal(data, "parley1/bin", nowMs);

    // A sealed text frame → its JSON, sender clock and nonce; null unless it opens and matches its `t`.
    public (string Json, long SentMs, byte[] Nonce)? OpenText(string wire)
    {
        try
        {
            using var doc = JsonDocument.Parse(wire);
            var r = doc.RootElement;
            if (r.ValueKind != JsonValueKind.Object || !r.TryGetProperty("t", out var tv) || tv.ValueKind != JsonValueKind.String
                || !r.TryGetProperty("e", out var ev) || ev.ValueKind != JsonValueKind.String) return null;
            var t = tv.GetString()!;
            if (Open(Convert.FromBase64String(ev.GetString()!), "parley1/text/" + t) is not { } o) return null;
            var json = Encoding.UTF8.GetString(o.Payload);
            return TypeOf(json) == t ? (json, o.SentMs, o.Nonce) : null;
        }
        catch (Exception) { return null; }
    }

    public (byte[] Data, long SentMs, byte[] Nonce)? OpenBinary(byte[] sealedBytes) =>
        Open(sealedBytes, "parley1/bin") is { } o ? (o.Payload, o.SentMs, o.Nonce) : null;

    private byte[] Seal(byte[] payload, string aad, long nowMs)
    {
        var plain = new byte[8 + payload.Length];
        BinaryPrimitives.WriteInt64BigEndian(plain, nowMs);
        payload.CopyTo(plain, 8);
        var output = new byte[12 + plain.Length + 16];
        var nonce = output.AsSpan(0, 12);
        RandomNumberGenerator.Fill(nonce);
        using var gcm = new AesGcm(_key, 16);
        gcm.Encrypt(nonce, plain, output.AsSpan(12, plain.Length), output.AsSpan(12 + plain.Length, 16), Encoding.UTF8.GetBytes(aad));
        return output;
    }

    private (byte[] Payload, long SentMs, byte[] Nonce)? Open(byte[] sealedBytes, string aad)
    {
        if (sealedBytes.Length < 12 + 8 + 16) return null;
        var n = sealedBytes.Length - 28;
        var plain = new byte[n];
        try
        {
            using var gcm = new AesGcm(_key, 16);
            gcm.Decrypt(sealedBytes.AsSpan(0, 12), sealedBytes.AsSpan(12, n), sealedBytes.AsSpan(12 + n, 16), plain, Encoding.UTF8.GetBytes(aad));
        }
        catch (CryptographicException) { return null; }
        return (plain[8..], BinaryPrimitives.ReadInt64BigEndian(plain), sealedBytes[..12]);
    }

    private static string? TypeOf(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            return doc.RootElement.ValueKind == JsonValueKind.Object && doc.RootElement.TryGetProperty("t", out var t)
                && t.ValueKind == JsonValueKind.String ? t.GetString() : null;
        }
        catch (JsonException) { return null; }
    }

    public static byte[]? FromBase64Url(string s)
    {
        var b = s.Replace('-', '+').Replace('_', '/');
        b += new string('=', (4 - b.Length % 4) % 4);
        try { return Convert.FromBase64String(b); }
        catch (FormatException) { return null; }
    }
}

// The host's replay check on what the phones send: a frame's clock within the window of its own,
// and a nonce not seen in that window. Used from the receive task only.
public sealed class ReplayGuard
{
    private readonly Dictionary<string, long> _seen = new();
    private long _pruned;

    public bool Accept(long sentMs, byte[] nonce, long nowMs)
    {
        var window = (long)RelaySeal.Window.TotalMilliseconds;
        if (Math.Abs(nowMs - sentMs) > window) return false;
        if (nowMs - _pruned > 10_000)   // ~50 audio frames a second: prune now and then
        {
            foreach (var k in _seen.Where(p => nowMs - p.Value > window).Select(p => p.Key).ToList()) _seen.Remove(k);
            _pruned = nowMs;
        }
        return _seen.TryAdd(Convert.ToBase64String(nonce), nowMs);
    }
}
