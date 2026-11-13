using System.Text.Json;

namespace Parley;

// Remote Control (Claude Code's /remote-control: the session is reachable from the Claude app and
// claude.ai/code) for every session Parley starts or that registers with it — as macOS
// RemoteControl.swift. Parley's own starts carry `--remote-control` (SessionStarter.ClaudeArgs).
// A session that registers without it gets `/remote-control` typed in once while it is idle —
// only where Parley can type into its terminal (`CatchUp`: the Linux host's tmux). Windows can't
// type into another console: there it stays a log line. `remoteControl` "0" in credentials.json:
// neither. Claude Code's own `remoteControlAtStartup` setting does it for every session.
public static class RemoteControl
{
    public const string Flag = "--remote-control";
    public static bool On => Config.Load().RemoteControl;

    // ~/.claude/sessions/<pid>.json — `bridgeSessionId` is there iff Remote Control is connected.
    public sealed record State(int Pid, string SessionId, string Status, bool Connected);

    public static State? Parse(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var r = doc.RootElement;
            string S(string k) => r.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
            if (!r.TryGetProperty("pid", out var pid) || !pid.TryGetInt32(out var n) || S("sessionId") is not { Length: > 0 } id) return null;
            return new State(n, id, S("status"), S("bridgeSessionId").Length > 0);
        }
        catch (Exception) { return null; }
    }

    public static State? Of(string sessionId, string? dir = null)
    {
        dir ??= Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "sessions");
        if (!Directory.Exists(dir)) return null;
        foreach (var f in Directory.EnumerateFiles(dir, "*.json"))
        {
            string json;
            try { json = File.ReadAllText(f); } catch (Exception) { continue; }
            if (Parse(json) is { } s && s.SessionId == sessionId) return s;
        }
        return null;
    }

    public enum Step { Later, Done, Type }

    // Type now only when Claude Code says idle and Parley holds nothing for it (`parley`: its
    // registry state — "parked" = finished, no voice dialog, no turn at the gate).
    public static Step Decide(State? s, string? parley) =>
        s is null ? Step.Later : s.Connected ? Step.Done : s.Status == "idle" && parley == "parked" ? Step.Type : Step.Later;

    // The dialog `/remote-control` opens, its first option chosen: "❯ 1. Enable Remote Control".
    public static bool EnableSelected(string screen) =>
        screen.Split('\n').TakeLast(15).Any(l => l.Contains('❯') && l.Contains("Enable Remote Control"));

    // (session id, label, pid): the one try, blocking, off the server's threads. null = can't type.
    public static Action<string, string, int>? CatchUp;

    private static readonly HashSet<string> Tried = new();

    // A session sent presence or polled /wake (Server.cs).
    public static void Seen(string id, Func<(string Label, string State)?> info)
    {
        lock (Tried) if (id.Length == 0 || Tried.Contains(id)) return;
        if (!On) return;
        var parley = info();
        var state = Of(id);
        var step = Decide(state, parley?.State);
        if (step == Step.Later) return;
        lock (Tried) if (!Tried.Add(id)) return;
        if (step == Step.Done) return;
        var label = parley?.Label is { Length: > 0 } l ? l : id;
        if (CatchUp is not { } catchUp)
        {
            Log.Write($"Remote Control: nur bei Starts durch Parley — {label} läuft ohne");
            return;
        }
        _ = Task.Run(() =>
        {
            try { catchUp(id, label, state!.Pid); }
            catch (Exception e) { Log.Write($"remote control: {label} — {e.Message}"); }
        });
    }
}
