import Foundation

// Protocol v11 (docs/IPHONE.md): the Detailgrad — how long a session's spoken line is.
// The default level is the host config `detail` (credentials.json); a session may have its own
// in detail.json (app data, beside reminders.json): { "<session id>": "lang" }. Claude learns it
// from a note the host appends to the text it hands the session: mittel / lang on every turn, kurz
// once after it went back (what was last noted is kept in memory only).
enum DetailLevel: String, CaseIterable, Sendable {
    case kurz, mittel, lang

    var title: String {
        switch self {
        case .kurz: "Kurz"
        case .mittel: "Mittel"
        case .lang: "Ausführlich"
        }
    }

    var hint: String {
        switch self {
        case .kurz: "ca. 15 Sek. · 1–2 Sätze (bis ~40 Wörter)"
        case .mittel: "ca. 40 Sek. · 3–5 Sätze (bis ~90 Wörter)"
        case .lang: "ca. 80 Sek. · ganze Zusammenfassung (bis ~180 Wörter)"
        }
    }

    /// "Kurz — ca. 15 Sek. · 1–2 Sätze (bis ~40 Wörter)" (the menu, like the phone).
    var label: String { "\(title) — \(hint)" }

    /// The note handed to the session when this level is new for it.
    var note: String {
        switch self {
        case .kurz: "[Parley · Detailgrad kurz: Sprechzeile wieder höchstens etwa 40 Wörter.]"
        case .mittel: "[Parley · Detailgrad mittel: Sprechzeile bis etwa 90 Wörter (rund 40 Sekunden) – die wichtigsten Punkte mit kurzer Begründung.]"
        case .lang: "[Parley · Detailgrad ausführlich: Sprechzeile bis etwa 180 Wörter (rund 80 Sekunden) – vollständige Zusammenfassung mit Gründen, Zahlen und offenen Punkten.]"
        }
    }
}

// ponytail: @unchecked Sendable — every field is behind `lock`.
final class DetailStore: @unchecked Sendable {
    static let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Parley", isDirectory: true).appendingPathComponent("detail.json")
    static let shared = DetailStore(store: .credentials, file: DetailStore.file)

    private let lock = NSLock()
    private let store: PhoneHub.Store
    private let file: URL?
    private var sessions: [String: DetailLevel]
    private var noted: [String: DetailLevel] = [:]   // per session: the level its last note said

    init(store: PhoneHub.Store, file: URL?) {
        self.store = store
        self.file = file
        sessions = Self.load(file)
    }

    /// The host's default (`detail`; missing / unknown = kurz).
    var defaultLevel: DetailLevel { store.get(.detail).flatMap(DetailLevel.init(rawValue:)) ?? .kurz }

    /// v11's other setting, kept with it for /sessions: Rückmeldung beim Fortsetzen (`resumeLine`
    /// "0" = off, anything else / missing = on).
    var resumeLine: Bool { store.get(.resumeLine) != "0" }

    /// The sessions with their own level (for the `sessions` frame's rows).
    var overrides: [String: DetailLevel] { lock.withLock { sessions } }

    func override(_ id: String) -> DetailLevel? { lock.withLock { sessions[id] } }

    func level(_ id: String) -> DetailLevel { override(id) ?? defaultLevel }

    /// The phone's `detail` frame or the menu: `id` nil = the default; `level` "" = that session
    /// back to the default. Unknown levels are ignored. True when something changed.
    @discardableResult
    func set(id: String?, level: String) -> Bool {
        guard let id, !id.isEmpty else {
            guard let l = DetailLevel(rawValue: level), l != defaultLevel else { return false }
            store.set(l == .kurz ? "" : l.rawValue, .detail)
            return true
        }
        let l: DetailLevel?
        if level.isEmpty { l = nil } else {
            guard let parsed = DetailLevel(rawValue: level) else { return false }
            l = parsed
        }
        let snapshot = lock.withLock { () -> [String: DetailLevel]? in
            guard sessions[id] != l else { return nil }
            sessions[id] = l
            return sessions
        }
        guard let snapshot else { return false }
        Self.save(snapshot, to: file)
        return true
    }

    /// The note to append to the text handed to session `id` now: mittel / lang every time; kurz
    /// (the plugin's default) only on the first turn after the session's level went back to it —
    /// a session never noted counts as at the default (what the plugin's PARLEY_DETAIL told it).
    /// Remembers what it noted.
    func takeNote(_ id: String) -> String? {
        let l = level(id)
        let start = defaultLevel
        return lock.withLock { () -> String? in
            let before = noted[id] ?? start
            noted[id] = l
            return l == .kurz && before == .kurz ? nil : l.note
        }
    }

    /// `text` with the session's Detailgrad note at its end, if one is due.
    func noted(_ text: String, session id: String) -> String {
        guard let note = takeNote(id) else { return text }
        return text.isEmpty ? note : text + "\n\n" + note
    }

    // MARK: - detail.json

    static func load(_ url: URL?) -> [String: DetailLevel] {
        guard let url, let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return raw.compactMapValues(DetailLevel.init(rawValue:))
    }

    static func save(_ map: [String: DetailLevel], to url: URL?) {
        guard let url else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? enc.encode(map.mapValues(\.rawValue)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
