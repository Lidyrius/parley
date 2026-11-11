using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Parley;

// Überwachungsmodus (as macOS: app/Sources/Parley/Supervisor.swift): only the Zentrale talks to
// Sir (PC, call, Live Activity). Every other session's turn is not voiced — it reaches the
// Zentrale as a report, and the session parks (resumable, taking the Zentrale's POST /dispatch).
// The Zentrale delegates, watches the sessions and alone gives Sir the updates.
//
// GET /supervisor → {"on","exempt","zentrale","waiting","missed"} · POST /supervisor {"on":bool,"exempt":[…]}
// Kept in supervisor.json (survives restarts and updates).
public sealed class Supervisor
{
    [JsonPropertyName("on")] public bool On { get; set; }
    // Sessions that keep talking to Sir themselves: an id or a spoken name.
    [JsonPropertyName("exempt")] public List<string> Exempt { get; set; } = new();

    public bool Exempts(string id, string label) =>
        Exempt.Any(x => x == id || string.Equals(x, label, StringComparison.OrdinalIgnoreCase));

    public static string FilePath => Path.Combine(Config.Dir, "supervisor.json");

    public static Supervisor Load(string? file)
    {
        try
        {
            if (file is null || !File.Exists(file)) return new Supervisor();
            var s = JsonSerializer.Deserialize<Supervisor>(File.ReadAllText(file)) ?? new Supervisor();
            s.Exempt ??= new List<string>();
            return s;
        }
        catch { return new Supervisor(); }
    }

    public void Save(string? file)
    {
        if (file is null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            var tmp = file + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(this));
            File.Move(tmp, file, overwrite: true);
        }
        catch (Exception e) { Log.Write($"supervisor: not saved ({e.Message})"); }
    }

    /// The session in the Zentrale's folder, or one that goes by its name.
    public static bool IsZentrale(string label, string? cwd, string zentrale) =>
        label == Routing.ZentraleName || CwdPath.Same(cwd, zentrale);

    public const int ContextMax = 1500;

    // What the Zentrale gets for a session's turn: its spoken line, whether Sir is asked
    // (<speak>) or it is done (<speak-end>), the answers it predicted, an excerpt of its last
    // message, and how to reach it.
    public static string Report(TurnPayload turn, string id, bool background)
    {
        var asks = turn.WantsListen;
        var state = asks ? "Frage an Sir" : background ? "arbeitet im Hintergrund weiter" : "fertig";
        var lines = new List<string> { $"[Bericht von {turn.SpokenLabel} · {state}] {turn.Speak}" };
        var options = (turn.Replies ?? new List<Reply>()).Select(r => r.On).Where(o => !string.IsNullOrEmpty(o)).ToList();
        if (asks && options.Count > 0) lines.Add("Erwartete Antworten: " + string.Join(" · ", options));
        var context = (turn.Context ?? "").Trim();
        if (context.Length > ContextMax)
        {
            context = context[^ContextMax..];
            if (char.IsLowSurrogate(context[0])) context = context[1..];   // never half a character
        }
        if (context.Length > 0) lines.Add("Kontext (Auszug aus ihrer letzten Nachricht):\n" + context);
        lines.Add(asks
            ? $"(<speak>: Frage oder Rückfrage — die Session wartet geparkt auf Antwort. Session {id}, Ordner {turn.Cwd}.)"
            : $"(<speak-end>: keine Antwort erwartet. Session {id}, Ordner {turn.Cwd}.)");
        return string.Join("\n", lines);
    }

    /// A dispatched instruction as its session reads it: who asks (`from`), and — while the mode
    /// is on — that its spoken line goes to the Zentrale, not to Sir.
    public static string Instruction(string text, string? from, bool reportsBack)
    {
        var who = Regex.Replace(from ?? "", @"[\n\u000B\f\r\u0085\u2028\u2029]", " ")
            .Replace("[", "").Replace("]", "").Trim();
        if (who.Length > 40) who = who[..40];
        if (who.Length == 0 || text.Length == 0) return text;
        var note = reportsBack
            ? $"\n\n(Überwachungsmodus: Deine <speak>- bzw. <speak-end>-Zeile wird nicht vorgelesen, sie geht als Bericht an {who}. Antworte so, dass {who} damit weiterarbeiten kann.)"
            : "";
        return $"[Auftrag von {who}] {text}{note}";
    }
}

/// A line of the Zentrale that Sir did not hear: he didn't take its call (Überwachungsmodus).
/// Nothing waits for him — the Zentrale goes on working, its lines are kept here (missed.json,
/// through restarts) without ringing again, and when he calls back the Zentrale gets them all
/// as one instruction and makes one spoken summary of them. As macOS (Supervisor.swift, Missed).
public sealed class MissedLine
{
    [JsonPropertyName("at")] public double At { get; set; }          // epoch ms
    [JsonPropertyName("text")] public string Text { get; set; } = "";
    [JsonPropertyName("asks")] public bool Asks { get; set; }        // a <speak>: it wanted an answer
}

public static class Missed
{
    public static string FilePath => Path.Combine(Config.Dir, "missed.json");
    public const int Most = 40;                                             // the newest; older ones are long overtaken
    public static readonly TimeSpan NoticeEvery = TimeSpan.FromMinutes(15);   // a notification with the count at most this often

    public static List<MissedLine> Load(string? file)
    {
        try
        {
            if (file is null || !File.Exists(file)) return new();
            return JsonSerializer.Deserialize<List<MissedLine>>(File.ReadAllText(file)) ?? new();
        }
        catch { return new(); }
    }

    public static void Save(List<MissedLine> list, string? file)
    {
        if (file is null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            var tmp = file + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(list));
            File.Move(tmp, file, overwrite: true);
        }
        catch (Exception e) { Log.Write($"missed: not saved ({e.Message})"); }
    }

    /// What the Zentrale reads in place of an answer to the line that rang unanswered.
    public const string Note =
        "[Parley] Sir hat den Anruf nicht angenommen. Deine Zeile ist für seinen Rückruf vorgemerkt; " +
        "alles Weitere, was du ihm sagst, wird ebenfalls gesammelt, ohne erneut zu klingeln. Arbeite " +
        "normal weiter (Berichte annehmen, delegieren, was nur Sir entscheiden kann, offen halten). " +
        "Antworte hierauf nur mit <speak-end></speak-end>.";

    private static string Clock(double at) =>
        DateTime.UnixEpoch.AddMilliseconds(at).ToLocalTime().ToString("HH:mm", System.Globalization.CultureInfo.InvariantCulture);

    /// Sir is back: everything he missed as one instruction — what is open first, then the rest,
    /// each oldest first. `said`: what he says right now ("Hey Parley, …").
    public static string Instruction(IReadOnlyList<MissedLine> list, string? said = null)
    {
        var open = list.Where(l => l.Asks).ToList();
        var rest = list.Where(l => !l.Asks).ToList();
        static string Lines(List<MissedLine> l) => string.Join("\n", l.Select(x => $"- ({Clock(x.At)} Uhr) {x.Text}"));
        var since = list.Count > 0 ? Clock(list[0].At) : "?";
        var which = list.Count == 1 ? "diese Zeile" : $"diese {list.Count} Zeilen";
        var parts = new List<string> { $"[Parley] Sir ruft zurück. Seit dem nicht angenommenen Anruf ({since} Uhr) hat er {which} von dir nicht gehört." };
        if (open.Count > 0) parts.Add("Offen — Fragen an ihn, älteste zuerst:\n" + Lines(open));
        if (rest.Count > 0) parts.Add("Zur Kenntnis, älteste zuerst:\n" + Lines(rest));
        parts.Add("Gib ihm jetzt EINE gesprochene Zusammenfassung: zuerst, was offen ist oder seine Entscheidung braucht, dann kurz das Erledigte. Was sich inzwischen überholt oder erledigt hat, lass weg oder sag es in einem Halbsatz. Danach geht es normal weiter.");
        if (said?.Trim() is { Length: > 0 } now) parts.Add($"Außerdem sagt Sir gerade: „{now}“");
        return string.Join("\n\n", parts);
    }

    /// The Live Activity's line and the notification: how many wait.
    public static string Waiting(int n) =>
        n == 1 ? "1 Update wartet auf deinen Rückruf" : $"{n} Updates warten auf deinen Rückruf";
}
