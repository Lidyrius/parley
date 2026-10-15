import Foundation

// Which Parley sessions exist and what each one is doing — for GET /sessions (the Claude
// Code mod's overview), POST /resume and the "Update zu <Name>" announcement. Three signals
// feed it: /presence heartbeats from the mod (~2 s, Claude Code only), the Stop hook's
// /turn + /wake traffic, and the reply the app hands back for each turn. The state itself is
// derived from timestamps on every read, so a session that goes silent ages into `stopped`
// on its own — there is no clean "session ended" signal.
//
// ponytail: not thread-safe on its own; ControlServer drives it from its serial queue.
final class SessionRegistry {
    struct Entry {
        var id: String                 // the agent's session_id
        var label = ""                 // spoken label (.parley.json) or the project
        var project = ""               // cwd basename
        var firstSeen: Date
        var presenceAt: Date?          // last /presence (nil = never sent, e.g. Codex)
        var presenceState = "idle"     // the mod's last state: working | background | idle
        var tasks: [BackgroundTask] = []   // its in-flight background tasks, as last reported
        var host: String?              // desktop app session id (local_…): the mod opens it by deep link
        var hookAt: Date               // last /turn, /wake or turn reply
        var queued = false             // a /turn (or resume dialog) waits in the queue
        var waitUntil: Date?           // "Warte X Minuten": the hook sleeps until then
        var parked = false             // answered with park; its hook polls /wake
        var wakeAt: Date?              // last /wake poll
        var injectedAt: Date?          // a reply was fed back → the agent is working on it
        var expectWorkUntil: Date?     // …shown as working until the mod confirms (max 15 s)
        var pending: String?           // resume instruction for the mod's next /presence
        var startedAt: Date?           // from the mod's usage
        var contextPercent: Double?
        var costUsd: Double?           // cumulative, as last reported
        var turns = 0                  // voiced turns since the app saw the session
        var replies = 0                // transcripts injected back
        var lastLine: String?          // last <speak> line voiced for it
        var state = ""
        var since: Date
    }

    private(set) var entries: [String: Entry] = [:]
    private(set) var activeId: String?   // the turn being voiced right now
    private var rateLimits: [RateLimit] = []   // latest reported by any session
    private let now: () -> Date
    private let phase: () -> String      // phase of the active turn (LiveStatus)
    private let daily: DailyStats

    // A session's label appeared or changed → pre-render its clips. Set once at startup.
    var onLabel: ((String) -> Void)?

    // Windows (seconds) from the contract: presence goes stale after 20 s, a parked hook
    // after 30 s without a /wake poll, a hook-only session (no presence) after 5 min.
    static let presenceTTL: TimeInterval = 20
    static let parkTTL: TimeInterval = 30
    static let hookTTL: TimeInterval = 300
    static let keepStopped: TimeInterval = 600
    static let landingTTL: TimeInterval = 15

    init(now: @escaping () -> Date = { Date() }, phase: @escaping () -> String = { LiveStatus.currentPhase() },
         daily: DailyStats = .shared) {
        self.now = now
        self.phase = phase
        self.daily = daily
    }

    // MARK: - signals

    // The mod's heartbeat. Returns a pending resume instruction — exactly once — for the mod
    // to submit as a prompt in its session.
    @discardableResult
    func presence(id: String, label: String, project: String, state: String,
                  usage: PresenceUsage? = nil, tasks: [BackgroundTask]? = nil, host: String? = nil) -> String? {
        var delivered: String?
        update(id, label: label, project: project) { e, t in
            e.presenceAt = t
            e.presenceState = state
            e.tasks = tasks ?? []
            if let h = host, !h.isEmpty { e.host = h }
            if state == "working" { e.expectWorkUntil = nil }
            if let u = usage {
                if let s = u.startedAt { e.startedAt = Date(timeIntervalSince1970: s / 1000) }
                e.contextPercent = u.contextPercent ?? e.contextPercent
                e.costUsd = u.costUsd ?? e.costUsd
            }
            if let p = e.pending { delivered = p; e.pending = nil; Self.inject(&e, t) }
        }
        if let cost = usage?.costUsd, !id.isEmpty {
            daily.addCost(session: id, cumulative: cost, startedAt: entries[id]?.startedAt)
        }
        if let limits = usage?.rateLimits, !limits.isEmpty { rateLimits = limits }
        return delivered
    }

    // A /turn arrived; it waits in the queue until it's this session's turn to speak.
    func queued(id: String, label: String, project: String) {
        update(id, label: label, project: project) { e, t in
            e.hookAt = t
            e.queued = true
            e.waitUntil = nil
            e.parked = false
            e.injectedAt = nil
            e.expectWorkUntil = nil
            e.pending = nil   // the session moved on by itself — drop a stale resume
        }
    }

    // A resume dialog for the session waits in the queue (its other state is kept).
    func resumeQueued(id: String) {
        update(id) { e, _ in e.queued = true }
    }

    // The session now holds the voice: its turn (`speak` = the line) or its resume dialog (nil).
    func activate(id: String, speak: String?) {
        activeId = id
        update(id) { e, t in
            e.queued = false
            guard let speak else { return }
            e.hookAt = t
            e.turns += 1
            e.lastLine = speak
        }
    }

    // The turn's reply went back to the hook: wait, park, inject a transcript, or end.
    func finished(id: String, reply: TurnReply) {
        if activeId == id { activeId = nil }
        update(id) { e, t in
            e.hookAt = t
            e.queued = false
            e.waitUntil = reply.waitSeconds > 0 ? t.addingTimeInterval(TimeInterval(reply.waitSeconds)) : nil
            e.parked = reply.park
            e.wakeAt = reply.park ? t : nil
            e.injectedAt = nil
            e.expectWorkUntil = nil
            if !reply.transcript.isEmpty { e.replies += 1; Self.inject(&e, t) }
        }
    }

    // The resume dialog ended; the server hands its instruction over next.
    func resumeFinished(id: String, replied: Bool) {
        if activeId == id { activeId = nil }
        update(id) { e, _ in
            e.queued = false
            if replied { e.replies += 1 }
        }
    }

    // A resume instruction was handed to the parked hook (its next /wake poll injects it).
    func wakeQueued(id: String) {
        update(id) { e, t in e.parked = false; Self.inject(&e, t) }
    }

    // A resume instruction for an idle session, delivered on its next /presence. Unknown
    // sessions are ignored.
    func setPending(id: String, _ instruction: String) {
        guard entries[id] != nil else { return }
        update(id) { e, _ in e.pending = instruction }
    }

    // A parked hook polled /wake. `resumed` = it was handed an instruction and goes on working.
    func wakePoll(id: String, label: String, project: String, resumed: Bool) {
        update(id, label: label, project: project) { e, t in
            e.hookAt = t
            e.wakeAt = t
            e.parked = !resumed
            if resumed { Self.inject(&e, t) }
        }
    }

    private static func inject(_ e: inout Entry, _ t: Date) {
        e.injectedAt = t
        e.expectWorkUntil = t.addingTimeInterval(landingTTL)
    }

    // MARK: - queries

    // Parked, or idle with a live mod (it can submit the instruction). A Codex session
    // (no presence) is only resumable while parked; a `background` one wakes on its own.
    func canResume(_ id: String) -> Bool {
        refresh()
        return entries[id].map(Self.resumable) ?? false
    }

    private static func resumable(_ e: Entry) -> Bool {
        e.state == "parked" || (e.state == "idle" && e.presenceAt != nil)
    }

    // Resumable sessions for the menu / tray and the voice resume command.
    func resumableList() -> [ParkedInfo] {
        refresh()
        return entries.values.filter(Self.resumable)
            .map { ParkedInfo(id: $0.id, label: $0.label, project: $0.project) }
            .sorted { $0.label < $1.label }
    }

    // The session's parked hook is still polling /wake (regardless of a running dialog).
    func parkedHookAlive(_ id: String) -> Bool {
        guard let e = entries[id], e.parked, let w = e.wakeAt else { return false }
        return now().timeIntervalSince(w) < Self.parkTTL
    }

    // Any session besides `id` that isn't stopped → the turn gets announced.
    func othersAlive(except id: String) -> Bool {
        refresh()
        return entries.values.contains { $0.id != id && $0.state != "stopped" }
    }

    // GET /sessions — voice holder first, then alive sessions by label, stopped last.
    func json() -> String {
        refresh()
        func rank(_ e: Entry) -> Int { e.id == activeId ? 0 : (e.state == "stopped" ? 2 : 1) }
        let rows = entries.values.sorted {
            let (ra, rb) = (rank($0), rank($1))
            if ra != rb { return ra < rb }
            let c = $0.label.caseInsensitiveCompare($1.label)
            return c != .orderedSame ? c == .orderedAscending : $0.id < $1.id
        }.map { e in
            Row(id: e.id, label: e.label, project: e.project, state: e.state, since: Self.ms(e.since),
                until: e.state == "waiting" ? e.waitUntil.map(Self.ms) : nil, voice: e.id == activeId,
                resumable: Self.resumable(e), tasks: e.tasks, host: e.host ?? DesktopSessions.host(for: e.id),
                stats: RowStats(startedAt: Self.ms(e.startedAt ?? e.firstSeen), contextPercent: e.contextPercent,
                                costUsd: e.costUsd, turns: e.turns, replies: e.replies, lastLine: e.lastLine))
        }
        let day = daily.snapshot()
        let today = Today(costUsd: (day.costUsd * 10_000).rounded() / 10_000, turns: day.turns,
                          spokenSeconds: Int(day.spokenSeconds.rounded()), rateLimits: rateLimits)
        let data = try? JSONEncoder().encode(Wire(sessions: rows, today: today))
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? #"{"sessions":[]}"#
    }

    private struct Wire: Encodable { let sessions: [Row]; let today: Today }
    private struct Today: Encodable { let costUsd: Double; let turns: Int; let spokenSeconds: Int; let rateLimits: [RateLimit] }

    private struct Row: Encodable {
        let id, label, project, state: String
        let since: Int64
        let until: Int64?
        let voice, resumable: Bool
        let tasks: [BackgroundTask]
        let host: String?
        let stats: RowStats
        enum CodingKeys: String, CodingKey { case id, label, project, state, since, until, voice, resumable, tasks, host, stats }
        func encode(to encoder: Encoder) throws {   // explicit: `until` must be null, not omitted
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id); try c.encode(label, forKey: .label)
            try c.encode(project, forKey: .project); try c.encode(state, forKey: .state)
            try c.encode(since, forKey: .since); try c.encode(until, forKey: .until)
            try c.encode(voice, forKey: .voice); try c.encode(resumable, forKey: .resumable)
            try c.encode(tasks, forKey: .tasks); try c.encode(host, forKey: .host)
            try c.encode(stats, forKey: .stats)
        }
    }

    private struct RowStats: Encodable {
        let startedAt: Int64?
        let contextPercent: Double?
        let costUsd: Double?
        let turns, replies: Int
        let lastLine: String?
        enum CodingKeys: String, CodingKey { case startedAt, contextPercent, costUsd, turns, replies, lastLine }
        func encode(to encoder: Encoder) throws {   // explicit nulls, as above
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(startedAt, forKey: .startedAt); try c.encode(contextPercent, forKey: .contextPercent)
            try c.encode(costUsd, forKey: .costUsd); try c.encode(turns, forKey: .turns)
            try c.encode(replies, forKey: .replies); try c.encode(lastLine, forKey: .lastLine)
        }
    }

    private static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }

    // MARK: - state derivation

    // Precedence high→low: the voiced turn's phase, queued, waiting, parked, working,
    // background, idle, stopped.
    func state(of e: Entry, at t: Date) -> String {
        if e.id == activeId {
            let p = phase()
            return ["speaking", "listening", "transcribing"].contains(p) ? p : "speaking"
        }
        if e.queued { return "queued" }
        if let u = e.waitUntil, t < u { return "waiting" }
        if e.parked, let w = e.wakeAt, t.timeIntervalSince(w) < Self.parkTTL { return "parked" }
        if let p = e.presenceAt {
            guard t.timeIntervalSince(p) < Self.presenceTTL else { return "stopped" }
            // A resume instruction waiting for / just handed to the mod counts as working.
            let landing = e.pending != nil || (e.expectWorkUntil.map { t < $0 } ?? false)
            if e.presenceState == "working" || landing { return "working" }
            return e.presenceState == "background" ? "background" : "idle"
        }
        // No presence (e.g. Codex): only the hook's traffic tells. A finished wait counts as
        // hook activity + injection — the hook woke up and fed the resume prompt back.
        let hook = max(e.hookAt, e.waitUntil ?? .distantPast)
        guard t.timeIntervalSince(hook) < Self.hookTTL else { return "stopped" }
        let injected = max(e.injectedAt ?? .distantPast, e.waitUntil ?? .distantPast)
        return t.timeIntervalSince(injected) < Self.hookTTL ? "working" : "idle"
    }

    private func lastSignal(_ e: Entry) -> Date {
        [e.presenceAt, e.wakeAt, e.waitUntil].compactMap { $0 }.reduce(e.hookAt, max)
    }

    // Re-derive every state (stamping `since` on change) and forget sessions that have been
    // silent for 10 min.
    private func refresh() {
        let t = now()
        for (id, var e) in entries {
            let s = state(of: e, at: t)
            if s == "stopped", t.timeIntervalSince(lastSignal(e)) > Self.keepStopped, id != activeId {
                entries[id] = nil
                continue
            }
            if s != e.state { e.state = s; e.since = t }
            entries[id] = e
        }
    }

    private func update(_ id: String, label: String = "", project: String = "",
                        _ change: (inout Entry, Date) -> Void) {
        guard !id.isEmpty else { return }
        let t = now()
        var e = entries[id] ?? Entry(id: id, firstSeen: t, hookAt: t, since: t)
        let before = e.label
        if !project.isEmpty { e.project = project }
        if !label.isEmpty { e.label = label } else if e.label.isEmpty { e.label = e.project }
        change(&e, t)
        entries[id] = e
        refresh()
        if e.label != before, !e.label.isEmpty { onLabel?(e.label) }
    }
}

// The Claude desktop app's own record of its Code sessions, one file per session:
// Application Support/Claude/claude-code-sessions/<org>/<user>/local_<id>.json holding
// `cliSessionId` (the id our hooks and the mod know) and `sessionId` (the desktop's local_…).
// It lets a tile deep-link to any desktop session, whatever mod version that session runs.
// ponytail: rescans at most every 10 s; a handful of small files.
enum DesktopSessions {
    nonisolated(unsafe) private static var cache: (at: Date, map: [String: String]) = (.distantPast, [:])

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude/claude-code-sessions", isDirectory: true)
    }

    static func host(for cliId: String) -> String? {
        if Date().timeIntervalSince(cache.at) > 10 { cache = (Date(), load(root)) }
        return cache.map[cliId]
    }

    static func load(_ root: URL) -> [String: String] {
        struct File: Decodable { let sessionId: String?; let cliSessionId: String? }
        var map: [String: String] = [:]
        let fm = FileManager.default
        for org in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for user in (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: nil)) ?? [] {
                for f in (try? fm.contentsOfDirectory(at: user, includingPropertiesForKeys: nil)) ?? []
                where f.lastPathComponent.hasPrefix("local_") && f.pathExtension == "json" {
                    guard let data = try? Data(contentsOf: f),
                          let d = try? JSONDecoder().decode(File.self, from: data),
                          let cli = d.cliSessionId, let id = d.sessionId, id.hasPrefix("local_") else { continue }
                    map[cli] = id
                }
            }
        }
        return map
    }
}
