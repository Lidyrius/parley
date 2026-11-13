using System.Diagnostics;

namespace Parley;

// Sessions on a host without windows: each start is a detached tmux session `parley-<folder>`
// in its folder — `tmux attach -t parley-<folder>` shows it. The Linux counterpart of
// SessionStarter / SessionCloser (windows/Zentrale.cs) and of the macOS start check's Terminal
// tab (StartWatch.swift): tmux can be read (capture-pane) and typed into (send-keys).
public static class Tmux
{
    public const string Prefix = "parley-";

    // What a session runs: `claude`, or PARLEY_CLAUDE_CMD — a wrapper, extra flags
    // ("claude --permission-mode acceptEdits"), or a stand-in while Claude Code isn't logged in.
    public static string ClaudeCommand =>
        Environment.GetEnvironmentVariable("PARLEY_CLAUDE_CMD") is { Length: > 0 } c ? c : "claude";

    // folder → the tmux session of its newest start (the start check reads and answers that one)
    private static readonly Dictionary<string, string> Starts = new();

    // tmux <args>: exit status and stdout (stderr on failure). Arguments as argv, nothing spliced.
    public static (int Status, string Output) Run(params string[] args)
    {
        var psi = new ProcessStartInfo("tmux") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var a in args) psi.ArgumentList.Add(a);
        try
        {
            using var p = Process.Start(psi)!;
            var err = p.StandardError.ReadToEndAsync();
            var output = p.StandardOutput.ReadToEnd();
            if (!p.WaitForExit(10_000)) { try { p.Kill(); } catch { } return (-1, "tmux did not answer"); }
            return (p.ExitCode, p.ExitCode == 0 ? output : err.Result.Trim());
        }
        catch (Exception e) { return (-1, e.Message); }
    }

    // As SessionStarter.Start: Parley's voice mode as the first prompt, `resume` a past session.
    public static bool Start(string dir, string? resume = null)
    {
        ClaudeTrust.Accept(dir);   // no "trust this folder?" in Parley's starts (Sir's rule)
        var name = FreeName(dir);
        // Through a login shell: ~/.profile applies, so `claude` is found where its installer put
        // it (~/.local/bin) whatever environment the tmux server was started with. One string, so
        // PARLEY_CLAUDE_CMD may carry flags; the arguments Parley adds are quoted.
        // Remote Control only on plain `claude` — a PARLEY_CLAUDE_CMD wrapper or stand-in may not take it.
        var remote = RemoteControl.On && ClaudeCommand == "claude";
        var command = ClaudeCommand + string.Concat(SessionStarter.ClaudeArgs(resume, remote).Skip(1).Select(a => " " + Quote(a)));
        var (status, output) = Run("new-session", "-d", "-s", name, "-x", "200", "-y", "50", "-c", dir, "bash", "-lc", command);
        if (status != 0)
        {
            Log.Write($"session: could not start one in {dir} (tmux: {output})");
            return false;
        }
        lock (Starts) Starts[CwdPath.Normalize(dir)] = name;
        Log.Write($"session: starting one in {dir} (tmux session {name}: {command})");
        return true;
    }

    // parley-<folder name>, with -2, -3 … beside a session of that name (a second one in the folder).
    private static string FreeName(string dir)
    {
        var slug = new string(Path.GetFileName(dir.TrimEnd('/')).ToLowerInvariant()
            .Select(c => char.IsAsciiLetterOrDigit(c) ? c : '-').ToArray()).Trim('-');
        var first = Prefix + (slug.Length > 0 ? slug : "session");
        var name = first;
        for (var n = 2; n < 100 && Run("has-session", "-t", "=" + name).Status == 0; n++)
            name = $"{first}-{n}";
        return name;
    }

    private static string Quote(string s) => "'" + s.Replace("'", "'\\''") + "'";

    // ---- the start check (Delivery.StartScreen / StartAnswer) ---------------------------

    // The screen's last non-empty lines of the start in `dir`; null = its tmux session is gone.
    public static string? Screen(string dir)
    {
        string? name;
        lock (Starts) Starts.TryGetValue(CwdPath.Normalize(dir), out name);
        if (name is null) return null;
        var (status, output) = Run("capture-pane", "-p", "-t", "=" + name + ":");
        if (status != 0) return null;
        return string.Join("\n", output.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0).TakeLast(8));
    }

    // Types `text` and Enter into the start in `dir`; false = its tmux session is gone.
    public static bool Answer(string dir, string text)
    {
        string? name;
        lock (Starts) Starts.TryGetValue(CwdPath.Normalize(dir), out name);
        if (name is null) return false;
        var target = "=" + name + ":";
        return Run("send-keys", "-t", target, "-l", "--", text).Status == 0 && Run("send-keys", "-t", target, "Enter").Status == 0;
    }

    // ---- Remote Control's catch-up (RemoteControl.CatchUp) -------------------------------

    // A session that registered without Remote Control, idle: `/remote-control` + Enter into its
    // pane (found by the claude process's tty), Enter on the dialog only with "Enable Remote
    // Control" chosen, else Escape. Once; blocking (RemoteControl.Seen runs it off the server).
    public static void RemoteControlOn(string id, string label, int pid)
    {
        string tty;
        try { tty = new FileInfo($"/proc/{pid}/fd/0").LinkTarget ?? ""; } catch (Exception) { tty = ""; }
        var pane = tty.Length == 0 ? null : Run("list-panes", "-a", "-F", "#{pane_tty}\t#{pane_id}").Output.Split('\n')
            .Select(l => l.Split('\t', 2)).FirstOrDefault(f => f.Length == 2 && f[0] == tty)?[1];
        if (pane is null)
        {
            Log.Write($"remote control: {label} (claude {pid}) runs outside tmux — not turned on");
            return;
        }
        Run("send-keys", "-t", pane, "-l", "--", "/remote-control");
        Thread.Sleep(300);
        Run("send-keys", "-t", pane, "Enter");
        Thread.Sleep(1500);
        if (RemoteControl.Of(id)?.Connected == true)   // no dialog: Claude Code connected at once
        {
            Log.Write($"remote control: {label} — /remote-control typed into {pane}, connected");
            return;
        }
        var screen = Run("capture-pane", "-p", "-t", pane).Output;
        if (RemoteControl.EnableSelected(screen))
        {
            Run("send-keys", "-t", pane, "Enter");
            Log.Write($"remote control: {label} — /remote-control typed into {pane}, enabling");
        }
        else
        {
            Run("send-keys", "-t", pane, "Escape");
            var tail = string.Join(" | ", screen.Split('\n').Select(l => l.Trim()).Where(l => l.Trim('─', ' ').Length > 0).TakeLast(4));
            Log.Write($"remote control: {label} — no \"Enable Remote Control\" on screen, Escape ({tail})");
        }
        Thread.Sleep(15_000);
        Log.Write($"remote control: {label} — {(RemoteControl.Of(id)?.Connected == true ? "connected" : "not connected after 15 s — given up")}");
    }

    // ---- closing (Server.Closer) --------------------------------------------------------

    // POST /close for session `id` working in `cwd`: null = closing, else why not. The one tmux
    // session Parley started in that folder; with none or several there, the claude process
    // ~/.claude/sessions/<pid>.json names for the id (as SessionCloser on Windows) — with its tmux
    // session when that is one of Parley's, else only its own process tree.
    public static string? Close(string id, string? cwd)
    {
        var mine = Run("list-sessions", "-F", "#{session_name}\t#{session_path}").Output.Split('\n')
            .Select(l => l.Split('\t', 2))
            .Where(f => f.Length == 2 && f[0].StartsWith(Prefix, StringComparison.Ordinal) && CwdPath.Same(f[1], cwd))
            .Select(f => f[0]).ToList();
        if (mine.Count == 1) return Kill(mine[0]);

        var procs = Processes();
        var p = SessionCloser.Pick(id, procs.Where(IsClaude).ToList(), SessionCloser.Claimed());
        if (p is null) return "no running claude process found for that session";
        // Up its parents to the tmux pane it runs in.
        var panes = Run("list-panes", "-a", "-F", "#{pane_pid}\t#{session_name}").Output.Split('\n')
            .Select(l => l.Split('\t', 2)).Where(f => f.Length == 2 && int.TryParse(f[0], out _))
            .ToDictionary(f => int.Parse(f[0]), f => f[1]);
        var parents = procs.ToDictionary(x => x.Pid, x => x.Parent);
        for (int pid = p.Pid, hops = 0; pid > 1 && hops < 16; hops++)
        {
            if (panes.TryGetValue(pid, out var session) && session.StartsWith(Prefix, StringComparison.Ordinal)) return Kill(session);
            if (!parents.TryGetValue(pid, out pid)) break;
        }
        try
        {
            using var claude = Process.GetProcessById(p.Pid);
            claude.Kill(entireProcessTree: true);
            Log.Write($"close: ended claude {p.Pid}");
            return null;
        }
        catch (Exception e) { return "could not end it: " + e.Message; }
    }

    private static string? Kill(string session)
    {
        var (status, output) = Run("kill-session", "-t", "=" + session);
        if (status != 0) return "could not end it: " + output;
        Log.Write($"close: ended tmux session {session}");
        return null;
    }

    // claude itself by argv[0] (native), or node running claude-code — as SessionCloser.Argv0.
    private static bool IsClaude(SessionCloser.Proc p)
    {
        var argv0 = Path.GetFileName(p.Args.Split(' ', 2)[0]);
        return argv0 == "claude" || (argv0 == "node" && p.Args.Contains("claude-code/cli.js"));
    }

    // Every process with its parent and command line, from /proc.
    private static List<SessionCloser.Proc> Processes()
    {
        var list = new List<SessionCloser.Proc>();
        foreach (var dir in Directory.EnumerateDirectories("/proc"))
        {
            if (!int.TryParse(Path.GetFileName(dir), out var pid)) continue;
            try
            {
                var args = File.ReadAllText(Path.Combine(dir, "cmdline")).TrimEnd('\0').Replace('\0', ' ');
                // /proc/<pid>/stat: "pid (comm) state ppid …" — comm may hold spaces and brackets.
                var stat = File.ReadAllText(Path.Combine(dir, "stat"));
                var fields = stat[(stat.LastIndexOf(')') + 2)..].Split(' ');
                if (args.Length > 0 && fields.Length > 1 && int.TryParse(fields[1], out var parent)) list.Add(new SessionCloser.Proc(pid, parent, args));
            }
            catch (Exception) { /* gone meanwhile, or not ours to read */ }
        }
        return list;
    }
}
