using System.Text.Json;
using System.Text.RegularExpressions;

// A colour palette for the iPhone app, made by voice — as macOS (app/Sources/Parley/
// PaletteSpec.swift): the Zentrale researches it and POSTs it; the phone gets it as a `palette`
// frame, saves it under "Eigene" and switches to it.
//
// POST /palette {"name","note"?,"alwaysDark"?,"colors":{role: "#RRGGBB" | ["#light","#dark"]}}
public static class PaletteSpec
{
    public static readonly string[] Roles =
        { "background", "card", "raised", "accent", "waiting", "working", "purple", "idle", "stopped", "red" };

    private static readonly Regex Hex6 = new("^#?[0-9A-Fa-f]{6}$");

    // The body → (name, the phone's frame), or the reason it is refused.
    public static (string? Name, string? Frame, string? Error) Parse(string body)
    {
        JsonElement root;
        try
        {
            using var doc = JsonDocument.Parse(body.Length == 0 ? "{}" : body);
            root = doc.RootElement.Clone();
        }
        catch (JsonException) { return (null, null, "body must be a JSON object"); }
        if (root.ValueKind != JsonValueKind.Object) return (null, null, "body must be a JSON object");
        var name = root.TryGetProperty("name", out var n) && n.ValueKind == JsonValueKind.String ? n.GetString()!.Trim() : "";
        if (name.Length == 0) return (null, null, "name is missing");
        var given = root.TryGetProperty("colors", out var c) && c.ValueKind == JsonValueKind.Object ? c : default;
        var colors = new SortedDictionary<string, string[]>(StringComparer.Ordinal);
        var missing = new List<string>();
        var invalid = new List<string>();
        foreach (var role in Roles)
        {
            if (given.ValueKind != JsonValueKind.Object || !given.TryGetProperty(role, out var v)) { missing.Add(role); continue; }
            string[]? pair = v.ValueKind switch
            {
                JsonValueKind.String => new[] { v.GetString()!, v.GetString()! },
                JsonValueKind.Array when v.GetArrayLength() is 1 or 2 && v.EnumerateArray().All(e => e.ValueKind == JsonValueKind.String)
                    => v.GetArrayLength() == 1 ? new[] { v[0].GetString()!, v[0].GetString()! } : new[] { v[0].GetString()!, v[1].GetString()! },
                _ => null,
            };
            if (pair is null || !pair.All(h => Hex6.IsMatch(h.Trim()))) { invalid.Add(role); continue; }
            colors[role] = pair.Select(h => "#" + h.Trim().TrimStart('#').ToUpperInvariant()).ToArray();
        }
        if (missing.Count > 0 || invalid.Count > 0)
        {
            var parts = new List<string>();
            if (missing.Count > 0) parts.Add("missing: " + string.Join(", ", missing));
            if (invalid.Count > 0) parts.Add("not #RRGGBB or [light, dark]: " + string.Join(", ", invalid));
            return (null, null, string.Join("; ", parts));
        }
        if (name.Length > 40) name = name[..40];
        var note = root.TryGetProperty("note", out var nt) && nt.ValueKind == JsonValueKind.String ? nt.GetString()!.Trim() : "";
        if (note.Length > 120) note = note[..120];
        var alwaysDark = root.TryGetProperty("alwaysDark", out var ad) && ad.ValueKind == JsonValueKind.True;
        var frame = JsonSerializer.Serialize(new SortedDictionary<string, object>(StringComparer.Ordinal)
        {
            ["alwaysDark"] = alwaysDark, ["colors"] = colors, ["name"] = name, ["note"] = note, ["t"] = "palette",
        });
        return (name, frame, null);
    }
}
