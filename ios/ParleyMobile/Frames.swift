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
    var callback: Double?           // its call was put off: Parley rings at (ms), 0 = waits for your call back
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

/// A Wiedervorlage on the host (docs/IPHONE.md): for whom, what, and when — a time (host ms) or
/// once another session is done.
struct ReminderRow: Identifiable, Equatable, Sendable {
    var id: String
    var text = ""
    var to = ""                     // a session's name, or "Sir"
    var at: Double?
    var after: String?
}

/// A `sessions` frame: the host's `/sessions` JSON plus `at`, the host clock when it was sent.
struct Snapshot: Equatable, Sendable {
    var sessions: [Session] = []
    var today: Today?
    var reminders: [ReminderRow] = []
    var snapshots: [SavedSnapshot] = []
    var at: Double?
}

/// v6: a set of sessions kept under a name (the "Snapshots" sheet) — opened again in one go.
struct SavedSnapshot: Identifiable, Hashable, Sendable, Decodable {
    struct Item: Hashable, Sendable, Decodable {
        var id: String
        var name: String
        var cwd: String
    }
    var id: String
    var name: String
    var at: Double                  // epoch ms, host clock
    var sessions: [Item]
}

/// v6: what opening a snapshot did to one of its sessions (`snapshot` frame from the host).
struct SnapshotResult: Equatable, Sendable, Decodable {
    enum Kind: String, Sendable { case running, resumed, started, missing }
    var id: String
    var name: String
    var result: String
    var kind: Kind? { Kind(rawValue: result) }
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

/// Live captions for one spoken line (`caption` frame, v3): its words and when each starts,
/// in seconds from the line's first audio frame.
struct Caption: Hashable, Sendable {
    var words: [String]
    var starts: [Double]
    var end: Double
    /// Nothing follows on this call (the turn's last line, no listening, no other turn waiting).
    var last = false

    /// The word being spoken `t` seconds in (-1 before the first).
    func index(at t: Double) -> Int { (starts.lastIndex { $0 <= t }) ?? -1 }

    /// The subtitle line (`chunks`) being spoken `t` seconds in — the first before it starts.
    func line(at t: Double) -> String? {
        let i = max(0, index(at: t))
        return chunks.first { $0.contains(i) }.map { words[$0].joined(separator: " ") }
    }

    /// Subtitle lines: up to a sentence end, or a comma once there are 7 words, at most 12.
    var chunks: [Range<Int>] {
        var out: [Range<Int>] = []
        var from = 0
        for (i, w) in words.enumerated() {
            let n = i + 1 - from
            let last = w.last
            if last.map({ ".!?…".contains($0) }) == true || (n >= 7 && last.map({ ",;:–—".contains($0) }) == true) || n >= 12 {
                out.append(from..<(i + 1))
                from = i + 1
            }
        }
        if from < words.count { out.append(from..<words.count) }
        return out
    }
}

/// One slide of a spoken line (`slides` frame, docs/CALL-SLIDES.md): shown from `at` seconds
/// into the line. Kinds: image (pixels in an `image` frame keyed by `id`), chart, metric, text.
struct Slide: Identifiable, Equatable, Sendable, Decodable {
    var id: String
    var at: Double
    var kind: String
    var title: String?
    var text: String?
    var chart: String?
    var labels: [String]?
    var values: [Double]?
    var unit: String?
    var metric: String?
    var note: String?

    /// The slide due `t` seconds into the line: the last one whose time has come.
    static func current(_ slides: [Slide], at t: Double) -> Slide? {
        slides.filter { $0.at <= t }.max { $0.at < $1.at }
    }
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
    /// v3: live captions for the line about to play.
    case caption(Caption)
    /// v3: slides for the line about to play.
    case slides([Slide])
    /// v4: a colour palette made by voice (the Zentrale researched it) — save it and switch to it.
    case palette(Palette)
    /// v6: the host opened snapshot `id` — what became of each session.
    case snapshotOpened(id: String, results: [SnapshotResult])
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
        case "slides":
            guard let w = try? decoder.decode(SlidesWire.self, from: data) else { return .other(head.t) }
            return .slides(w.items.items)
        case "palette":
            guard let w = try? decoder.decode(PaletteWire.self, from: data), let p = w.palette else { return .other(head.t) }
            return .palette(p)
        case "caption":
            guard let w = try? decoder.decode(CaptionWire.self, from: data), w.words.count == w.at.count, !w.words.isEmpty
            else { return .other(head.t) }
            return .caption(Caption(words: w.words, starts: w.at, end: w.end, last: w.last ?? false))
        case "snapshot":
            guard let w = try? decoder.decode(SnapshotWire.self, from: data) else { return .other(head.t) }
            return .snapshotOpened(id: w.id, results: w.results.items)
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
    private struct SnapshotWire: Decodable { let id: String; let results: Lossy<SnapshotResult> }
    /// `{"t":"palette","name","note","alwaysDark","colors":{role:["#light","#dark"]}}` — every role
    /// present, else no palette.
    private struct PaletteWire: Decodable {
        let name: String
        let note: String?
        let alwaysDark: Bool?
        let colors: [String: [String]]

        var palette: Palette? {
            func shade(_ role: String) -> Shade? {
                guard let pair = colors[role], pair.count == 2,
                      let l = UInt32(pair[0].replacingOccurrences(of: "#", with: ""), radix: 16),
                      let d = UInt32(pair[1].replacingOccurrences(of: "#", with: ""), radix: 16) else { return nil }
                return Shade(l, d)
            }
            guard !name.isEmpty, let bg = shade("background"), let card = shade("card"), let raised = shade("raised"),
                  let accent = shade("accent"), let waiting = shade("waiting"), let working = shade("working"),
                  let purple = shade("purple"), let idle = shade("idle"), let stopped = shade("stopped"), let red = shade("red")
            else { return nil }
            return Palette(id: "", name: name, note: note ?? "", background: bg, card: card, raised: raised, accent: accent,
                           waiting: waiting, working: working, purple: purple, idle: idle, stopped: stopped, red: red,
                           alwaysDark: alwaysDark ?? false)
        }
    }

    private struct CaptionWire: Decodable { let words: [String]; let at: [Double]; let end: Double; let last: Bool? }
    private struct SlidesWire: Decodable { let items: Lossy<Slide> }

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
    /// Fragerunde: how long an update waits for others still at work (0 = never).
    static func round(seconds: Int) -> String { encode(["t": .s("round"), "seconds": .i(seconds)]) }
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
    /// v4: the Live Activity's push tokens (hex). `start`: its push-to-start token (the host starts
    /// it); `token`: the running activity's update token, "" = none runs (any more).
    static func activityStart(token: String, env: PushEnvironment) -> String {
        encode(["t": .s("activity"), "start": .s(token), "env": .s(env.rawValue)])
    }
    static func activity(token: String?, env: PushEnvironment) -> String {
        encode(["t": .s("activity"), "token": .s(token ?? ""), "env": .s(env.rawValue)])
    }
    /// v4: Sir talks over Parley — stop the line and listen (barge-in).
    static let barge = encode(["t": .s("barge")])
    /// v4: a palette made by voice is saved (the host stops resending it).
    static func paletteSaved(_ name: String) -> String { encode(["t": .s("palette"), "saved": .s(name)]) }
    /// v6: keep the sessions `ids` under `name` (the same name again replaces it); open one; delete one.
    static func snapshotSave(name: String, ids: [String]) -> String {
        encode(["t": .s("snapshot"), "op": .s("save"), "name": .s(name), "ids": .a(ids)])
    }
    static func snapshotOpen(id: String) -> String { encode(["t": .s("snapshot"), "op": .s("open"), "id": .s(id)]) }
    static func snapshotDelete(id: String) -> String { encode(["t": .s("snapshot"), "op": .s("delete"), "id": .s(id)]) }
    /// Can't talk now (on the ringing screen): ring again in `after` s, or nil = I'll call back.
    static func later(after: Int?) -> String {
        after.map { encode(["t": .s("later"), "after": .i($0)]) } ?? encode(["t": .s("later")])
    }

    private enum Value: Encodable {
        case s(String), b(Bool), i(Int), a([String])
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .a(let v): try c.encode(v)
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
    private enum K: String, CodingKey { case id, label, project, state, since, until, callback, voice, resumable, tasks, host, stats }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)  // the one field a tile cannot do without
        label = c.lenient(.label) ?? ""
        project = c.lenient(.project) ?? ""
        state = (c.lenient(.state) as String?).flatMap(SessionState.init(rawValue:)) ?? .idle
        since = c.lenient(.since) ?? 0
        until = c.lenient(.until)
        callback = c.lenient(.callback)
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

extension ReminderRow: Decodable {
    private enum K: String, CodingKey { case id, text, to, at, after }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        text = c.lenient(.text) ?? ""
        to = c.lenient(.to) ?? ""
        at = c.lenient(.at)
        after = c.lenient(.after)
    }
}

extension Snapshot: Decodable {
    private enum K: String, CodingKey { case sessions, today, reminders, snapshots, at }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        sessions = (c.lenient(.sessions) as Lossy<Session>?)?.items ?? []
        today = c.lenient(.today)
        reminders = (c.lenient(.reminders) as Lossy<ReminderRow>?)?.items ?? []
        snapshots = (c.lenient(.snapshots) as Lossy<SavedSnapshot>?)?.items ?? []
        at = c.lenient(.at)
    }
}

extension Date {
    /// Epoch milliseconds, the protocol's time unit.
    var ms: Double { timeIntervalSince1970 * 1000 }
}
