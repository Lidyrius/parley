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
