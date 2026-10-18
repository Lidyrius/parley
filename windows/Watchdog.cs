using System.Text.Json;

namespace Parley;

// The Wachhund — as macOS (app/Sources/Parley/Watchdog.swift): notices a session that works but
// gets nowhere, and asks Sir whether to step in. Every 30 s, for each working session, the tail of
// its Claude Code transcript:
//   circles — the same tool call 4 times among the last 8
//   failing — the last 6 tool calls all failed
//   silent  — working for 15 min, nothing written to the transcript for 10
// A yes hands the session a hint; Claude Code reads it at its next step, mid-turn.
public static class Watchdog
{
    public sealed record Call(string Key, string Label, bool Failed);
    public sealed record Finding(string Kind, int Times, string What);   // circles | failing | silent (Times = minutes)

    public const int Window = 8, Repeats = 4, Failures = 6;
    public static readonly TimeSpan WorkingFor = TimeSpan.FromMinutes(15), QuietFor = TimeSpan.FromMinutes(10);

    // The tool calls in transcript lines, oldest first, each with whether its result failed.
    // The turn is over: the transcript's last message is Claude's, ended normally (`end_turn`).
    // The session waits for Sir, whatever the registry still believes — a turn that spoke
    // nothing (an empty `<speak-end>`) never told Parley it ended. As macOS.
    public static bool TurnEnded(IReadOnlyList<string> lines)
    {
        for (var i = lines.Count - 1; i >= 0; i--)
        {
            try
            {
                using var doc = JsonDocument.Parse(lines[i]);
                var e = doc.RootElement;
                if (e.ValueKind != JsonValueKind.Object || !e.TryGetProperty("type", out var t)) continue;
                var type = t.GetString();
                if (type is not ("assistant" or "user")) continue;
                return type == "assistant" && e.TryGetProperty("message", out var m) && m.ValueKind == JsonValueKind.Object
                    && m.TryGetProperty("stop_reason", out var r) && r.ValueKind == JsonValueKind.String && r.GetString() == "end_turn";
            }
            catch (JsonException) { }
        }
        return false;
    }

    public static List<Call> Calls(IEnumerable<string> lines)
    {
        var order = new List<(string Id, string Key, string Label)>();
        var failed = new HashSet<string>();
        foreach (var line in lines)
        {
            try
            {
                using var doc = JsonDocument.Parse(line);
                if (!doc.RootElement.TryGetProperty("message", out var m) || m.ValueKind != JsonValueKind.Object
                    || !m.TryGetProperty("content", out var content) || content.ValueKind != JsonValueKind.Array) continue;
                foreach (var b in content.EnumerateArray())
                {
                    var type = b.TryGetProperty("type", out var t) ? t.GetString() : null;
                    if (type == "tool_use" && b.TryGetProperty("id", out var id) && b.TryGetProperty("name", out var name))
                    {
                        var input = b.TryGetProperty("input", out var i) ? i : default;
                        var raw = input.ValueKind == JsonValueKind.Undefined ? "" : input.GetRawText();
                        order.Add((id.GetString() ?? "", name.GetString() + "|" + raw,
                                   Transcript.Tool(name.GetString() ?? "", input.ValueKind == JsonValueKind.Object ? input : JsonDocument.Parse("{}").RootElement)));
                    }
                    else if (type == "tool_result" && b.TryGetProperty("is_error", out var err) && err.ValueKind == JsonValueKind.True
                             && b.TryGetProperty("tool_use_id", out var tid))
                        failed.Add(tid.GetString() ?? "");
                }
            }
            catch (JsonException) { }
        }
        return order.Select(o => new Call(o.Key, o.Label, failed.Contains(o.Id))).ToList();
    }

    // What is wrong with a session, if anything. Only working sessions are judged.
    public static Finding? Check(string state, DateTime since, DateTime? lastWrite, IReadOnlyList<Call> calls, DateTime now)
    {
        if (state != "working") return null;
        var recent = calls.Skip(Math.Max(0, calls.Count - Window)).ToList();
        var same = recent.GroupBy(c => c.Key).OrderByDescending(g => g.Count()).FirstOrDefault();
        if (same is not null && same.Count() >= Repeats) return new Finding("circles", same.Count(), same.First().Label);
        var last = calls.Skip(Math.Max(0, calls.Count - Failures)).ToList();
        if (last.Count == Failures && last.All(c => c.Failed)) return new Finding("failing", Failures, "");
        if (now - since >= WorkingFor && lastWrite is { } w && now - w >= QuietFor)
            return new Finding("silent", (int)(now - w).TotalMinutes, "");
        return null;
    }

    // Spoken (JARVIS): what is wrong, and the question.
    public static string Question(string label, Finding f) => f.Kind switch
    {
        "circles" => $"Wachhund, Sir: {label} dreht sich im Kreis — {f.Times}-mal dasselbe: {f.What.Replace(" · ", ", ")}. Soll ich eingreifen?",
        "failing" => $"Wachhund, Sir: Bei {label} schlägt gerade {f.Times}-mal hintereinander alles fehl. Soll ich eingreifen?",
        _ => $"Wachhund, Sir: {label} arbeitet, aber seit {f.Times} Minuten kommt nichts mehr. Vielleicht hängt ein Befehl. Soll ich nachhaken?",
    };

    // The hint the session gets when Sir says yes.
    public static string Hint(Finding f)
    {
        var what = f.Kind switch
        {
            "circles" => $"Du wiederholst denselben Schritt ({f.Times}× {f.What}).",
            "failing" => $"Deine letzten {f.Times} Schritte sind alle fehlgeschlagen.",
            _ => $"Seit {f.Times} Minuten kommt von dir nichts mehr — vielleicht hängt ein Befehl.",
        };
        return $"Hinweis vom Parley-Wachhund, mit Sirs Zustimmung: {what} Halte inne, fasse in zwei Sätzen zusammen, "
             + "woran es hängt, und versuche einen anderen Weg. Kommst du nicht weiter, frag Sir.";
    }
}

// Each kind of finding is reported once per session per half hour — also after a "no".
public sealed class WatchdogMemory
{
    public static readonly TimeSpan Quiet = TimeSpan.FromMinutes(30);
    private readonly Dictionary<string, DateTime> _reported = new();

    public bool ShouldReport(string id, Watchdog.Finding f, DateTime now)
    {
        var key = id + "|" + f.Kind;
        if (_reported.TryGetValue(key, out var at) && now - at < Quiet) return false;
        _reported[key] = now;
        return true;
    }
}
