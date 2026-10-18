using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Parley;

// Wiedervorlage (as macOS: app/Sources/Parley/Reminders.swift): something Sir says now, handed
// over later. The Zentrale turns his words into POST /remind (GET /remind lists, POST
// /remind/cancel removes):
//
// - for a session, at a time     {"to":"Shirts","text":"Lass die Tests laufen","at":"2026-10-19T09:00:00+02:00"}
//                                ("in": minutes instead of "at")
// - for a session, once another is done   {"to":"Zentrale","text":"Deploye","after":"Shirts"}
// - for Sir himself              {"text":"das Telefonat mit Max","in":30}   (no "to", or "to":"sir")
//
// Kept in reminders.json (survives restarts and updates), checked every 30 s.
public sealed class Reminder
{
    public string Id { get; set; } = "";
    public string Text { get; set; } = "";
    public string Label { get; set; } = "Sir";   // who gets it: a session's spoken name, or "Sir"
    public string? Session { get; set; }         // its id (null: Sir, or a folder without a known session)
    public string? Cwd { get; set; }             // its folder: to resume / start it when it doesn't run
    public DateTime? At { get; set; }            // due then (UTC) …
    public string? After { get; set; }           // … or once this session stopped working
    public string? AfterLabel { get; set; }
    public DateTime Created { get; set; }

    [JsonIgnore] public bool ForSir => Session is null && Cwd is null;
}

public sealed class ReminderStore
{
    public const double MaxDays = 60;
    private static readonly HashSet<string> Busy = new() { "working", "background" };
    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };

    private readonly string? _file;
    private readonly List<Reminder> _list;

    public ReminderStore(string? file)
    {
        _file = file;
        try { _list = file is not null && File.Exists(file) ? JsonSerializer.Deserialize<List<Reminder>>(File.ReadAllText(file), Json) ?? new() : new(); }
        catch { _list = new(); }
    }

    /// A session by name or id → its id (if known), spoken name and folder.
    public delegate (string? Id, string Label, string Cwd)? Resolve(string name);

    /// The POST body → a reminder (kept), or what is wrong.
    public (Reminder? Reminder, string? Error) Add(string body, DateTime now, Resolve resolve)
    {
        string? text = null, to = null, cwd = null, at = null, after = null;
        double? minutes = null;
        try
        {
            using var doc = JsonDocument.Parse(body.Length == 0 ? "{}" : body);
            var r = doc.RootElement;
            if (r.ValueKind != JsonValueKind.Object) return (null, "body must be a JSON object");
            string? S(string k) => r.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
            (text, to, cwd, at, after) = (S("text"), S("to"), S("cwd"), S("at"), S("after"));
            if (r.TryGetProperty("in", out var m) && m.ValueKind == JsonValueKind.Number) minutes = m.GetDouble();
        }
        catch (JsonException) { return (null, "body must be a JSON object"); }

        text = (text ?? "").Trim();
        if (text.Length == 0) return (null, "text is missing");
        if (new[] { at is not null, minutes is not null, after is not null }.Count(b => b) != 1)
            return (null, "give exactly one of at, in, after");
        var rem = new Reminder
        {
            Id = "r" + Guid.NewGuid().ToString("N")[..8],
            Text = text.Length > 2000 ? text[..2000] : text,
            Created = now,
        };
        if (at is not null)
        {
            if (!DateTimeOffset.TryParse(at, CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) || !HasZone(at))
                return (null, "at must be ISO 8601 with a zone, e.g. 2026-10-19T09:00:00+02:00");
            rem.At = d.UtcDateTime;
        }
        else if (minutes is { } mins)
        {
            if (mins < 0) return (null, "in must be minutes from now");
            rem.At = now.AddMinutes(mins);
        }
        if (rem.At is { } due)
        {
            if (due <= now.AddSeconds(-60)) return (null, "at is in the past");
            if (due >= now.AddDays(MaxDays)) return (null, $"at is more than {MaxDays} days away");
        }
        if (after is not null)
        {
            if (resolve(after) is not { Id: { } sid } s) return (null, $"no session \"{after}\" to wait for");
            rem.After = sid;
            rem.AfterLabel = s.Label;
        }

        to = (to ?? "").Trim();
        if (!string.IsNullOrWhiteSpace(cwd))
        {
            cwd = cwd.Trim();
            if (!Path.IsPathRooted(cwd)) return (null, "cwd must be an absolute folder");
            rem.Cwd = CwdPath.Normalize(cwd);
            rem.Label = to.Length > 0 ? to : Path.GetFileName(rem.Cwd.TrimEnd('/', '\\'));
        }
        else if (to.Length > 0 && !to.Equals("sir", StringComparison.OrdinalIgnoreCase))
        {
            if (resolve(to) is not { } s) return (null, $"no session \"{to}\"");
            rem.Session = s.Id;
            rem.Label = s.Label;
            rem.Cwd = s.Cwd.Length > 0 ? s.Cwd : null;
        }
        if (rem.ForSir && rem.After is not null) return (null, "after needs a session in to");
        lock (_list) { _list.Add(rem); Save(); }
        return (rem, null);
    }

    private static bool HasZone(string s) => s.EndsWith("Z", StringComparison.OrdinalIgnoreCase)
        || System.Text.RegularExpressions.Regex.IsMatch(s, @"[+-]\d{2}:?\d{2}$");

    /// Due now: its time has come, or the session it waits for is done — it stopped working
    /// after the reminder was made, or is gone. `state(id)`: a listed session's state and since.
    public static bool IsDue(Reminder r, DateTime now, Func<string, (string State, DateTime Since)?> state)
    {
        if (r.At is { } at) return at <= now;
        if (r.After is null) return true;
        if (state(r.After) is not { } s) return true;
        return s.State == "stopped" || (!Busy.Contains(s.State) && s.Since > r.Created);
    }

    /// Takes the matching reminders out (once).
    public List<Reminder> Take(Func<Reminder, bool> due)
    {
        lock (_list)
        {
            var fire = _list.Where(due).ToList();
            if (fire.Count == 0) return fire;
            _list.RemoveAll(fire.Contains);
            Save();
            return fire;
        }
    }

    public List<Reminder> Cancel(IReadOnlyCollection<string> ids) => Take(r => ids.Contains(r.Id));

    /// What the session gets.
    public static string Instruction(Reminder r)
    {
        var de = new CultureInfo("de-DE");
        var when = r.Created.ToLocalTime().ToString("dddd HH:mm", de);
        var why = r.AfterLabel is { } a ? $" — {a} ist fertig" : "";
        return $"Wiedervorlage von Sir (gesprochen {when}{why}): {r.Text}";
    }

    /// What Sir hears.
    public static string Spoken(Reminder r) => $"Erinnerung, Sir: {r.Text}";

    /// GET /remind and the `reminders` in /sessions (the phone lists them): soonest first,
    /// waiting ones last; times in epoch ms.
    public List<object> Rows() { lock (_list) return Rows(_list); }

    public static List<object> Rows(IEnumerable<Reminder> list) => list
        .OrderBy(r => r.At ?? DateTime.MaxValue).ThenBy(r => r.Created)
        .Select(r => (object)new
        {
            id = r.Id,
            text = r.Text,
            to = r.Label,
            at = r.At is { } at ? (long?)Math.Round((at - DateTime.UnixEpoch).TotalMilliseconds) : null,
            after = r.AfterLabel,
        })
        .ToList();

    private void Save()
    {
        if (_file is null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_file)!);
            var tmp = _file + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(_list, Json));
            File.Move(tmp, _file, overwrite: true);
        }
        catch (Exception e) { Log.Write($"remind: not saved ({e.Message})"); }
    }
}
