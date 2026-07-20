import Foundation

// Wire payloads from the Claude Code plugin hooks (see CONTRACT.md).

struct TurnPayload: Codable, Equatable {
    var event: String
    var session_id: String
    var cwd: String
    var project: String
    var tmux_pane: String
    var speak: String
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
}
