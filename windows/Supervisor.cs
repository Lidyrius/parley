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
/// through restarts) without ringing again. What he hears when he calls back is ready before he
/// does (Missed.Ready): the one line that waits, or — once there are more — the one summary the
/// Zentrale is asked for as each joins. It plays the moment his call connects; the Zentrale
/// then learns what he heard and what he said. As macOS (Supervisor.swift, Missed).
public sealed class MissedLine
{
    [JsonPropertyName("at")] public double At { get; set; }          // epoch ms
    [JsonPropertyName("text")] public string Text { get; set; } = "";
    [JsonPropertyName("asks")] public bool Asks { get; set; }        // a <speak>: it wanted an answer
    // The Zentrale's summary of the lines before it (not a line he missed).
    [JsonPropertyName("sum"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public bool? Sum { get; set; }
}

public static class Missed
{
    public static string FilePath => Path.Combine(Config.Dir, "missed.json");
    public const int Most = 40;                                             // the newest; older ones are long overtaken
    public static readonly TimeSpan NoticeEvery = TimeSpan.FromMinutes(15);   // a notification with the count at most this often
    public static readonly TimeSpan SummaryWithin = TimeSpan.FromMinutes(3);  // the Zentrale's next line is the summary asked for, this long

    /// The lines he missed (without a summary made of them).
    public static List<MissedLine> Lines(IEnumerable<MissedLine> list) => list.Where(l => l.Sum != true).ToList();

    /// What he hears first when he calls back, if it is ready: the one line that waits, or the
    /// summary of all of them. null: more than one waits and the newest is not in a summary yet.
    public static MissedLine? Ready(IReadOnlyList<MissedLine> list) =>
        list.Count == 1 ? list[0] : list.Count > 1 && list[list.Count - 1].Sum == true ? list[list.Count - 1] : null;

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
        "[Parley] Sir hat den Anruf nicht angenommen. Deine Zeile ist für seinen Rückruf vorgemerkt: " +
        "Ruft er zurück, hört er sie sofort, und du erfährst, was er geantwortet hat. Alles Weitere, " +
        "was du ihm sagst, wird ebenfalls gesammelt, ohne erneut zu klingeln; dann bitte ich dich um " +
        "EINE Zusammenfassung, die er stattdessen hört. Arbeite normal weiter (Berichte annehmen, " +
        "delegieren, was nur Sir entscheiden kann, offen halten). Antworte hierauf nur mit " +
        "<speak-end></speak-end>.";

    private static string Clock(double at) =>
        DateTime.UnixEpoch.AddMilliseconds(at).ToLocalTime().ToString("HH:mm", System.Globalization.CultureInfo.InvariantCulture);

    // The lines he missed: what is open first, then the rest, each oldest first.
    private static List<string> Listing(List<MissedLine> list)
    {
        var open = list.Where(l => l.Asks).ToList();
        var rest = list.Where(l => !l.Asks).ToList();
        static string Rows(List<MissedLine> l) => string.Join("\n", l.Select(x => $"- ({Clock(x.At)} Uhr) {x.Text}"));
        var parts = new List<string>();
        if (open.Count > 0) parts.Add("Offen — Fragen an ihn, älteste zuerst:\n" + Rows(open));
        if (rest.Count > 0) parts.Add("Zur Kenntnis, älteste zuerst:\n" + Rows(rest));
        return parts;
    }

    private const string How = "zuerst, was offen ist oder seine Entscheidung braucht, dann kurz das Erledigte. Was sich inzwischen überholt oder erledigt hat, lass weg oder sag es in einem Halbsatz.";

    /// Sir is back and nothing was ready for him (or he says something right now — `said`, "Hey
    /// Parley, …"): everything he missed as one instruction, for a summary made now.
    public static string Instruction(IReadOnlyList<MissedLine> all, string? said = null)
    {
        var list = Lines(all);
        var since = list.Count > 0 ? Clock(list[0].At) : "?";
        var which = list.Count == 1 ? "diese Zeile" : $"diese {list.Count} Zeilen";
        var parts = new List<string> { $"[Parley] Sir ruft zurück. Seit dem nicht angenommenen Anruf ({since} Uhr) hat er {which} von dir nicht gehört." };
        parts.AddRange(Listing(list));
        parts.Add($"Gib ihm jetzt EINE gesprochene Zusammenfassung: {How} Danach geht es normal weiter.");
        if (said?.Trim() is { Length: > 0 } now) parts.Add($"Außerdem sagt Sir gerade: „{now}“");
        return string.Join("\n\n", parts);
    }

    /// More than one line waits: what the Zentrale reads in place of an answer to the newest —
    /// its next line is the summary he hears the moment he calls back.
    public static string SummaryRequest(IReadOnlyList<MissedLine> all)
    {
        var list = Lines(all);
        var parts = new List<string> { $"[Parley] Sir hat noch nicht zurückgerufen; auch diese Zeile ist vorgemerkt. Es warten jetzt {list.Count} Zeilen von dir auf ihn." };
        parts.AddRange(Listing(list));
        parts.Add($"Schreib jetzt die EINE gesprochene Zusammenfassung, die er beim Rückruf sofort hört, ohne Wartezeit: {How} Antworte nur mit ihr — als <speak>, wenn etwas offen ist, sonst als <speak-end>. Es klingelt dabei nicht; danach arbeitest du normal weiter.");
        return string.Join("\n\n", parts);
    }

    /// He called back and heard `line` at once (of `all` that waited): what the Zentrale reads now.
    public static string Heard(MissedLine line, IReadOnlyList<MissedLine> all, string answer)
    {
        var list = Lines(all);
        var parts = new List<string> { $"[Parley] Sir hat zurückgerufen und sofort gehört: „{line.Text}“" };
        if (line.Sum == true) parts.Add($"Das war deine Zusammenfassung dieser {list.Count} Zeilen:\n" + string.Join("\n\n", Listing(list)));
        var said = answer.Trim();
        parts.Add(said.Length == 0
            ? "Er hat darauf nichts gesagt. Liegt nichts Neues an, antworte nur mit <speak-end></speak-end>."
            : $"Seine Antwort: „{said}“");
        return string.Join("\n\n", parts);
    }

    /// The Live Activity's line and the notification: how many wait.
    public static string Waiting(int n) =>
        n == 1 ? "1 Update wartet auf deinen Rückruf" : $"{n} Updates warten auf deinen Rückruf";
}
