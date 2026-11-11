import Foundation

// Überwachungsmodus: only the Zentrale talks to Sir (Mac, call, Live Activity). Every other
// session's turn is not voiced — it reaches the Zentrale as a report, and the session parks
// (resumable, taking the Zentrale's POST /dispatch). The Zentrale delegates, watches the sessions
// and alone gives Sir the updates.
//
// GET /supervisor → {"on","exempt","zentrale","waiting"} · POST /supervisor {"on":bool,"exempt":[…]}
// Kept in supervisor.json (survives restarts and updates). Keep in step with windows/Supervisor.cs.
struct Supervisor: Codable, Equatable {
    var on = false
    var exempt: [String] = []   // sessions that keep talking to Sir themselves: an id or a spoken name

    func exempts(id: String, label: String) -> Bool {
        exempt.contains { $0 == id || $0.caseInsensitiveCompare(label) == .orderedSame }
    }

    static let file = Reminders.file.deletingLastPathComponent().appendingPathComponent("supervisor.json")

    static func load(_ url: URL?) -> Supervisor {
        guard let url, let data = try? Data(contentsOf: url) else { return Supervisor() }
        return (try? JSONDecoder().decode(Supervisor.self, from: data)) ?? Supervisor()
    }

    func save(to url: URL?) {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// The session in the Zentrale's folder, or one that goes by its name.
    static func isZentrale(label: String, cwd: String, zentrale: String) -> Bool {
        label == Zentrale.label || (!cwd.isEmpty && cwd == zentrale)
    }

    static let contextMax = 1500

    /// What the Zentrale gets for a session's turn: its spoken line, whether Sir is asked
    /// (<speak>) or it is done (<speak-end>), the answers it predicted, an excerpt of its last
    /// message, and how to reach it.
    static func report(_ turn: TurnPayload, id: String, background: Bool) -> String {
        let asks = turn.wantsListen
        let state = asks ? "Frage an Sir" : background ? "arbeitet im Hintergrund weiter" : "fertig"
        var lines = ["[Bericht von \(turn.spokenLabel) · \(state)] \(turn.speak)"]
        let options = (turn.replies ?? []).map(\.on).filter { !$0.isEmpty }
        if asks, !options.isEmpty { lines.append("Erwartete Antworten: " + options.joined(separator: " · ")) }
        let context = (turn.context ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty { lines.append("Kontext (Auszug aus ihrer letzten Nachricht):\n" + String(context.suffix(contextMax))) }
        lines.append(asks
            ? "(<speak>: Frage oder Rückfrage — die Session wartet geparkt auf Antwort. Session \(id), Ordner \(turn.cwd).)"
            : "(<speak-end>: keine Antwort erwartet. Session \(id), Ordner \(turn.cwd).)")
        return lines.joined(separator: "\n")
    }

    /// A dispatched instruction as its session reads it: who asks (`from`), and — while the mode
    /// is on — that its spoken line goes to the Zentrale, not to Sir.
    static func instruction(_ text: String, from raw: String?, reportsBack: Bool) -> String {
        let from = (raw ?? "").components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            .trimmingCharacters(in: .whitespaces).prefix(40)
        guard !from.isEmpty, !text.isEmpty else { return text }
        let note = reportsBack
            ? "\n\n(Überwachungsmodus: Deine <speak>- bzw. <speak-end>-Zeile wird nicht vorgelesen, sie geht als Bericht an \(from). Antworte so, dass \(from) damit weiterarbeiten kann.)"
            : ""
        return "[Auftrag von \(from)] \(text)\(note)"
    }
}

/// A line of the Zentrale that Sir did not hear: he didn't take its call (Überwachungsmodus).
/// Nothing waits for him — the Zentrale goes on working, its lines are kept here (missed.json,
/// through restarts) without ringing again, and when he calls back the Zentrale gets them all
/// as one instruction and makes one spoken summary of them. Keep in step with windows/Supervisor.cs.
struct MissedLine: Codable, Equatable, Sendable {
    var at: Date
    var text: String
    var asks: Bool          // a <speak>: it wanted an answer
}

enum Missed {
    static let file = Reminders.file.deletingLastPathComponent().appendingPathComponent("missed.json")
    static let most = 40                             // the newest; older ones are long overtaken
    static let noticeEvery: TimeInterval = 15 * 60   // a notification with the count at most this often

    static func load(_ url: URL?) -> [MissedLine] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .millisecondsSince1970
        return (try? dec.decode([MissedLine].self, from: data)) ?? []
    }

    static func save(_ list: [MissedLine], to url: URL?) {
        guard let url else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .millisecondsSince1970
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(list).write(to: url, options: .atomic)
    }

    /// What the Zentrale reads in place of an answer to the line that rang unanswered.
    static let note = """
    [Parley] Sir hat den Anruf nicht angenommen. Deine Zeile ist für seinen Rückruf vorgemerkt; \
    alles Weitere, was du ihm sagst, wird ebenfalls gesammelt, ohne erneut zu klingeln. Arbeite \
    normal weiter (Berichte annehmen, delegieren, was nur Sir entscheiden kann, offen halten). \
    Antworte hierauf nur mit <speak-end></speak-end>.
    """

    private static func clock(_ d: Date) -> String {
        d.formatted(.dateTime.hour().minute().locale(Locale(identifier: "de_DE")))
    }

    /// Sir is back: everything he missed as one instruction — what is open first, then the rest,
    /// each oldest first. `said`: what he says right now ("Hey Parley, …").
    static func instruction(_ list: [MissedLine], said: String? = nil) -> String {
        let open = list.filter(\.asks), rest = list.filter { !$0.asks }
        func lines(_ l: [MissedLine]) -> String { l.map { "- (\(clock($0.at)) Uhr) \($0.text)" }.joined(separator: "\n") }
        var out = ["[Parley] Sir ruft zurück. Seit dem nicht angenommenen Anruf (\(list.first.map { clock($0.at) } ?? "?") Uhr) hat er \(list.count == 1 ? "diese Zeile" : "diese \(list.count) Zeilen") von dir nicht gehört."]
        if !open.isEmpty { out.append("Offen — Fragen an ihn, älteste zuerst:\n" + lines(open)) }
        if !rest.isEmpty { out.append("Zur Kenntnis, älteste zuerst:\n" + lines(rest)) }
        out.append("Gib ihm jetzt EINE gesprochene Zusammenfassung: zuerst, was offen ist oder seine Entscheidung braucht, dann kurz das Erledigte. Was sich inzwischen überholt oder erledigt hat, lass weg oder sag es in einem Halbsatz. Danach geht es normal weiter.")
        if let said = said?.trimmingCharacters(in: .whitespacesAndNewlines), !said.isEmpty {
            out.append("Außerdem sagt Sir gerade: „\(said)“")
        }
        return out.joined(separator: "\n\n")
    }

    /// The Live Activity's line and the notification: how many wait.
    static func waiting(_ n: Int) -> String {
        n == 1 ? "1 Update wartet auf deinen Rückruf" : "\(n) Updates warten auf deinen Rückruf"
    }
}

