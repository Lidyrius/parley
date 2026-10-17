using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Parley;

// Where a spoken request goes (docs/IPHONE.md, v2), 1:1 with the macOS host: "Hey Parley" →
// a running session by its name, else the Zentrale — a permanent Claude Code session that finds
// and creates projects and hands work to sessions through POST /dispatch. A session that isn't
// running yet is started in a terminal; its instruction waits, by folder, for its first presence.

// Folder paths as the hooks, the mod and the Zentrale's bash send them, pure.
public static class CwdPath
{
    // One spelling per folder: Windows separators, no trailing one, ".." resolved, "~" expanded,
    // and Git Bash's /c/Users/… as C:\Users\… (the Zentrale's curl sends $HOME-style paths).
    public static string Normalize(string? path)
    {
        var p = (path ?? "").Trim();
        if (p.Length == 0) return "";
        if (p == "~" || p.StartsWith("~/", StringComparison.Ordinal) || p.StartsWith("~\\", StringComparison.Ordinal))
            p = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + p[1..];
        var msys = Regex.Match(p, @"^/([A-Za-z])(/.*)?$");
        if (msys.Success)
            p = msys.Groups[1].Value.ToUpperInvariant() + ":" + (msys.Groups[2].Success ? msys.Groups[2].Value : "\\");
        p = p.Replace('/', '\\');
        try
        {
            if (Path.IsPathFullyQualified(p)) p = Path.GetFullPath(p);
        }
        catch (Exception) { /* odd characters: compare it as written */ }
        return p.Length > 3 ? p.TrimEnd('\\') : p;   // keep a drive root as "C:\"
    }

    // Windows paths compare case-insensitively.
    public static bool Same(string? a, string? b)
    {
        var x = Normalize(a);
        return x.Length > 0 && string.Equals(x, Normalize(b), StringComparison.OrdinalIgnoreCase);
    }

    // A /dispatch cwd: absolute as is; a bare name/relative path lives under projectsDir. null =
    // empty or rooted-but-not-absolute ("\foo").
    public static string? Resolve(string? cwd, string projectsDir)
    {
        var p = Normalize(cwd);
        if (p.Length == 0) return null;
        if (!Path.IsPathFullyQualified(p))
        {
            if (Path.IsPathRooted(p)) return null;
            p = Normalize(Path.Combine(Normalize(projectsDir), p));
        }
        return Path.IsPathFullyQualified(p) ? p : null;
    }
}

// Instructions for a folder where no session runs yet, handed over on the first /presence from
// that folder (the mod submits it as a prompt). They expire after 10 min — a session that never
// came up must not get a stale task hours later.
public sealed class PendingByCwd
{
    public static readonly TimeSpan Ttl = TimeSpan.FromMinutes(10);

    private readonly object _gate = new();
    private readonly List<(string Dir, string Instruction, DateTime At)> _items = new();
    private readonly Func<DateTime> _now;

    public PendingByCwd(Func<DateTime>? now = null) => _now = now ?? (() => DateTime.UtcNow);

    public void Add(string cwd, string instruction)
    {
        var dir = CwdPath.Normalize(cwd);
        if (dir.Length == 0 || instruction.Length == 0) return;
        lock (_gate)
        {
            Prune();
            _items.Add((dir, instruction, _now()));
        }
    }

    // The oldest live instruction for the folder, removed — one per presence, in order.
    public string? Take(string? cwd)
    {
        lock (_gate)
        {
            if (_items.Count == 0) return null;   // the common case: every presence asks
            Prune();
            var dir = CwdPath.Normalize(cwd);
            if (dir.Length == 0) return null;
            var i = _items.FindIndex(x => string.Equals(x.Dir, dir, StringComparison.OrdinalIgnoreCase));
            if (i < 0) return null;
            var found = _items[i].Instruction;
            _items.RemoveAt(i);
            return found;
        }
    }

    public int Count
    {
        get { lock (_gate) { Prune(); return _items.Count; } }
    }

    private void Prune()
    {
        var t = _now();
        _items.RemoveAll(x => t - x.At >= Ttl);
    }
}

// Target = a session label (as listed) or Routing.ZentraleName; Instruction = what it gets.
public readonly record struct RouteResult(string Target, string Instruction);

// Routing a wake utterance, pure: the Groq prompt, its answer parsed, and the label fallback.
public static class Routing
{
    public const string ZentraleName = "Zentrale";

    public static string SystemPrompt(IReadOnlyList<string> labels) =>
        "You route a spoken request in a voice coding assistant. It comes from speech recognition, " +
        "so names may be misspelled or split (\"tipp frei\" = \"Tippfrei\"). Running sessions, by " +
        "spoken name: " + string.Join(", ", labels) + ". If the request is addressed to one of these " +
        "sessions by name or clearly means one of them, reply {\"target\":\"<that name exactly as " +
        "listed>\",\"instruction\":\"<the request for that session without the addressing, in the " +
        "speaker's words and language>\"}. Otherwise (general questions, finding or creating " +
        "projects, starting something new, anything not clearly for one running session) reply " +
        "{\"target\":\"" + ZentraleName + "\",\"instruction\":\"\"}. Output ONLY the JSON object.";

    // The LLM's JSON → a listed label (its exact spelling) or the Zentrale; null when it names
    // anything else or isn't JSON (the fallback decides then). The Zentrale always gets the whole
    // utterance — it may need the name to pass the task on itself.
    public static RouteResult? Parse(string json, IReadOnlyList<string> labels, string utterance)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("target", out var t) || t.ValueKind != JsonValueKind.String) return null;
            var target = (t.GetString() ?? "").Trim();
            if (string.Equals(target, ZentraleName, StringComparison.OrdinalIgnoreCase))
                return new RouteResult(ZentraleName, utterance);
            var label = labels.FirstOrDefault(l => string.Equals(l.Trim(), target, StringComparison.OrdinalIgnoreCase));
            if (label is null) return null;
            var instruction = root.TryGetProperty("instruction", out var i) && i.ValueKind == JsonValueKind.String
                ? (i.GetString() ?? "").Trim() : "";
            return new RouteResult(label, instruction.Length > 0 ? instruction : utterance);
        }
        catch (JsonException) { return null; }
    }

    // Without the LLM: the longest label the utterance contains — letters and digits only, so
    // "tipp frei" still finds "Tippfrei" — else the Zentrale. The whole utterance goes along.
    public static RouteResult Fallback(string utterance, IReadOnlyList<string> labels)
    {
        var said = Squash(utterance);
        var hit = labels
            .Where(l => Squash(l).Length >= 2 && said.Contains(Squash(l), StringComparison.Ordinal))
            .OrderByDescending(l => Squash(l).Length)
            .FirstOrDefault();
        return new RouteResult(hit ?? ZentraleName, utterance);
    }

    public static string Squash(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (var c in s.ToLowerInvariant())
            if (char.IsLetterOrDigit(c)) sb.Append(c);
        return sb.ToString();
    }
}

// The Zentrale's folder: zentraleDir (default %USERPROFILE%\workspace\privat\parley-zentrale),
// made from the repo's zentrale\ template.
public static class Zentrale
{
    public const string FirstPrompt = "/parley:voice";

    // Spoken when a wake request lands in the Zentrale.
    public static readonly string[] TakeOver =
    {
        "Ich kümmere mich darum, Sir.",
        "Ich nehme mich der Sache an, Sir.",
        "Alles klar, Sir. Ich habe gleich Infos für Sie.",
    };

    public static string Dir(Config c) => CwdPath.Normalize(c.ZentraleDir);

    // A session is the Zentrale by its spoken name or by working in its folder.
    public static bool Is(string label, string cwd, string dir) =>
        string.Equals(label.Trim(), Routing.ZentraleName, StringComparison.OrdinalIgnoreCase) || CwdPath.Same(cwd, dir);

    // Creates the folder when needed: the template's files (CLAUDE.md, .parley.json) from the
    // checkout (sourceDir) — only missing ones, so local edits survive; the template's own
    // README stays behind. Without a checkout just {"name":"Zentrale"}. Throws on I/O errors.
    public static string Ensure(Config c)
    {
        var dir = Dir(c);
        Directory.CreateDirectory(dir);
        var template = Path.Combine(c.ResolvedSourceDir, "zentrale");
        if (Directory.Exists(template))
        {
            foreach (var file in Directory.EnumerateFiles(template, "*", SearchOption.AllDirectories))
            {
                var rel = Path.GetRelativePath(template, file);
                if (string.Equals(rel, "README.md", StringComparison.OrdinalIgnoreCase)) continue;
                var dest = Path.Combine(dir, rel);
                if (File.Exists(dest)) continue;
                Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                File.Copy(file, dest);
            }
        }
        var name = Path.Combine(dir, ".parley.json");
        if (!File.Exists(name)) File.WriteAllText(name, "{ \"name\": \"" + Routing.ZentraleName + "\" }\n");
        return dir;
    }
}

// Starts a visible, interactive Claude Code CLI session in a folder with Parley's voice mode as
// its first prompt: Windows Terminal (`wt -d <dir> claude /parley:voice`), else a cmd window.
// (The desktop deep link claude://code/new only pre-fills the prompt — it can't start one
// unattended.) Arguments go through ArgumentList, never concatenated; an instruction never goes
// on a command line at all — it waits pending-by-cwd.
public static class SessionStarter
{
    // `resume`: a past session (checked by Transcript.IsSessionId) continued with its history.
    public static string[] ClaudeArgs(string? resume) =>
        resume is null ? new[] { "claude", Zentrale.FirstPrompt } : new[] { "claude", "--resume", resume, Zentrale.FirstPrompt };

    public static bool Start(string dir, string? resume = null)
    {
        try
        {
            var wt = new ProcessStartInfo("wt.exe") { UseShellExecute = false };
            // Through cmd /k: an npm install is claude.cmd, which Windows Terminal cannot start directly.
            foreach (var a in new[] { "-d", dir, "cmd", "/k" }.Concat(ClaudeArgs(resume))) wt.ArgumentList.Add(a);
            Process.Start(wt)?.Dispose();
            Log.Write($"session: starting one in {dir} (Windows Terminal)");
            return true;
        }
        catch (Exception e) { Log.Write($"session: Windows Terminal unavailable ({e.Message}) → cmd"); }
        try
        {
            // cmd /c start "" /D <dir> cmd /k claude /parley:voice — `start` opens the new window;
            // the empty argument is its window title.
            var cmd = new ProcessStartInfo("cmd.exe") { UseShellExecute = false, CreateNoWindow = true };
            foreach (var a in new[] { "/c", "start", "", "/D", dir, "cmd", "/k" }.Concat(ClaudeArgs(resume))) cmd.ArgumentList.Add(a);
            Process.Start(cmd)?.Dispose();
            Log.Write($"session: starting one in {dir} (cmd)");
            return true;
        }
        catch (Exception e)
        {
            Log.Write($"session: could not start one in {dir} ({e.Message})");
            return false;
        }
    }
}

public enum DispatchResult { Delivered, Started, Pending, Failed }

// Hands instructions to sessions: wake routing, POST /dispatch, and the pending-by-cwd queue
// the /presence handler drains. Delivery to a live session is the resume path (parked → /wake,
// else pending on its next /presence).
public sealed class Delivery
{
    // A started session that never reported is started again after this (the terminal may have
    // failed or been closed before Claude Code came up).
    private static readonly TimeSpan RestartAfter = TimeSpan.FromMinutes(2);

    private readonly SessionRegistry _sessions;
    private readonly Action<string, string> _deliver;   // (session id, instruction)
    private readonly Func<string, string?, bool> _start; // folder, resume id → started
    private readonly PendingByCwd _pending = new();
    private readonly Dictionary<string, DateTime> _started = new(StringComparer.OrdinalIgnoreCase);

    public Delivery(SessionRegistry sessions, Action<string, string> deliver, Func<string, string?, bool>? start = null)
    {
        _sessions = sessions;
        _deliver = deliver;
        _start = start ?? ((dir, resume) => SessionStarter.Start(dir, resume));
    }

    // /presence: an instruction waiting for this folder, or null.
    public string? TakePending(string? cwd) => _pending.Take(cwd);

    // POST /dispatch: a live session in `cwd` gets the instruction now; else it waits for the
    // folder's first presence and (start) a session is started there — once per 2 min.
    // `resume`: that past session is the one to reach — started with --resume unless it runs.
    // ponytail: the instruction still waits by folder; another idle session in the same folder
    // could take it first. Key it by session id if that ever bites.
    public DispatchResult Dispatch(string cwd, string instruction, bool start, string? resume = null)
    {
        var dir = CwdPath.Normalize(cwd);
        var (alive, deliverable) = resume is null ? (false, false) : _sessions.Running(resume);
        var id = resume is null ? _sessions.DeliverableIn(dir) : deliverable ? resume : null;
        if (id is not null)
        {
            if (instruction.Length > 0) _deliver(id, instruction);
            Log.Write($"dispatch: {dir} → its running session");
            return DispatchResult.Delivered;
        }
        _pending.Add(dir, instruction);
        if (alive) start = false;   // it runs, just can't take it yet: its next turn does
        if (!start)
        {
            Log.Write($"dispatch: {dir} → pending (no session started)");
            return DispatchResult.Pending;
        }
        lock (_started)
        {
            if (_started.TryGetValue(dir, out var at) && DateTime.UtcNow - at < RestartAfter)
            {
                Log.Write($"dispatch: {dir} → pending (a session is already starting)");
                return DispatchResult.Started;
            }
            _started[dir] = DateTime.UtcNow;
        }
        if (_start(dir, resume))
        {
            if (resume is not null) Log.Write($"dispatch: {dir} → session {resume} resumed");
            return DispatchResult.Started;
        }
        lock (_started) _started.Remove(dir);
        return DispatchResult.Failed;
    }

    // A wake utterance → a running session by name (Groq LLM, label substring fallback) or the
    // Zentrale. Returns the short line Parley confirms with.
    public async Task<string> Route(string utterance, Config config)
    {
        var zentrale = Zentrale.Dir(config);
        var all = _sessions.RouteTargets();
        var targets = all.Where(t => t.Label.Trim().Length > 0 && !Zentrale.Is(t.Label, t.Cwd, zentrale)).ToList();
        var labels = targets.Select(t => t.Label).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        var choice = (labels.Count > 0 ? await Groq.Route(utterance, labels, config) : null)
            ?? Routing.Fallback(utterance, labels);
        var target = targets.FirstOrDefault(t => string.Equals(t.Label, choice.Target, StringComparison.OrdinalIgnoreCase));
        if (target is not null)
        {
            _deliver(target.Id, choice.Instruction);
            Log.Write($"route: → {target.Label}");
            return $"Verstanden, ich gebe das an {target.Label} weiter.";
        }

        // The Zentrale: alive (by name or folder) → straight to it; else start it there.
        DispatchResult result;
        var live = all.FirstOrDefault(t => Zentrale.Is(t.Label, t.Cwd, zentrale));
        if (live is not null)
        {
            _deliver(live.Id, choice.Instruction);
            result = DispatchResult.Delivered;
        }
        else
        {
            try { result = Dispatch(Zentrale.Ensure(config), choice.Instruction, start: true); }
            catch (Exception e)
            {
                Log.Write($"zentrale: could not prepare {zentrale} ({e.Message})");
                result = DispatchResult.Failed;
            }
        }
        Log.Write($"route: → Zentrale ({result.ToString().ToLowerInvariant()})");
        // The Zentrale is Parley itself — it takes the job on, it doesn't pass it on.
        return result == DispatchResult.Failed
            ? "Das konnte ich leider nicht anstoßen, Sir."
            : Zentrale.TakeOver[Random.Shared.Next(Zentrale.TakeOver.Length)];
    }
}
