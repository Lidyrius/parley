import Foundation

// Wire payloads from the Claude Code plugin hooks (see CONTRACT.md).

struct TurnPayload: Codable, Equatable {
    var event: String
    var session_id: String
    var cwd: String
    var project: String
    var tmux_pane: String
    var speak: String
    var label: String?    // spoken project name from .parley.json; nil → use project
    var listen: Bool?     // false = speak-only (no mic/pill); nil/true = speak + listen
    var replies: [Reply]? // predicted answers (<reply on="…">), each with its spoken reaction

    var spokenLabel: String { (label?.isEmpty == false ? label : nil) ?? project }
    var wantsListen: Bool { listen ?? true }
}

// A predicted answer to a listen turn: `on` describes it, `say` is spoken the moment the
// user's reply matches it (pre-rendered — no latency); `listen` = `say` asks back, so the
// mic opens again and both answers go to the session.
struct Reply: Codable, Equatable {
    var on: String
    var say: String
    var listen: Bool?
}

// Result of a /turn: the voice reply to inject, and whether the session should PARK
// (stay alive & resumable via /wake) rather than end when the reply is empty.
struct TurnReply {
    var transcript: String
    var park: Bool
    var waitSeconds: Int = 0   // >0 → hook sleeps this long, then injects `resume`
    var resume: String = ""    // prompt fed back to Claude after the wait
}

// A paused-but-resumable session, surfaced to the menu and matched by voice command.
struct ParkedInfo: Identifiable, Equatable { var id: String; var label: String; var project: String }

// A parked hook's /wake poll: the turn's identity without the spoken line (no `event`,
// no `speak` — so it can't decode as a TurnPayload).
struct WakePayload: Codable, Equatable {
    var session_id: String?
    var cwd: String?
    var project: String?
    var tmux_pane: String?
    var label: String?

    var spokenLabel: String { (label?.isEmpty == false ? label : nil) ?? project ?? "" }
}

// POST /presence — the Claude Code mod's heartbeat (~2 s per session).
// state: working | background (turn over, its background tasks still run) | idle.
struct PresencePayload: Codable, Equatable {
    var session_id: String
    var label: String?
    var project: String?
    var cwd: String?
    var state: String?
    var usage: PresenceUsage?
    var tasks: [BackgroundTask]?  // in-flight background tasks (subagents, shell jobs, monitors)
    var host: String?             // the desktop app's id for the session (local_…), for claude:// deep links
}

// One background task as the mod reports it; echoed in GET /sessions rows.
struct BackgroundTask: Codable, Equatable {
    var type: String?             // "subagent", …
    var description: String?
    enum CodingKeys: String, CodingKey { case type, description }
    func encode(to encoder: Encoder) throws {   // explicit nulls, not omitted
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(description, forKey: .description)
    }
}

// What the mod knows about its Claude Code session (all optional). startedAt = epoch ms.
struct PresenceUsage: Codable, Equatable {
    var startedAt: Double?
    var contextPercent: Double?
    var contextTokens: Double?
    var contextWindow: Double?
    var costUsd: Double?          // cumulative for the session
    var rateLimits: [RateLimit]?
}

// One plan limit as the mod reports it; re-emitted as-is in GET /sessions → today.
struct RateLimit: Codable, Equatable {
    var kind: String?             // "five_hour", …
    var percentUsed: Double?
    var resetsAt: String?         // ISO 8601
    enum CodingKeys: String, CodingKey { case kind, percentUsed, resetsAt }
    func encode(to encoder: Encoder) throws {   // explicit: unknown values are null, not omitted
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(percentUsed, forKey: .percentUsed)
        try c.encode(resetsAt, forKey: .resetsAt)
    }
}

// POST /resume — wake a parked session by its session_id (as listed by GET /sessions).
struct ResumePayload: Codable, Equatable { var id: String }

// POST /dispatch — hand a task to the session in a folder (the Zentrale starts projects this way).
// start: launch a session there when none is alive (default true).
struct DispatchPayload: Codable, Equatable {
    var cwd: String?          // optional with `resume` (then the session's own folder)
    var instruction: String?
    var start: Bool?
    var resume: String?       // a past session's id: started as `claude --resume <id>`
}

struct ReadyPayload: Codable, Equatable {
    var event: String
    var session_id: String?
    var cwd: String
    var project: String
    var tmux_pane: String
}

enum Contract {
    static func decodeTurn(_ body: Data) -> TurnPayload? {
        try? JSONDecoder().decode(TurnPayload.self, from: body)
    }
    static func decodeReady(_ body: Data) -> ReadyPayload? {
        try? JSONDecoder().decode(ReadyPayload.self, from: body)
    }
    static func decodeWake(_ body: Data) -> WakePayload? {
        try? JSONDecoder().decode(WakePayload.self, from: body)
    }
    static func decodePresence(_ body: Data) -> PresencePayload? {
        try? JSONDecoder().decode(PresencePayload.self, from: body)
    }
    static func decodeResume(_ body: Data) -> ResumePayload? {
        try? JSONDecoder().decode(ResumePayload.self, from: body)
    }
    static func decodeDispatch(_ body: Data) -> DispatchPayload? {
        try? JSONDecoder().decode(DispatchPayload.self, from: body)
    }
}
