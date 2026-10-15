import Foundation

// Which Parley sessions exist and what each one is doing — for GET /sessions (the Claude
// Code mod's overview), POST /resume and the "Update zu <Name>" announcement. Three signals
// feed it: /presence heartbeats from the mod (~5 s, Claude Code only), the Stop hook's
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
        var presenceAt: Date?          // last /presence (nil = never sent, e.g. Codex)
        var presenceWorking = false    // the mod reported "working"
        var hookAt: Date               // last /turn, /wake or turn reply
        var queued = false             // a /turn waits in the queue
        var waitUntil: Date?           // "Warte X Minuten": the hook sleeps until then
        var parked = false             // answered with park; its hook polls /wake
        var wakeAt: Date?              // last /wake poll
        var injectedAt: Date?          // a reply was fed back → the agent is working on it
        var state = ""
        var since: Date
    }

    private(set) var entries: [String: Entry] = [:]
    private(set) var activeId: String?   // the turn being voiced right now
    private let now: () -> Date
    private let phase: () -> String      // phase of the active turn (LiveStatus)

    // Windows (seconds) from the contract: presence goes stale after 20 s, a parked hook
    // after 30 s without a /wake poll, a hook-only session (no presence) after 5 min.
    static let presenceTTL: TimeInterval = 20
    static let parkTTL: TimeInterval = 30
    static let hookTTL: TimeInterval = 300
    static let keepStopped: TimeInterval = 600

    init(now: @escaping () -> Date = { Date() }, phase: @escaping () -> String = { LiveStatus.currentPhase() }) {
        self.now = now
        self.phase = phase
    }

    // MARK: - signals

    func presence(id: String, label: String, project: String, working: Bool) {
        update(id, label: label, project: project) { e, t in
            e.presenceAt = t
            e.presenceWorking = working
        }
    }

    // A /turn arrived; it waits in the queue until it's this session's turn to speak.
    func queued(id: String, label: String, project: String) {
        update(id, label: label, project: project) { e, t in
            e.hookAt = t
            e.queued = true
            e.waitUntil = nil
            e.parked = false
            e.injectedAt = nil
        }
    }

    // The session's turn is now the one being voiced.
    func activate(id: String) {
        activeId = id
        update(id) { e, t in e.hookAt = t; e.queued = false }
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
            e.injectedAt = reply.transcript.isEmpty ? nil : t
        }
    }

    // A parked hook polled /wake. `resumed` = it was handed an instruction and goes on working.
    func wakePoll(id: String, label: String, project: String, resumed: Bool) {
        update(id, label: label, project: project) { e, t in
            e.hookAt = t
            e.wakeAt = t
            e.parked = !resumed
            if resumed { e.injectedAt = t }
        }
    }

    // MARK: - queries

    func isParked(_ id: String) -> Bool {
        refresh()
        return entries[id]?.state == "parked"
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
                until: e.state == "waiting" ? e.waitUntil.map(Self.ms) : nil, voice: e.id == activeId)
        }
        let data = try? JSONEncoder().encode(["sessions": rows])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? #"{"sessions":[]}"#
    }

    private struct Row: Encodable {
        let id, label, project, state: String
        let since: Int64
        let until: Int64?
        let voice: Bool
        enum CodingKeys: String, CodingKey { case id, label, project, state, since, until, voice }
        func encode(to encoder: Encoder) throws {   // explicit: `until` must be null, not omitted
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id); try c.encode(label, forKey: .label)
            try c.encode(project, forKey: .project); try c.encode(state, forKey: .state)
            try c.encode(since, forKey: .since); try c.encode(until, forKey: .until)
            try c.encode(voice, forKey: .voice)
        }
    }

    private static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }

    // MARK: - state derivation

    // Precedence high→low: the voiced turn's phase, queued, waiting, parked, working, idle,
    // stopped.
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
            return e.presenceWorking ? "working" : "idle"
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
        var e = entries[id] ?? Entry(id: id, hookAt: t, since: t)
        if !project.isEmpty { e.project = project }
        if !label.isEmpty { e.label = label } else if e.label.isEmpty { e.label = e.project }
        change(&e, t)
        entries[id] = e
        refresh()
    }
}
