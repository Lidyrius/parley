using System.Text.Json;
using System.Text.RegularExpressions;

namespace Parley;

// Permission prompts aloud (docs/IPHONE.md, v2), pure, 1:1 with the macOS host: the question
// "<Projekt> möchte <kurze Beschreibung> — erlauben?" from the hook's tool_name + tool_input, and
// the spoken reply → allow / deny / ask by German keyword rules.
public static class Permission
{
    public const string Allow = "allow", Deny = "deny", Ask = "ask";

    public static string Question(string project, string tool, JsonElement? input) =>
        $"{project} möchte {Describe(tool, input)} — erlauben?";

    // A few words to hear, not the raw call: no paths, no full commands.
    public static string Describe(string tool, JsonElement? input)
    {
        var o = input ?? default;   // default(JsonElement).ValueKind is Undefined → no fields
        string S(string key) =>
            o.ValueKind == JsonValueKind.Object && o.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String
                ? (v.GetString() ?? "").Trim() : "";

        var name = tool.Trim();
        switch (name)
        {
            case "Bash":
            case "PowerShell":
            {
                var what = S("description");
                if (what.Length > 0) return $"einen Befehl ausführen: {Clip(what)}";
                var head = S("command").Split((char[]?)null, 2, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
                return head.Length > 0 ? $"den Befehl {Clip(head)} ausführen" : "einen Befehl ausführen";
            }
            case "Write": return OnFile(S("file_path"), "schreiben");
            case "Edit":
            case "MultiEdit": return OnFile(S("file_path"), "bearbeiten");
            case "NotebookEdit": return OnFile(S("notebook_path"), "bearbeiten");
            case "Read": return OnFile(S("file_path"), "lesen");
            case "WebFetch":
                return Uri.TryCreate(S("url"), UriKind.Absolute, out var url) && url.Host.Length > 0
                    ? $"die Seite {url.Host} abrufen" : "eine Webseite abrufen";
            case "WebSearch":
            {
                var q = S("query");
                return q.Length > 0 ? $"im Web nach {Clip(q)} suchen" : "im Web suchen";
            }
            case "Glob":
            case "Grep": return "Dateien durchsuchen";
            case "Task":
            case "Agent": return "einen Subagenten starten";
        }
        // mcp__<server>__<tool>
        var parts = name.Split("__");
        if (parts.Length >= 3 && parts[0] == "mcp") return $"{Words(parts[2])} über {Words(parts[1])} ausführen";
        return name.Length > 0 ? $"{Words(name)} benutzen" : "ein Werkzeug benutzen";
    }

    private static string OnFile(string path, string verb)
    {
        var file = Path.GetFileName(path.Replace('/', '\\').TrimEnd('\\'));
        return file.Length > 0 ? $"die Datei {file} {verb}" : $"eine Datei {verb}";
    }

    private static string Words(string s) => s.Replace('_', ' ').Replace('-', ' ').Trim();

    // At most ~80 characters, cut at a word.
    private static string Clip(string s)
    {
        s = Regex.Replace(s, @"\s+", " ").Trim();
        if (s.Length <= 80) return s;
        var cut = s.LastIndexOf(' ', 80);
        return (cut > 40 ? s[..cut] : s[..80]) + "…";
    }

    // ---- the spoken answer -------------------------------------------------------------

    private static readonly HashSet<string> YesWords = new()
    {
        "ja", "jawohl", "jo", "jep", "yes", "okay", "ok", "klar", "gerne", "gern", "los", "passt",
        "sicher", "einverstanden", "genau", "freigeben", "go",
    };
    private static readonly string[] YesStems = { "erlaub", "mach", "genehmig", "zustimm", "bestätig", "akzeptier" };
    // "warum nicht" also hits "nicht" → both → ask; better than reading it as a "no".
    private static readonly string[] YesPhrases = { " jeden fall ", " gib frei ", " leg los ", " warum nicht " };

    private static readonly HashSet<string> NoWords = new()
    {
        "nein", "nee", "nö", "noe", "no", "nicht", "stopp", "stop", "abbruch", "niemals", "keinesfalls",
    };
    private static readonly string[] NoStems = { "stopp", "verbiet", "verbot", "ablehn", "abbrech", "verweiger", "untersag" };
    private static readonly string[] NoPhrases = { " keinen fall ", " lieber nicht " };

    // Hesitation ("weiß nicht", "warte mal") is neither — it must not read as the "nicht" of a no.
    private static readonly HashSet<string> UnclearWords = new() { "warte", "moment", "momentchen" };
    private static readonly string[] UnclearPhrases = { " weiß nicht ", " weiss nicht ", " keine ahnung " };

    // Only yes-words → allow; only no-words → deny; both ("ja, aber nicht…"), neither, hesitation
    // or silence → ask: the on-screen prompt decides — an unclear answer never becomes "allow".
    public static string Decide(string transcript)
    {
        var words = Regex.Split(transcript.ToLowerInvariant(), @"[^\p{L}\p{N}]+").Where(w => w.Length > 0).ToList();
        if (words.Count == 0) return Ask;
        var text = " " + string.Join(" ", words) + " ";
        if (words.Any(w => UnclearWords.Contains(w)) || UnclearPhrases.Any(p => text.Contains(p, StringComparison.Ordinal))) return Ask;
        var yes = words.Any(w => YesWords.Contains(w) || YesStems.Any(s => w.StartsWith(s, StringComparison.Ordinal)))
                  || YesPhrases.Any(p => text.Contains(p, StringComparison.Ordinal));
        var no = words.Any(w => NoWords.Contains(w) || NoStems.Any(s => w.StartsWith(s, StringComparison.Ordinal)))
                 || NoPhrases.Any(p => text.Contains(p, StringComparison.Ordinal));
        return yes == no ? Ask : yes ? Allow : Deny;
    }
}
