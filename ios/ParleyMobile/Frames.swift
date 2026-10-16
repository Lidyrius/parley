import Foundation

// Relay protocol v1 (docs/IPHONE.md). Decoding is lenient on purpose: a host newer or older
// than this app may add, drop or retype fields, and that must never blank the overview.

enum SessionState: String, Sendable, CaseIterable {
    case speaking, listening, transcribing, queued, working, waiting, parked, background, idle, stopped
}

/// Background work a session left running when its turn ended (subagent, shell, monitor).
struct BackgroundTask: Equatable, Sendable {
    var type = ""
    var description = ""
}

struct Stats: Equatable, Sendable {
    var startedAt: Double?          // epoch ms, host clock
    var contextPercent: Double?
    var costUsd: Double?
    var turns = 0
    var replies = 0
    var lastLine: String?           // last <speak> line voiced for it
}

/// One row of the host's `GET /sessions`. Times are epoch ms on the host's clock.
struct Session: Identifiable, Equatable, Sendable {
    var id: String
    var label = ""
    var project = ""
    var state: SessionState = .idle
    var since: Double = 0
    var until: Double?              // waiting: when the pause runs out
    var voice = false               // holds Parley's voice right now
    var resumable: Bool?
    var tasks: [BackgroundTask] = []
    var host: String?
    var stats: Stats?
}

struct RateLimit: Equatable, Sendable {
    var kind: String?               // "five_hour", "seven_day", …
    var percentUsed: Double?
    var resetsAt: String?           // ISO 8601
}

/// Totals for today across every session.
struct Today: Equatable, Sendable {
    var costUsd: Double = 0
    var turns = 0
    var spokenSeconds: Double = 0
    var rateLimits: [RateLimit] = []
}

/// A `sessions` frame: the host's `/sessions` JSON plus `at`, the host clock when it was sent.
struct Snapshot: Equatable, Sendable {
    var sessions: [Session] = []
    var today: Today?
    var at: Double?
}

enum Frame: Equatable, Sendable {
    case sessions(Snapshot)
    case peer(host: Bool)
    case other(String)              // unknown `t`: ignored (forward compatible)

    /// nil for anything that is not a JSON message with a `t` (e.g. the relay's `pong`).
    static func decode(_ text: String) -> Frame? {
        let data = Data(text.utf8)
        let decoder = JSONDecoder()
        guard let head = try? decoder.decode(Head.self, from: data) else { return nil }
        switch head.t {
        case "sessions": return (try? decoder.decode(Snapshot.self, from: data)).map(Frame.sessions)
        case "peer": return .peer(host: head.host ?? false)
        default: return .other(head.t)
        }
    }

    private struct Head: Decodable {
        let t: String
        let host: Bool?
        enum K: String, CodingKey { case t, host }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            t = try c.decode(String.self, forKey: .t)
            host = c.lenient(.host)
        }
    }
}

/// Phone → host messages.
enum Outgoing {
    static func hello(device: String) -> String { encode(["t": "hello", "device": device]) }
    static func resume(id: String) -> String { encode(["t": "resume", "id": id]) }

    private static func encode(_ body: [String: String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(body)) ?? Data(), as: UTF8.self)
    }
}

// MARK: - Lenient decoding

extension KeyedDecodingContainer {
    /// A missing, null or mistyped field reads as nil instead of failing the whole frame.
    func lenient<T: Decodable>(_ key: Key) -> T? { try? decodeIfPresent(T.self, forKey: key) }
}

/// An array that drops elements it cannot decode instead of failing as a whole.
struct Lossy<T: Decodable>: Decodable {
    var items: [T] = []
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        while !c.isAtEnd {
            if let item = try? c.decode(T.self) { items.append(item) } else if (try? c.decode(Skip.self)) == nil { break }
        }
    }
    private struct Skip: Decodable { init(from decoder: Decoder) throws {} }
}

extension BackgroundTask: Decodable {
    private enum K: String, CodingKey { case type, description }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        type = c.lenient(.type) ?? ""
        description = c.lenient(.description) ?? ""
    }
}

extension Stats: Decodable {
    private enum K: String, CodingKey { case startedAt, contextPercent, costUsd, turns, replies, lastLine }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        startedAt = c.lenient(.startedAt)
        contextPercent = c.lenient(.contextPercent)
        costUsd = c.lenient(.costUsd)
        turns = c.lenient(.turns) ?? 0
        replies = c.lenient(.replies) ?? 0
        lastLine = c.lenient(.lastLine)
    }
}

extension Session: Decodable {
    private enum K: String, CodingKey { case id, label, project, state, since, until, voice, resumable, tasks, host, stats }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)  // the one field a tile cannot do without
        label = c.lenient(.label) ?? ""
        project = c.lenient(.project) ?? ""
        state = (c.lenient(.state) as String?).flatMap(SessionState.init(rawValue:)) ?? .idle
        since = c.lenient(.since) ?? 0
        until = c.lenient(.until)
        voice = c.lenient(.voice) ?? false
        resumable = c.lenient(.resumable)
        tasks = (c.lenient(.tasks) as Lossy<BackgroundTask>?)?.items ?? []
        host = c.lenient(.host)
        stats = c.lenient(.stats)
    }
}

extension RateLimit: Decodable {
    private enum K: String, CodingKey { case kind, percentUsed, resetsAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        kind = c.lenient(.kind)
        percentUsed = c.lenient(.percentUsed)
        resetsAt = c.lenient(.resetsAt)
    }
}

extension Today: Decodable {
    private enum K: String, CodingKey { case costUsd, turns, spokenSeconds, rateLimits }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        costUsd = c.lenient(.costUsd) ?? 0
        turns = c.lenient(.turns) ?? 0
        spokenSeconds = c.lenient(.spokenSeconds) ?? 0
        rateLimits = (c.lenient(.rateLimits) as Lossy<RateLimit>?)?.items ?? []
    }
}

extension Snapshot: Decodable {
    private enum K: String, CodingKey { case sessions, today, at }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        sessions = (c.lenient(.sessions) as Lossy<Session>?)?.items ?? []
        today = c.lenient(.today)
        at = c.lenient(.at)
    }
}

extension Date {
    /// Epoch milliseconds, the protocol's time unit.
    var ms: Double { timeIntervalSince1970 * 1000 }
}
