import Foundation

// Labels and figures exactly as the Claude Code mod's /parley overview words them
// (plugin-ui/hooks/register.tsx: STATE, timer, facts, bgLabel, todayParts).

struct Fact: Equatable, Sendable {
    let label: String
    let value: String
}

extension SessionState {
    var label: String {
        switch self {
        case .speaking: "spricht"
        case .listening: "hört zu"
        case .transcribing: "transkribiert"
        case .queued: "Warteschlange"
        case .working: "arbeitet"
        case .background: "Agent im Hintergrund"
        case .waiting: "pausiert"
        case .parked: "geparkt"
        case .idle: "bereit"
        case .stopped: "gestoppt"
        }
    }
}

extension Session {
    var name: String { !label.isEmpty ? label : !project.isEmpty ? project : String(id.prefix(8)) }
    /// Same rule as the mod: a host that does not say falls back to "parked".
    var canResume: Bool { resumable ?? (state == .parked) }
    var isLive: Bool { voice || state == .speaking || state == .listening || state == .transcribing }

    /// Fraction of a pause still left (1 → 0), for the draining ring; nil unless waiting.
    func remaining(at: Double) -> Double? {
        guard state == .waiting, let until else { return nil }
        return min(1, max(0, (until - at) / max(1, until - since)))
    }
}

enum Fmt {
    /// "4:12", "1:02:05".
    static func clock(_ ms: Double) -> String {
        let s = max(0, Int((ms / 1000).rounded(.down)))
        let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "noch 4:12" (pause countdown), "vor 3 min" (stopped), else "seit 2:14".
    static func timer(_ s: Session, at: Double) -> String {
        if s.state == .waiting, let until = s.until { return "noch \(clock(until - at))" }
        if s.state == .stopped { return "vor \(max(1, Int(((at - s.since) / 60_000).rounded()))) min" }
        return "seit \(clock(at - s.since))"
    }

    /// "45 min", "1 h 12 min".
    static func span(_ ms: Double) -> String {
        let m = max(0, Int((ms / 60_000).rounded()))
        return m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
    }

    static func money(_ usd: Double) -> String { String(format: "$%.2f", usd) }
    static func percent(_ p: Double) -> String { "\(Int(p.rounded())) %" }

    /// A tile's details: the figures you'd ask about a session at a glance.
    static func facts(_ s: Session, at: Double) -> [Fact] {
        guard let st = s.stats else { return [] }
        var out: [Fact] = []
        if let started = st.startedAt { out.append(Fact(label: "Laufzeit", value: span(at - started))) }
        if let ctx = st.contextPercent { out.append(Fact(label: "Kontext", value: percent(ctx))) }
        if let cost = st.costUsd { out.append(Fact(label: "Kosten", value: money(cost))) }
        out.append(Fact(label: "Updates", value: "\(st.turns) · \(st.replies) Antw."))
        return out
    }

    /// "Agent im Hintergrund" for subagents/workflows, "Job im Hintergrund" for shells etc.
    static func stateLabel(_ s: Session) -> String {
        guard s.state == .background else { return s.state.label }
        let agents = s.tasks.filter { $0.type == "subagent" || $0.type == "workflow" }.count
        if s.tasks.isEmpty || agents == s.tasks.count {
            return agents > 1 ? "\(agents) Agents im Hintergrund" : "Agent im Hintergrund"
        }
        return s.tasks.count > 1 ? "\(s.tasks.count) Jobs im Hintergrund" : "Job im Hintergrund"
    }

    /// Today's totals as value/label pairs (values bold, labels dim in the header).
    static func todayParts(_ d: Today) -> [Fact] {
        var out = [Fact(label: "Kosten", value: money(d.costUsd)),
                   Fact(label: "Updates", value: "\(d.turns)"),
                   Fact(label: "gesprochen", value: "\(Int((d.spokenSeconds / 60).rounded())) min")]
        let names = ["five_hour": "5-h-Limit", "seven_day": "Woche"]
        for r in d.rateLimits {
            if let name = r.kind.flatMap({ names[$0] }), let p = r.percentUsed { out.append(Fact(label: name, value: percent(p))) }
        }
        return out
    }
}

/// What the header says about the link to the host.
enum ConnectionStatus: Equatable, Sendable {
    case connected, hostOffline, connecting, unknownRoom, rejected, unreachable

    var label: String {
        switch self {
        case .connected: "Mac verbunden"
        case .hostOffline, .unknownRoom: "Mac offline"
        case .connecting: "Verbinde…"
        case .rejected: "Kopplung abgelehnt"
        case .unreachable: "Keine Verbindung"
        }
    }
}

/// The ring per tile (design C), one per state.
enum RingKind: Equatable, Sendable {
    case live                                   // pulse: speaking / listening / transcribing / holds the voice
    case spin(fraction: Double, period: Double) // rotating arc: working (fast), queued (slow)
    case background(jobs: Int)                  // a dot per job on the orbit
    case countdown                              // draining arc: a pause with an end
    case parked, idle, stopped

    init(_ s: Session) {
        if s.isLive { self = .live; return }
        switch s.state {
        case .working: self = .spin(fraction: 0.28, period: 1.6)
        case .queued: self = .spin(fraction: 0.12, period: 4)
        case .background: self = .background(jobs: s.tasks.count)
        case .waiting where s.until != nil: self = .countdown
        case .parked: self = .parked
        case .idle: self = .idle
        default: self = .stopped
        }
    }

    var isAnimated: Bool {
        switch self {
        case .live, .spin, .background, .countdown: true
        case .parked, .idle, .stopped: false
        }
    }
}

/// The overview's order: what needs Sir first, then what works, then what rests; newest change
/// first inside each (the host's `/sessions` order, Sessions.group on the Mac).
enum SessionGroup: Int, CaseIterable, Comparable {
    case input, working, paused, stopped

    init(_ s: Session) {
        switch s.state {
        case .stopped: self = .stopped
        case _ where s.voice || s.callback != nil: self = .input
        case .speaking, .listening, .transcribing, .queued: self = .input
        case .working, .background: self = .working
        default: self = .paused
        }
    }

    var title: String {
        switch self {
        case .input: "BRAUCHT INPUT"
        case .working: "ARBEITET"
        case .paused: "ANGEHALTEN"
        case .stopped: "BEENDET"
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    static func sorted(_ list: [Session]) -> [Session] {
        list.enumerated().sorted { x, y in
            let (a, b) = (x.element, y.element)
            if SessionGroup(a) != SessionGroup(b) { return SessionGroup(a) < SessionGroup(b) }
            if a.since != b.since { return a.since > b.since }
            return x.offset < y.offset
        }.map(\.element)
    }
}
