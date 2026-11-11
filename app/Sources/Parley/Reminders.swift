import Foundation

// Wiedervorlage: something Sir says now, handed over later. The Zentrale turns his words into
// POST /remind (GET /remind lists, POST /remind/cancel removes):
//
// - for a session, at a time     {"to":"Shirts","text":"Lass die Tests laufen","at":"2026-10-19T09:00:00+02:00"}
//                                ("in": minutes instead of "at")
// - for a session, once another is done   {"to":"Zentrale","text":"Deploye","after":"Shirts"}
// - for Sir himself              {"text":"das Telefonat mit Max","in":30}   (no "to", or "to":"sir")
// - again and again              {"to":"Zentrale","text":"Prüfe Mails und Sessions","every":5}
//                                (minutes; first after one interval, or at "at" / "in"; until cancelled)
//
// `to` / `after` are a session's spoken name, its id, or a past session's id (/past); `cwd`
// instead of `to` names a folder. The host keeps them in reminders.json (survives restarts and
// updates). Due for a session: it gets the text as an instruction — resumed or started if it
// doesn't run. Due for Sir: spoken at the Mac, or the phone rings when Unterwegs.
struct Reminder: Codable, Equatable, Sendable {
    var id: String
    var text: String
    var label: String          // who gets it: a session's spoken name, or "Sir"
    var session: String?       // its id (nil: Sir, or a folder without a known session)
    var cwd: String?           // its folder: to resume / start it when it doesn't run
    var at: Date?              // due then …
    var after: String?         // … or once this session stopped working
    var afterLabel: String?
    var every: Double?         // minutes: due again and again from `at` on, until cancelled
    var created: Date

    var forSir: Bool { session == nil && cwd == nil }
}

enum Reminders {
    /// A session by name or id → its id (if known), spoken name and folder.
    typealias Resolve = (String) -> (id: String?, label: String, cwd: String)?

    static let maxDays: Double = 60
    static let minEvery: Double = 1

    struct Invalid: Error, Equatable { let why: String }

    /// The POST body → a reminder, or what is wrong.
    static func make(_ body: Data, now: Date, id: String = "r" + UUID().uuidString.prefix(8).lowercased(),
                     resolve: Resolve) -> Result<Reminder, Invalid> {
        struct Body: Decodable { var text: String?; var to: String?; var cwd: String?; var at: String?; var `in`: Double?; var after: String?; var every: Double? }
        guard let b = try? JSONDecoder().decode(Body.self, from: body) else { return .failure(Invalid(why: "body must be a JSON object")) }
        let text = (b.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(Invalid(why: "text is missing")) }
        let whens = [b.at != nil, b.in != nil, b.after != nil].filter({ $0 }).count
        guard whens == 1 || (whens == 0 && b.every != nil) else {
            return .failure(Invalid(why: "give exactly one of at, in, after (or every alone)"))
        }
        var r = Reminder(id: id, text: String(text.prefix(2000)), label: "Sir", created: now)
        if let every = b.every {
            guard b.after == nil else { return .failure(Invalid(why: "every goes with at or in, not with after")) }
            guard every >= minEvery, every <= maxDays * 1440 else { return .failure(Invalid(why: "every must be minutes, at least \(Int(minEvery))")) }
            r.every = every
            if whens == 0 { r.at = now.addingTimeInterval(every * 60) }
        }

        if let at = b.at {
            guard let d = date(at) else { return .failure(Invalid(why: "at must be ISO 8601 with a zone, e.g. 2026-10-19T09:00:00+02:00")) }
            r.at = d
        } else if let minutes = b.in {
            guard minutes >= 0 else { return .failure(Invalid(why: "in must be minutes from now")) }
            r.at = now.addingTimeInterval(minutes * 60)
        }
        if let at = r.at {
            guard at > now.addingTimeInterval(-60) else { return .failure(Invalid(why: "at is in the past")) }
            guard at < now.addingTimeInterval(maxDays * 86_400) else { return .failure(Invalid(why: "at is more than \(Int(maxDays)) days away")) }
        }
        if let after = b.after {
            guard let s = resolve(after), let sid = s.id else { return .failure(Invalid(why: "no session \"\(after)\" to wait for")) }
            r.after = sid
            r.afterLabel = s.label
        }

        let to = (b.to ?? "").trimmingCharacters(in: .whitespaces)
        if let cwd = b.cwd?.trimmingCharacters(in: .whitespaces), !cwd.isEmpty {
            guard cwd.hasPrefix("/") || cwd.hasPrefix("~") else { return .failure(Invalid(why: "cwd must be an absolute folder")) }
            r.cwd = Zentrale.normalize(cwd)
            r.label = to.isEmpty ? (r.cwd! as NSString).lastPathComponent : to
        } else if !to.isEmpty, to.lowercased() != "sir" {
            guard let s = resolve(to) else { return .failure(Invalid(why: "no session \"\(to)\"")) }
            r.session = s.id
            r.label = s.label
            r.cwd = s.cwd.isEmpty ? nil : s.cwd
        }
        if r.forSir, r.after != nil { return .failure(Invalid(why: "after needs a session in to")) }
        return .success(r)
    }

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    static let busy: Set<String> = ["working", "background"]

    /// Due now: its time has come, or the session it waits for is done — it stopped working
    /// after the reminder was made, or is gone. `state(id)`: a listed session's state and since.
    static func isDue(_ r: Reminder, now: Date, state: (String) -> (state: String, since: Date)?) -> Bool {
        if let at = r.at { return at <= now }
        guard let after = r.after else { return true }
        guard let s = state(after) else { return true }
        return s.state == "stopped" || (!busy.contains(s.state) && s.since > r.created)
    }

    /// A recurring one's next time after `now`: on its own grid, missed rounds (the Mac slept,
    /// Parley was off) are skipped, not caught up.
    static func next(_ r: Reminder, after now: Date) -> Date? {
        guard let every = r.every, every > 0, let at = r.at else { return nil }
        let step = every * 60
        return at.addingTimeInterval((floor(max(0, now.timeIntervalSince(at)) / step) + 1) * step)
    }

    /// A recurring one skips a round while its session talks to Sir or works: the next comes anyway.
    static let skipRound: Set<String> = ["working", "speaking", "listening", "transcribing", "queued"]

    static func minutes(_ every: Double) -> String {
        every == 1 ? "jede Minute" : "alle \(every == every.rounded() ? String(Int(every)) : String(every)) Minuten"
    }

    /// What the session gets.
    static func instruction(_ r: Reminder, now: Date) -> String {
        if let every = r.every { return "Wiedervorlage (\(minutes(every))): \(r.text)" }
        let when = r.created.formatted(.dateTime.weekday(.wide).hour().minute().locale(Locale(identifier: "de_DE")))
        let why = r.afterLabel.map { " — \($0) ist fertig" } ?? ""
        return "Wiedervorlage von Sir (gesprochen \(when)\(why)): \(r.text)"
    }

    /// What Sir hears.
    static func spoken(_ r: Reminder) -> String { "Erinnerung, Sir: \(r.text)" }

    // MARK: - reminders.json

    static let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Parley", isDirectory: true).appendingPathComponent("reminders.json")

    static func load(_ url: URL?) -> [Reminder] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .millisecondsSince1970
        return (try? dec.decode([Reminder].self, from: data)) ?? []
    }

    static func save(_ list: [Reminder], to url: URL?) {
        guard let url else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .millisecondsSince1970
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(list).write(to: url, options: .atomic)
    }

    /// GET /remind, and the `reminders` in /sessions (the phone lists them): soonest first,
    /// waiting ones last; times in epoch ms.
    struct Row: Encodable, Equatable {
        let id, text, to: String
        let at: Int64?
        let after: String?
        var every: Double? = nil   // minutes, a recurring one
    }

    static func rows(_ list: [Reminder]) -> [Row] {
        list.sorted { ($0.at ?? .distantFuture, $0.created) < ($1.at ?? .distantFuture, $1.created) }
            .map { Row(id: $0.id, text: $0.text, to: $0.label, at: $0.at.map { Int64($0.timeIntervalSince1970 * 1000) },
                       after: $0.afterLabel, every: $0.every) }
    }
}
