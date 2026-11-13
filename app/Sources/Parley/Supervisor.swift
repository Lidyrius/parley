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
/// through restarts) without ringing again. What he hears when he calls back is ready before he
/// does (`ready`): the one line that waits, or — once there are more — the one summary the
/// Zentrale is asked for as each joins. It plays the moment his call connects; the Zentrale
/// then learns what he heard and what he said. Keep in step with windows/Supervisor.cs.
struct MissedLine: Codable, Equatable, Sendable {
    var at: Date
    var text: String
    var asks: Bool          // a <speak>: it wanted an answer
    var sum: Bool? = nil    // the Zentrale's summary of the lines before it (not a line he missed)
}

enum Missed {
    static let file = Reminders.file.deletingLastPathComponent().appendingPathComponent("missed.json")
    static let most = 40                             // the newest; older ones are long overtaken
    static let noticeEvery: TimeInterval = 15 * 60   // a notification with the count at most this often
    static let summaryWithin: TimeInterval = 180     // the Zentrale's next line is the summary asked for, this long

    /// The lines he missed (without a summary made of them).
    static func lines(_ list: [MissedLine]) -> [MissedLine] { list.filter { $0.sum != true } }

    /// What he hears first when he calls back, if it is ready: the one line that waits, or the
    /// summary of all of them. nil: more than one waits and the newest is not in a summary yet.
    static func ready(_ list: [MissedLine]) -> MissedLine? {
        list.count == 1 ? list[0] : list.last.flatMap { $0.sum == true ? $0 : nil }
    }

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
    [Parley] Sir hat den Anruf nicht angenommen. Deine Zeile ist für seinen Rückruf vorgemerkt: \
    Ruft er zurück, hört er sie sofort, und du erfährst, was er geantwortet hat. Alles Weitere, \
    was du ihm sagst, wird ebenfalls gesammelt, ohne erneut zu klingeln; dann bitte ich dich um \
    EINE Zusammenfassung, die er stattdessen hört. Arbeite normal weiter (Berichte annehmen, \
    delegieren, was nur Sir entscheiden kann, offen halten). Antworte hierauf nur mit \
    <speak-end></speak-end>.
    """

    private static func clock(_ d: Date) -> String {
        d.formatted(.dateTime.hour().minute().locale(Locale(identifier: "de_DE")))
    }

    // The lines he missed: what is open first, then the rest, each oldest first.
    private static func listing(_ list: [MissedLine]) -> [String] {
        let open = list.filter(\.asks), rest = list.filter { !$0.asks }
        func lines(_ l: [MissedLine]) -> String { l.map { "- (\(clock($0.at)) Uhr) \($0.text)" }.joined(separator: "\n") }
        return (open.isEmpty ? [] : ["Offen — Fragen an ihn, älteste zuerst:\n" + lines(open)])
            + (rest.isEmpty ? [] : ["Zur Kenntnis, älteste zuerst:\n" + lines(rest)])
    }

    private static let how = "zuerst, was offen ist oder seine Entscheidung braucht, dann kurz das Erledigte. Was sich inzwischen überholt oder erledigt hat, lass weg oder sag es in einem Halbsatz."

    /// Sir is back and nothing was ready for him (or he says something right now — `said`, "Hey
    /// Parley, …"): everything he missed as one instruction, for a summary made now.
    static func instruction(_ all: [MissedLine], said: String? = nil) -> String {
        let list = lines(all)
        var out = ["[Parley] Sir ruft zurück. Seit dem nicht angenommenen Anruf (\(list.first.map { clock($0.at) } ?? "?") Uhr) hat er \(list.count == 1 ? "diese Zeile" : "diese \(list.count) Zeilen") von dir nicht gehört."]
        out += listing(list)
        out.append("Gib ihm jetzt EINE gesprochene Zusammenfassung: \(how) Danach geht es normal weiter.")
        if let said = said?.trimmingCharacters(in: .whitespacesAndNewlines), !said.isEmpty {
            out.append("Außerdem sagt Sir gerade: „\(said)“")
        }
        return out.joined(separator: "\n\n")
    }

    /// More than one line waits: what the Zentrale reads in place of an answer to the newest —
    /// its next line is the summary he hears the moment he calls back.
    static func summaryRequest(_ all: [MissedLine]) -> String {
        let list = lines(all)
        return (["[Parley] Sir hat noch nicht zurückgerufen; auch diese Zeile ist vorgemerkt. Es warten jetzt \(list.count) Zeilen von dir auf ihn."]
            + listing(list)
            + ["Schreib jetzt die EINE gesprochene Zusammenfassung, die er beim Rückruf sofort hört, ohne Wartezeit: \(how) Antworte nur mit ihr — als <speak>, wenn etwas offen ist, sonst als <speak-end>. Es klingelt dabei nicht; danach arbeitest du normal weiter."])
            .joined(separator: "\n\n")
    }

    /// He called back and heard `line` at once (of `all` that waited): what the Zentrale reads now.
    static func heard(_ line: MissedLine, of all: [MissedLine], answer: String) -> String {
        let list = lines(all)
        var out = ["[Parley] Sir hat zurückgerufen und sofort gehört: „\(line.text)“"]
        if line.sum == true { out.append("Das war deine Zusammenfassung dieser \(list.count) Zeilen:\n" + listing(list).joined(separator: "\n\n")) }
        let said = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        out.append(said.isEmpty
            ? "Er hat darauf nichts gesagt. Liegt nichts Neues an, antworte nur mit <speak-end></speak-end>."
            : "Seine Antwort: „\(said)“")
        return out.joined(separator: "\n\n")
    }

    /// The Live Activity's line and the notification: how many wait.
    static func waiting(_ n: Int) -> String {
        n == 1 ? "1 Update wartet auf deinen Rückruf" : "\(n) Updates warten auf deinen Rückruf"
    }
}

