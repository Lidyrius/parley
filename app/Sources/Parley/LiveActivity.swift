import Foundation

// The Parley Live Activity on the iPhone (docs/LIVE-ACTIVITIES.md): every session at a glance in
// the Dynamic Island, on the Lock Screen, the Watch and in CarPlay. The host owns it — it starts
// it by push-to-start while Unterwegs is on and a session runs, pushes each state change (the
// phone's timers count by themselves) and ends it. `Content` is the activity's `content-state`:
// keep it in step with ios/Shared/ParleyActivity.swift and windows/LiveActivity.cs.
enum LiveActivity {
    struct Row: Codable, Equatable, Sendable {
        var id: String
        var label: String
        var state: String
        var since: Double             // epoch s
        var until: Double?
        var callback: Double?         // epoch s; 0 = waits for Sir's call back
    }

    /// Stumm: Parley's question, waiting for Sir — answered with a tap on a predicted answer.
    struct Ask: Codable, Equatable, Sendable {
        var id: String                // the session
        var label: String
        var text: String
        var options: [String] = []

        /// From a voiced turn: the line and its predicted answers (`<reply on>`), trimmed to fit.
        init(id: String, label: String, text: String, options: [String]) {
            self.id = id
            self.label = String(label.prefix(32))
            self.text = String(text.prefix(160))
            self.options = options.map { String($0.trimmingCharacters(in: .whitespaces).prefix(40)) }.filter { !$0.isEmpty }.prefix(3).map { $0 }
        }
    }

    struct Content: Codable, Equatable, Sendable {
        var sessions: [Row] = []
        var alive = 0
        var line: String?
        var from: String?
        var ask: Ask?

        /// Sir is wanted: a question, a call back, a ring to come, Parley talking or wanting to.
        var wantsSir: Set<String> {
            var ids = Set(sessions.filter { $0.callback != nil || ["speaking", "listening", "transcribing", "queued"].contains($0.state) }.map(\.id))
            if let ask { ids.insert("ask:" + ask.id) }
            return ids
        }
    }

    /// A question stays while its session waits (parked, paused or in the background after it); once it works again, talks, or stopped, it was answered some other way.
    static func isOpen(_ ask: Ask, sessions json: String) -> Bool {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let list = obj["sessions"] as? [[String: Any]],
              let s = list.first(where: { $0["id"] as? String == ask.id }) else { return false }
        return ["parked", "waiting", "background"].contains(s["state"] as? String ?? "")
    }

    static let maxRows = 4

    /// The order that matters to Sir: a call back owed, a ring to come, talking, wanting to talk,
    /// paused, working, background, parked — newest first within each.
    static func rank(_ r: Row) -> Int {
        if let c = r.callback { return c <= 0 ? 0 : 1 }
        switch r.state {
        case "speaking", "listening", "transcribing": return 2
        case "queued": return 3
        case "waiting": return 4
        case "working": return 5
        case "background": return 6
        case "parked": return 7
        default: return 8
        }
    }

    /// GET /sessions (the registry's JSON, times in epoch ms) → the activity's content. Stopped
    /// sessions are left out; the line is the most urgent session's last spoken one.
    static func content(fromSessions json: String, ask: Ask? = nil, rows maxRows: Int = maxRows) -> Content {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let list = obj["sessions"] as? [[String: Any]] else { return Content() }
        var rows: [(row: Row, line: String?)] = []
        for s in list {
            guard let id = s["id"] as? String, let state = s["state"] as? String, state != "stopped" else { continue }
            func sec(_ key: String) -> Double? { (s[key] as? NSNumber).map { $0.doubleValue / 1000 } }
            let label = (s["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (s["project"] as? String) ?? String(id.prefix(8))
            let row = Row(id: id, label: String(label.prefix(32)), state: state, since: sec("since") ?? 0,
                          until: sec("until"), callback: sec("callback"))
            rows.append((row, (s["stats"] as? [String: Any])?["lastLine"] as? String))
        }
        rows.sort { rank($0.row) != rank($1.row) ? rank($0.row) < rank($1.row) : $0.row.since > $1.row.since }
        let spoken = rows.first { !($0.line ?? "").isEmpty }
        return Content(sessions: rows.prefix(maxRows).map(\.row), alive: rows.count,
                       line: spoken?.line.map { String($0.prefix(120)) }, from: spoken?.row.label, ask: ask)
    }

    // MARK: - the widgets (a silent push the app stores for them)

    /// The widgets' picture (ios/Shared/WidgetSnapshot.swift `WidgetPush`): up to 8 sessions,
    /// the line, and today's figures from GET /sessions.
    struct Widget: Codable, Equatable, Sendable {
        var sessions: [Row] = []
        var line: String?
        var from: String?
        var cost: Double?
        var updates: Int?
        var limit: Double?
        var week: Double?

        /// What makes a push worth it: the sessions, the line, the limit in whole percent — not
        /// the cost, which creeps up all the time.
        var key: String { "\(sessions)|\(line ?? "")|\(limit.map { Int($0) } ?? -1)" }
    }

    static func widget(fromSessions json: String) -> Widget {
        let c = content(fromSessions: json, rows: 8)
        var w = Widget(sessions: c.sessions, line: c.line, from: c.from)
        if let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
           let today = obj["today"] as? [String: Any] {
            w.cost = (today["costUsd"] as? NSNumber)?.doubleValue
            w.updates = (today["turns"] as? NSNumber)?.intValue
            let limits = today["rateLimits"] as? [[String: Any]] ?? []
            func used(_ kind: String) -> Double? {
                (limits.first { $0["kind"] as? String == kind }?["percentUsed"] as? NSNumber)?.doubleValue
            }
            w.limit = used("five_hour")
            w.week = used("seven_day")
        }
        return w
    }

    /// `{"aps":{"content-available":1},"widget":{…}}` — wakes the app, shows nothing.
    static func widgetPayload(_ w: Widget) -> Data {
        struct Aps: Encodable {
            let contentAvailable = 1
            enum CodingKeys: String, CodingKey { case contentAvailable = "content-available" }
        }
        struct Payload: Encodable { let aps = Aps(); let widget: Widget }
        return (try? JSONEncoder().encode(Payload(widget: w))) ?? Data()
    }

    // MARK: - payloads (APNs `liveactivity`)

    static let attributesType = "ParleyAttributes"
    static let staleAfter: TimeInterval = 15 * 60   // the Mac went quiet: the phone shows it as stale

    enum Event: String { case start, update, end }

    static func payload(_ event: Event, _ content: Content, now: Date) -> Data {
        struct Alert: Encodable { let title: String; let body: String }
        struct Empty: Encodable {}
        struct Aps: Encodable {
            let timestamp: Int
            let event: String
            let contentState: Content
            let staleDate: Int?
            let relevanceScore: Double?
            let dismissalDate: Int?
            let attributesType: String?
            let attributes: Empty?
            let alert: Alert?
            enum CodingKeys: String, CodingKey {
                case timestamp, event, alert, attributes
                case contentState = "content-state", staleDate = "stale-date", relevanceScore = "relevance-score"
                case dismissalDate = "dismissal-date", attributesType = "attributes-type"
            }
        }
        struct Payload: Encodable { let aps: Aps }
        let t = Int(now.timeIntervalSince1970)
        let start = event == .start
        let aps = Aps(timestamp: t, event: event.rawValue, contentState: content,
                      staleDate: event == .end ? nil : t + Int(staleAfter),
                      relevanceScore: event == .end ? nil : (content.wantsSir.isEmpty ? 50 : 100),
                      dismissalDate: event == .end ? t : nil,
                      attributesType: start ? attributesType : nil, attributes: start ? Empty() : nil,
                      alert: start ? Alert(title: "Parley unterwegs", body: startLine(content)) : nil)
        return (try? JSONEncoder().encode(Payload(aps: aps))) ?? Data()
    }

    /// The start's banner: what runs, in one line.
    static func startLine(_ c: Content) -> String {
        guard let top = c.sessions.first else { return "Bereit." }
        let more = c.alive > 1 ? " · \(c.alive) aktiv" : ""
        return "\(top.label) \(top.state == "working" ? "arbeitet" : "ist dabei")\(more)"
    }
}

// When to start, update and end the activity — pure, so it is tested without APNs. `step` runs
// every couple of seconds with the current content; what it returns is pushed.
struct LiveActivityFeed: Sendable {
    enum Action: Equatable, Sendable {
        case start(LiveActivity.Content)
        case update(LiveActivity.Content, priority: Int)
        case end(LiveActivity.Content)
    }

    static let emptyGrace: TimeInterval = 120          // nothing runs any more: keep it this long
    static let renewAfter: TimeInterval = 7.5 * 3600   // iOS ends an activity after 8 h
    static let heartbeat: TimeInterval = 10 * 60       // refresh the stale date while nothing changes
    static let startRetry: TimeInterval = 60
    static let minGap: TimeInterval = 1

    static let settle: TimeInterval = 30               // a phone's "ended" this soon after a start is the old one's

    private(set) var running = false
    private(set) var dismissed = false                 // Sir swiped it away: not again until Unterwegs goes off
    private var startedAt: Date?
    private var lastStartTry = Date.distantPast
    private var sent: LiveActivity.Content?
    private var sentAt = Date.distantPast
    private var emptySince: Date?

    /// The phone told us whether one runs (its update token arrived, or "" = it ended). An end we
    /// did not push is Sir's (swiped away) — unless it is the replaced one right after a start.
    mutating func phoneReports(running now: Bool, at t: Date) {
        if now {
            if !running { running = true; startedAt = startedAt ?? t }
            return
        }
        if let s = startedAt, t.timeIntervalSince(s) < Self.settle { return }
        if running { dismissed = true }
        running = false
        startedAt = nil
        sent = nil
    }

    mutating func step(_ content: LiveActivity.Content, away: Bool, canStart: Bool, canUpdate: Bool, now: Date) -> Action? {
        if !away { dismissed = false }
        if content.alive > 0 { emptySince = nil } else if emptySince == nil { emptySince = now }
        let idleTooLong = emptySince.map { now.timeIntervalSince($0) >= Self.emptyGrace } ?? false
        let wanted = away && !idleTooLong

        if !wanted || (running && startedAt.map { now.timeIntervalSince($0) >= Self.renewAfter } == true) {
            guard running else { return nil }
            running = false
            startedAt = nil
            sent = nil
            lastStartTry = .distantPast   // a renewal starts again right away
            return canUpdate ? .end(content) : nil
        }
        guard content.alive > 0 || running else { return nil }

        if !running {
            guard canStart, !dismissed, now.timeIntervalSince(lastStartTry) >= Self.startRetry else { return nil }
            running = true
            startedAt = now
            lastStartTry = now
            sent = content
            sentAt = now
            return .start(content)
        }

        guard canUpdate, now.timeIntervalSince(sentAt) >= Self.minGap else { return nil }
        guard content != sent || now.timeIntervalSince(sentAt) >= Self.heartbeat else { return nil }
        let newlyWanted = !content.wantsSir.subtracting(sent?.wantsSir ?? []).isEmpty
        sent = content
        sentAt = now
        return .update(content, priority: newlyWanted ? 10 : 5)
    }
}

// When the widgets get a silent push: iOS throttles them (a few an hour), so at most every
// 20 min, and only when what they show changed.
struct WidgetPushFeed: Sendable {
    static let every: TimeInterval = 20 * 60
    private var sent: String?
    private var sentAt = Date.distantPast

    mutating func due(_ w: LiveActivity.Widget, now: Date) -> Bool {
        guard w.key != sent, now.timeIntervalSince(sentAt) >= Self.every else { return false }
        sent = w.key
        sentAt = now
        return true
    }
}
