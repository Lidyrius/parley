using System.Text.Json;

namespace Parley;

// Protocol v11 (docs/IPHONE.md): the Detailgrad — how long a session's spoken line is. A default
// (`detail` in credentials.json) and per-session levels (detail.json beside reminders.json). The
// session learns it from a note at the end of what it is handed. 1:1 with the macOS host.
public static class Detail
{
    public static readonly string[] Levels = { "kurz", "mittel", "lang" };

    // What the menus show.
    public static string Label(string level) => level switch
    {
        "mittel" => "Mittel — ca. 40 Sek. · 3–5 Sätze",
        "lang" => "Ausführlich — ca. 80 Sek. · ganze Zusammenfassung",
        _ => "Kurz — ca. 15 Sek. · 1–2 Sätze",
    };

    public static string NoteFor(string level) => level switch
    {
        "mittel" => "[Parley · Detailgrad mittel: Sprechzeile bis etwa 90 Wörter (rund 40 Sekunden) – die wichtigsten Punkte mit kurzer Begründung.]",
        "lang" => "[Parley · Detailgrad ausführlich: Sprechzeile bis etwa 180 Wörter (rund 80 Sekunden) – vollständige Zusammenfassung mit Gründen, Zahlen und offenen Punkten.]",
        _ => "[Parley · Detailgrad kurz: Sprechzeile wieder höchstens etwa 40 Wörter.]",
    };

    public static string Valid(string? level) => level is "mittel" or "lang" ? level : "kurz";

    private static readonly object Gate = new();
    private static readonly Dictionary<string, string> Noted = new();   // session → level last noted
    private static Dictionary<string, string>? _own;
    public static string Path => System.IO.Path.Combine(Config.Dir, "detail.json");

    private static Dictionary<string, string> Own()
    {
        if (_own is not null) return _own;
        try { _own = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(Path)) ?? new(); }
        catch { _own = new(); }
        return _own;
    }

    // A session's own level, or null (it uses the default).
    public static string? OwnLevel(string id) { lock (Gate) return Own().TryGetValue(id, out var l) ? l : null; }

    public static string Effective(string id, Config c) => OwnLevel(id) ?? Valid(c.Detail);

    // Phone `{"t":"detail","id","level"}`: "" = back to the default.
    public static void SetOwn(string id, string level)
    {
        lock (Gate)
        {
            var own = Own();
            if (level.Length == 0) own.Remove(id); else own[id] = Valid(level);
            try
            {
                Directory.CreateDirectory(Config.Dir);
                File.WriteAllText(Path, JsonSerializer.Serialize(own));
                if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(Path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            }
            catch (Exception e) { Log.Write($"detail: not saved: {e.Message}"); }
        }
    }

    // A phone's `detail` / `resumeLine` frame (both hosts).
    public static void Apply(PhoneDetail d)
    {
        if (d.Id is null) Config.Merge(new Dictionary<string, string> { ["detail"] = Valid(d.Level) });
        else SetOwn(d.Id, d.Level);
        Log.Write($"phone: Detailgrad {(d.Id is null ? "Standard" : d.Id)} → {(d.Level.Length > 0 ? d.Level : "wie Standard")}");
    }

    public static void SetResumeLine(bool on)
    {
        Config.Merge(new Dictionary<string, string> { ["resumeLine"] = on ? "" : "0" });
        Log.Write($"Rückmeldung beim Fortsetzen {(on ? "an" : "aus")}");
    }

    // The note to append to what session `id` is handed now: its level unless that's kurz and was
    // never anything else; kurz once after it went back. Pure apart from the memory.
    public static string Note(string id, Config c)
    {
        var level = Effective(id, c);
        lock (Gate)
        {
            // never noted: it started at the default (the plugin's PARLEY_DETAIL told it so)
            var before = Noted.TryGetValue(id, out var b) ? b : Valid(c.Detail);
            Noted[id] = level;
            if (level == "kurz" && before == "kurz") return "";
        }
        return "\n\n" + NoteFor(level);
    }
}
