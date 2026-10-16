import Foundation
import Security

// The iPhone connection (docs/IPHONE.md, relay protocol v1). Parley dials OUT to a small relay
// on Cloudflare as the host of one room — no port opens on the Mac. It mirrors GET /sessions to
// the phones in the room and takes a phone's `resume` down the POST /resume path.

// The relay settings in credentials.json. relayUrl empty = the feature is off.
struct RelayConfig: Equatable {
    var url: String       // relay base URL, normalized (no trailing slash)
    var room: String      // 16 random bytes, base64url
    var secret: String    // 32 random bytes, base64url — the relay keeps only its sha256

    init(url: String, room: String, secret: String) {
        self.url = RelayLink.normalize(url)
        self.room = room
        self.secret = secret
    }

    var isComplete: Bool { RelayLink.socketBase(url) != nil && !room.isEmpty && !secret.isEmpty }

    static func load() -> RelayConfig {
        RelayConfig(url: Keychain.get(.relayUrl) ?? "", room: Keychain.get(.relayRoom) ?? "",
                    secret: Keychain.get(.relaySecret) ?? "")
    }

    // "iPhone verbinden…": nil while no (http/https) relayUrl is set; else the settings, with
    // room + secret created once — together, since a room is claimed by its first secret.
    static func pair() -> RelayConfig? {
        var c = load()
        guard RelayLink.socketBase(c.url) != nil else { return nil }
        if c.room.isEmpty || c.secret.isEmpty {
            c.room = RelayLink.token(bytes: 16)
            c.secret = RelayLink.token(bytes: 32)
            Keychain.set(c.room, for: .relayRoom)
            Keychain.set(c.secret, for: .relaySecret)
            Log.write("relay: created room + secret for pairing")
        }
        return c
    }
}

// Pairing link, pairing page and socket URL — pure (1:1 with RelayLink on Windows).
enum RelayLink {
    // RFC 3986 unreserved; everything else is percent-encoded (= Uri.EscapeDataString).
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }

    // Trimmed, no trailing slash; a bare host gets https://.
    static func normalize(_ url: String) -> String {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        if !u.isEmpty, !u.contains("://") { u = "https://" + u }
        return u
    }

    // parley://pair?u=<relay>&r=<room>&k=<secret> — what the iPhone scans.
    static func pairing(_ c: RelayConfig) -> String {
        "parley://pair?u=\(encode(c.url))&r=\(encode(c.room))&k=\(encode(c.secret))"
    }

    // <relay>/pair#<pairing link>: the relay's page draws the QR code from the fragment, which
    // the browser never sends — the secret never reaches the relay in a request.
    static func pairPage(_ c: RelayConfig) -> URL? {
        URL(string: "\(c.url)/pair#\(encode(pairing(c)))")
    }

    // wss://<relay>/v1/room/<room>?role=host (ws:// for a plain-http dev relay).
    static func socket(_ c: RelayConfig) -> URL? {
        socketBase(c.url).flatMap { URL(string: "\($0)/v1/room/\(encode(c.room))?role=host") }
    }

    // The relay URL with its ws scheme; nil unless http(s).
    static func socketBase(_ url: String) -> String? {
        let lower = url.lowercased()
        if lower.hasPrefix("https://") { return "wss://" + url.dropFirst(8) }
        if lower.hasPrefix("http://") { return "ws://" + url.dropFirst(7) }
        return nil
    }

    // `n` bytes from the system CSPRNG, base64url without padding.
    static func token(bytes n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        let status = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")   // never a weak secret
        return base64url(Data(bytes))
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// Relay frames: UTF-8 JSON text, the type in `t`.
enum RelayFrame {
    // `sessions`: the GET /sessions object with `t` and `at` (host clock, epoch ms) spliced in
    // front — the registry's own bytes, not re-encoded. nil unless `json` is an object.
    static func sessions(_ json: String, at: Date) -> String? {
        let body = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix("{"), body.hasSuffix("}") else { return nil }
        let rest = body.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        let head = #"{"t":"sessions","at":\#(Int64((at.timeIntervalSince1970 * 1000).rounded()))"#
        return head + (rest == "}" ? "" : ",") + rest
    }

    // A phone's frame: `resume` takes the POST /resume path; `hello`, the relay's `pong` and
    // unknown types are ignored (forward compatible).
    static func dispatch(_ text: String, resume: (String) -> Void) {
        struct Frame: Decodable { let t: String?; let id: String? }
        guard let f = try? JSONDecoder().decode(Frame.self, from: Data(text.utf8)),
              f.t == "resume", let id = f.id, !id.isEmpty else { return }
        resume(id)
    }
}

// When the overview goes out: on change (compared as the registry's JSON, so `at` never
// counts), else at least every 10 s. reset() after a reconnect sends the current state at once.
struct RelaySync {
    static let heartbeat: TimeInterval = 10
    private var last: String?
    private var lastAt = Date.distantPast

    mutating func due(_ json: String, at now: Date) -> Bool {
        // ½ s slack so the 2 s check tick can't slip a heartbeat to 12 s.
        guard json != last || now.timeIntervalSince(lastAt) >= Self.heartbeat - 0.5 else { return false }
        last = json
        lastAt = now
        return true
    }

    mutating func reset() { last = nil }
}

// The relay WebSocket, behind a seam so tests need no network.
protocol RelaySocket: AnyObject, Sendable {
    func send(_ text: String, completion: @escaping @Sendable ((any Error)?) -> Void)
    func receive(_ handler: @escaping @Sendable (Result<String?, any Error>) -> Void)   // nil = binary frame
    func close()
}

// The host's one connection to its room: reconnects with capped exponential backoff (1 s →
// 30 s), pings every 25 s (the relay answers `pong` itself), checks the overview every 2 s and
// sends it on change / every 10 s, and hands a phone's `resume` on. `onState` reports reachability.
// ponytail: @unchecked Sendable — all state lives on `queue`; onState is set once before start().
final class RelayClient: @unchecked Sendable {
    static let tickEvery: TimeInterval = 2
    static let pingEvery: TimeInterval = 25
    static let silentLimit: TimeInterval = 60   // nothing from the relay (not even a pong) → dead link
    static let maxBackoff: TimeInterval = 30

    static func nextBackoff(_ b: TimeInterval) -> TimeInterval { min(b * 2, maxBackoff) }

    let config: RelayConfig
    var onState: (@Sendable (Bool) -> Void)?   // true = connected; fired on the relay queue, on change

    private let request: URLRequest
    private let sessions: @Sendable () -> String
    private let resume: @Sendable (String) -> Void
    private let now: @Sendable () -> Date
    private let connect: @Sendable (URLRequest) -> any RelaySocket
    private let log: @Sendable (String) -> Void
    private let queue: DispatchQueue

    private var running = false
    private var socket: (any RelaySocket)?
    private var generation = 0        // per connection: late callbacks of an old one are dropped
    private var connected = false
    private var backoff: TimeInterval = 1
    private var sync = RelaySync()
    private var timer: DispatchSourceTimer?
    private var lastPing = Date.distantPast
    private var lastInbound = Date.distantPast

    // nil unless the config is complete (http(s) relayUrl, room, secret).
    init?(config: RelayConfig, sessions: @escaping @Sendable () -> String,
          resume: @escaping @Sendable (String) -> Void,
          now: @escaping @Sendable () -> Date = { Date() },
          connect: @escaping @Sendable (URLRequest) -> any RelaySocket = { URLSessionRelaySocket($0) },
          log: @escaping @Sendable (String) -> Void = { Log.write($0) },
          queue: DispatchQueue = DispatchQueue(label: "de.developaway.parley.relay")) {
        guard config.isComplete, let url = RelayLink.socket(config) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(config.secret)", forHTTPHeaderField: "Authorization")
        self.config = config
        self.request = req
        self.sessions = sessions
        self.resume = resume
        self.now = now
        self.connect = connect
        self.log = log
        self.queue = queue
    }

    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + Self.tickEvery, repeating: Self.tickEvery)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
            self.open()
        }
    }

    func stop() {
        queue.async {
            guard self.running else { return }
            self.running = false
            self.timer?.cancel()
            self.timer = nil
            self.drop()
            self.log("relay: stopped")
        }
    }

    // MARK: - on `queue`

    private func open() {
        guard running, socket == nil else { return }
        generation += 1
        let gen = generation
        let s = connect(request)
        socket = s
        sync.reset()
        lastPing = now()
        lastInbound = now()
        receive(s, gen)
        push()
    }

    // Every 2 s: the keepalive ping (and dead-link check) every 25 s, the overview when due.
    // Internal for tests.
    func tick() {
        guard socket != nil else { return }
        let t = now()
        if t.timeIntervalSince(lastPing) >= Self.pingEvery {
            guard t.timeIntervalSince(lastInbound) <= Self.silentLimit else { fail(generation, RelayError.silent); return }
            lastPing = t
            send("ping")
        }
        push()
    }

    private func push() {
        let json = sessions()
        let t = now()
        guard sync.due(json, at: t), let frame = RelayFrame.sessions(json, at: t) else { return }
        send(frame)
    }

    private func receive(_ s: any RelaySocket, _ gen: Int) {
        s.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation else { return }
                switch result {
                case .success(let text):
                    self.lastInbound = self.now()
                    if let text { RelayFrame.dispatch(text, resume: self.resume) }
                    self.receive(s, gen)
                case .failure(let error):
                    self.fail(gen, error)
                }
            }
        }
    }

    private func send(_ text: String) {
        guard let s = socket else { return }
        let gen = generation
        s.send(text) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation else { return }
                if let error { self.fail(gen, error) } else { self.opened() }
            }
        }
    }

    // A send went through → the handshake succeeded.
    private func opened() {
        guard !connected else { return }
        connected = true
        backoff = 1
        log("relay: connected to \(request.url?.host ?? "?")")
        onState?(true)
    }

    private func fail(_ gen: Int, _ error: any Error) {
        guard gen == generation, socket != nil else { return }
        let wasUp = connected
        drop()
        let delay = backoff
        backoff = Self.nextBackoff(backoff)
        // Quiet once at the cap: an offline Mac would log every 30 s otherwise.
        if wasUp || delay < Self.maxBackoff {
            log("relay: \(wasUp ? "disconnected" : "unreachable") (\(error.localizedDescription)) — retry in \(Int(delay)) s")
        }
        if wasUp { onState?(false) }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.open() }
    }

    private func drop() {
        socket?.close()
        socket = nil
        generation += 1
        connected = false
    }
}

enum RelayError: LocalizedError {
    case http(Int), silent
    var errorDescription: String? {
        switch self {
        case .http(let status): "HTTP \(status)"
        case .silent: "no answer from the relay for \(Int(RelayClient.silentLimit)) s"
        }
    }
}

// URLSessionWebSocketTask as the RelaySocket.
final class URLSessionRelaySocket: RelaySocket {
    private let task: URLSessionWebSocketTask

    init(_ request: URLRequest) {
        task = URLSession.shared.webSocketTask(with: request)
        task.resume()
    }

    func send(_ text: String, completion: @escaping @Sendable ((any Error)?) -> Void) {
        task.send(.string(text), completionHandler: completion)
    }

    func receive(_ handler: @escaping @Sendable (Result<String?, any Error>) -> Void) {
        let task = self.task
        task.receive { result in
            switch result {
            case .success(.string(let text)): handler(.success(text))
            case .success: handler(.success(nil))   // binary: reserved for audio (stage 2)
            case .failure(let error):
                // A refused handshake (401 wrong secret, …) reads better as its status.
                let status = (task.response as? HTTPURLResponse)?.statusCode ?? 101
                handler(.failure(status == 101 ? error : RelayError.http(status)))
            }
        }
    }

    func close() { task.cancel(with: .goingAway, reason: nil) }
}
