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
struct TurnReply { var transcript: String; var park: Bool }

// A paused-but-resumable session, surfaced to the menu and matched by voice command.
struct ParkedInfo: Identifiable, Equatable { var id: String; var label: String; var project: String }

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
}
