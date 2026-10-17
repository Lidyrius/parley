import Foundation

// Relay protocol v1 + v2 (docs/IPHONE.md). Decoding is lenient on purpose: a host newer or older
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

/// One entry of a session's history (`history` frame, v3): what was typed or said, Claude's
/// text, the line Parley spoke, a tool step, or an image (pixels via an `image` frame).
struct ChatItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case user, voice, assistant, speak, tool, image, other }
    var id: String
    var kind: Kind = .other
    var text: String?
    var fromUser = false            // which side an image sits on
    var at: Double?
    var add: Int?                   // tool: lines a Write / Edit added
    var del: Int?                   //       and removed
}

/// What the host is doing with the call audio (`audio` frame, v2).
enum HostAudio: String, Sendable, CaseIterable {
    case speaking, listening, idle
}

enum Frame: Equatable, Sendable {
    case sessions(Snapshot)
    case peer(host: Bool)
    /// v2: the host's call-audio state. `label` is optional and not in the contract: a host may
    /// name the project it is voicing; without it the phone uses the session that holds the voice.
    case audio(HostAudio, label: String?)
    /// v2: an update wants the phone (the push's twin for a phone that is open in the foreground).
    case ring(label: String?)
    /// v3: a page of a session's history, oldest first: the newest (`before` nil) or the one
    /// right before the item `before`. `more` = there is older history.
    case history(id: String, items: [ChatItem], before: String?, more: Bool)
    /// v3: one image of a history (JPEG); nil = the host could not find it.
    case image(key: String, data: Data?)
    case other(String)              // unknown `t` (or a v2 frame it cannot read): ignored

    /// nil for anything that is not a JSON message with a `t` (e.g. the relay's `pong`).
    static func decode(_ text: String) -> Frame? {
        let data = Data(text.utf8)
        let decoder = JSONDecoder()
        guard let head = try? decoder.decode(Head.self, from: data) else { return nil }
        switch head.t {
        case "sessions": return (try? decoder.decode(Snapshot.self, from: data)).map(Frame.sessions)
        case "peer": return .peer(host: head.host ?? false)
        case "audio":
            guard let state = head.state.flatMap(HostAudio.init(rawValue:)) else { return .other(head.t) }
            return .audio(state, label: head.label.flatMap(Self.clean))
        case "ring": return .ring(label: head.label.flatMap(Self.clean))
        case "history":
            guard let h = try? decoder.decode(HistoryWire.self, from: data) else { return .other(head.t) }
            return .history(id: h.id, items: h.items.items, before: h.before, more: h.more ?? false)
        case "image":
            guard let w = try? decoder.decode(ImageWire.self, from: data) else { return .other(head.t) }
            return .image(key: w.key, data: w.data.flatMap { Data(base64Encoded: $0) })
        default: return .other(head.t)
        }
    }

    /// A label worth showing: trimmed, not empty.
    static func clean(_ label: String) -> String? {
        let s = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private struct HistoryWire: Decodable { let id: String; let items: Lossy<ChatItem>; let before: String?; let more: Bool? }
    private struct ImageWire: Decodable { let key: String; let data: String? }

    private struct Head: Decodable {
        let t: String
        let host: Bool?
        let state: String?
        let label: String?
        enum K: String, CodingKey { case t, host, state, label }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            t = try c.decode(String.self, forKey: .t)
            host = c.lenient(.host)
            state = c.lenient(.state)
            label = c.lenient(.label)
        }
    }
}

/// Phone → host messages (keys sorted, so the text is stable for tests and logs).
enum Outgoing {
    static func hello(device: String) -> String { encode(["t": .s("hello"), "device": .s(device)]) }
    static func resume(id: String) -> String { encode(["t": .s("resume"), "id": .s(id)]) }
    /// v2: the phone's CallKit call connected (`true`) or ended (`false`).
    /// v3: a start asks for Parley's voice at 24 kHz (`down`); the mic stays 16 kHz.
    static func call(started: Bool) -> String {
        started ? encode(["t": .s("call"), "state": .s("start"), "down": .i(24_000)]) : encode(["t": .s("call"), "state": .s("end")])
    }
    /// v2: the wake word was heard while the host was idle.
    static let wake = encode(["t": .s("wake")])
    /// v2: the VoIP push token (hex) and its APNs environment.
    static func push(token: String, env: PushEnvironment) -> String {
        encode(["t": .s("push"), "token": .s(token), "env": .s(env.rawValue)])
    }
    /// v2: Unterwegs-Modus on or off.
    static func away(_ on: Bool) -> String { encode(["t": .s("away"), "on": .b(on)]) }
    /// v3: Stumm — with Unterwegs on, updates come as a notification instead of a call.
    static func silent(_ on: Bool) -> String { encode(["t": .s("silent"), "on": .b(on)]) }
    /// v3: the notification push token (hex).
    static func alertPush(token: String, env: PushEnvironment) -> String {
        encode(["t": .s("push"), "token": .s(token), "env": .s(env.rawValue), "kind": .s("alert")])
    }
    /// v3: a session's history, one of its images, a typed message for it.
    static func history(id: String, before: String? = nil) -> String {
        var body: [String: Value] = ["t": .s("history"), "id": .s(id)]
        if let before { body["before"] = .s(before) }
        return encode(body)
    }
    static func image(id: String, key: String) -> String { encode(["t": .s("image"), "id": .s(id), "key": .s(key)]) }
    static func say(id: String, text: String) -> String { encode(["t": .s("say"), "id": .s(id), "text": .s(text)]) }

    private enum Value: Encodable {
        case s(String), b(Bool), i(Int)
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .s(let v): try c.encode(v)
            case .b(let v): try c.encode(v)
            case .i(let v): try c.encode(v)
            }
        }
    }

    private static func encode(_ body: [String: Value]) -> String {
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

extension ChatItem: Decodable {
    private enum K: String, CodingKey { case id, k, text, who, at, add, del }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (c.lenient(.k) as String?).flatMap(Kind.init(rawValue:)) ?? .other
        text = c.lenient(.text)
        fromUser = (c.lenient(.who) as String?) == "user"
        at = c.lenient(.at)
        add = c.lenient(.add)
        del = c.lenient(.del)
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
