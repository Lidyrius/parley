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

    var spokenLabel: String { (label?.isEmpty == false ? label : nil) ?? project }
    var wantsListen: Bool { listen ?? true }
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

// POST /presence — the Claude Code mod's heartbeat (~5 s per session). state: working|idle.
struct PresencePayload: Codable, Equatable {
    var session_id: String
    var label: String?
    var project: String?
    var cwd: String?
    var state: String?
}

// POST /resume — wake a parked session by its session_id (as listed by GET /sessions).
struct ResumePayload: Codable, Equatable { var id: String }

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
}
