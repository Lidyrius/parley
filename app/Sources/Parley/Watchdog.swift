import Foundation

// The Wachhund: notices a session that works but gets nowhere, and asks Sir whether to step in.
// Every 30 s, for each session that is working, it reads the tail of its Claude Code transcript:
//
// - circles  — the same tool call 4 times among the last 8 ("Bash · npm test" again and again)
// - failing  — the last 6 tool calls all failed
// - silent   — working for 15 min, but nothing written to the transcript for 10 (a hung command,
//              or a prompt in the terminal nobody sees)
//
// Sir hears it as a question (at the Mac or on a call) or gets a notification (Unterwegs); a yes
// sends the session a hint — Claude Code reads it at its next step, mid-turn.
enum Watchdog {
    struct Call: Equatable, Sendable {
        let key: String       // tool name + its input, to spot the same call again
        let label: String     // "Bash · npm test"
        let failed: Bool
    }

    enum Finding: Equatable, Sendable {
        case circles(times: Int, what: String)
        case failing(times: Int)
        case silent(minutes: Int)

        var kind: String {
            switch self {
            case .circles: "circles"
            case .failing: "failing"
            case .silent: "silent"
            }
        }
    }

    static let window = 8, repeats = 4, failures = 6
    static let workingFor: TimeInterval = 15 * 60, quietFor: TimeInterval = 10 * 60

    /// The tool calls in transcript lines, oldest first, each with whether its result failed.
    static func calls(_ lines: [Data]) -> [Call] {
        var order: [(id: String, call: Call)] = []
        var failed: Set<String> = []
        for line in lines {
            guard let e = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let content = (e["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for block in content {
                switch block["type"] as? String {
                case "tool_use":
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                    let input = block["input"] as? [String: Any] ?? [:]
                    let canonical = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
                        .map { String(decoding: $0, as: UTF8.self) } ?? ""
                    order.append((id, Call(key: name + "|" + canonical, label: Transcript.tool(name, input), failed: false)))
                case "tool_result":
                    if block["is_error"] as? Bool == true, let id = block["tool_use_id"] as? String { failed.insert(id) }
                default:
                    break
                }
            }
        }
        return order.map { Call(key: $0.call.key, label: $0.call.label, failed: failed.contains($0.id)) }
    }

    /// What is wrong with a session, if anything. Only working sessions are judged.
    static func check(state: String, since: Date, lastWrite: Date?, calls: [Call], now: Date) -> Finding? {
        guard state == "working" else { return nil }
        let recent = calls.suffix(window)
        let counts = Dictionary(grouping: recent, by: \.key)
        if let (_, same) = counts.max(by: { $0.value.count < $1.value.count }), same.count >= repeats {
            return .circles(times: same.count, what: same[0].label)
        }
        let last = calls.suffix(failures)
        if last.count == failures, last.allSatisfy(\.failed) { return .failing(times: failures) }
        if now.timeIntervalSince(since) >= workingFor, let w = lastWrite, now.timeIntervalSince(w) >= quietFor {
            return .silent(minutes: Int(now.timeIntervalSince(w) / 60))
        }
        return nil
    }

    /// Spoken (JARVIS): what is wrong, and the question.
    static func question(label: String, _ f: Finding) -> String {
        switch f {
        case .circles(let n, let what):
            "Wachhund, Sir: \(label) dreht sich im Kreis — \(n)-mal dasselbe: \(spoken(what)). Soll ich eingreifen?"
        case .failing(let n):
            "Wachhund, Sir: Bei \(label) schlägt gerade \(n)-mal hintereinander alles fehl. Soll ich eingreifen?"
        case .silent(let m):
            "Wachhund, Sir: \(label) arbeitet, aber seit \(m) Minuten kommt nichts mehr. Vielleicht hängt ein Befehl. Soll ich nachhaken?"
        }
    }

    /// The hint the session gets when Sir says yes.
    static func hint(_ f: Finding) -> String {
        let what = switch f {
        case .circles(let n, let call): "Du wiederholst denselben Schritt (\(n)× \(call))."
        case .failing(let n): "Deine letzten \(n) Schritte sind alle fehlgeschlagen."
        case .silent(let m): "Seit \(m) Minuten kommt von dir nichts mehr — vielleicht hängt ein Befehl."
        }
        return "Hinweis vom Parley-Wachhund, mit Sirs Zustimmung: \(what) Halte inne, fasse in zwei Sätzen zusammen, "
            + "woran es hängt, und versuche einen anderen Weg. Kommst du nicht weiter, frag Sir."
    }

    /// "Bash · npm test" → "Bash, npm test" (reads better aloud).
    private static func spoken(_ label: String) -> String { label.replacingOccurrences(of: " · ", with: ", ") }
}

// Each kind of finding is reported once per session per half hour — also after a "no".
struct WatchdogMemory: Sendable {
    static let quiet: TimeInterval = 30 * 60
    private var reported: [String: Date] = [:]

    mutating func shouldReport(_ id: String, _ f: Watchdog.Finding, now: Date) -> Bool {
        let key = id + "|" + f.kind
        if let at = reported[key], now.timeIntervalSince(at) < Self.quiet { return false }
        reported[key] = now
        return true
    }
}
