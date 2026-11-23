import Foundation
import Network

// Protocol v10 (docs/IPHONE.md → Desktops): a VNC session tunnelled through the relay, end-to-end
// sealed like every other frame. The phone opens a channel to one of the host's `vnc` desktops;
// the host connects to it (tcp:// = plain RFB, ws:// = websockify) and passes the RFB bytes both
// ways as base64 in `vnc` frames. 1:1 with Desktops on Windows/Linux.

enum VncFrame: Equatable, Sendable {
    case open(ch: String, desktop: String)
    case data(ch: String, Data)
    case close(ch: String)

    static let chunk = 48 * 1024   // RFB bytes per host → phone frame

    /// 8–32 chars of [A-Za-z0-9].
    static func validChannel(_ ch: String) -> Bool {
        (8...32).contains(ch.count) && ch.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    /// A phone's `vnc` frame (already decoded JSON); nil when malformed.
    static func parse(_ f: [String: Any]) -> VncFrame? {
        guard let ch = f["ch"] as? String, validChannel(ch) else { return nil }
        switch f["op"] as? String {
        case "open":
            guard let d = f["desktop"] as? String, !d.isEmpty else { return nil }
            return .open(ch: ch, desktop: d)
        case "close":
            return .close(ch: ch)
        case nil:
            guard let s = f["d"] as? String, let bytes = Data(base64Encoded: s) else { return nil }
            return .data(ch: ch, bytes)
        default:
            return nil
        }
    }

    // MARK: host → phone

    private struct Wire: Encodable {
        let t = "vnc"
        var op: String?
        let ch: String
        var ok: Bool?
        var password: String?
        var error: String?
        var d: String?
    }

    private static func encode(_ w: Wire) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(w)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    static func opened(_ ch: String, password: String) -> String { encode(Wire(op: "open", ch: ch, ok: true, password: password)) }
    static func failed(_ ch: String, error: String) -> String { encode(Wire(op: "open", ch: ch, ok: false, error: error)) }
    static func closed(_ ch: String) -> String { encode(Wire(op: "close", ch: ch)) }

    /// RFB bytes as data frames of at most `chunk` bytes each, in order.
    static func data(_ ch: String, _ bytes: Data) -> [String] {
        stride(from: 0, to: bytes.count, by: chunk).map { start in
            let slice = bytes.subdata(in: bytes.startIndex + start ..< bytes.startIndex + min(start + chunk, bytes.count))
            return encode(Wire(ch: ch, d: slice.base64EncodedString()))
        }
    }
}

// The desktop end of a channel. Callbacks arrive on the queue given to start(); `end` once
// (nil = closed normally, else why), `ready` at most once before it.
protocol DesktopLink: AnyObject, Sendable {
    func start(queue: DispatchQueue, ready: @escaping @Sendable () -> Void, data: @escaping @Sendable (Data) -> Void,
               end: @escaping @Sendable (String?) -> Void)
    func send(_ data: Data)
    func cancel()
}

enum DesktopLinks {
    /// tcp://host:port → NWConnection; ws(s):// → URLSessionWebSocketTask; else nil.
    static func make(_ d: HostDesktop) -> (any DesktopLink)? {
        guard let url = URL(string: d.url), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else { return nil }
        switch scheme {
        case "tcp":
            guard let port = url.port, let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else { return nil }
            return TCPDesktopLink(host: host, port: p)
        case "ws", "wss":
            return WSDesktopLink(url: url)
        default:
            return nil
        }
    }
}

// The phone's channels: at most 2 (a third open closes the oldest), closed after 10 min without
// data from the phone, when the desktop closes, or (closeAll) when the relay link drops.
// ponytail: @unchecked Sendable — all state lives on `queue`.
final class VncTunnels: @unchecked Sendable {
    static let maxChannels = 2
    static let idleLimit: TimeInterval = 10 * 60
    static let unreachable = "Desktop nicht erreichbar."
    static let connectLimit: TimeInterval = 10

    private final class Channel: @unchecked Sendable {
        let ch: String
        let link: any DesktopLink
        var lastIn: Date
        var ready = false
        init(ch: String, link: any DesktopLink, at: Date) { self.ch = ch; self.link = link; self.lastIn = at }
    }

    private let queue = DispatchQueue(label: "de.developaway.parley.vnc")
    private let send: @Sendable (String) -> Void
    private let desktops: @Sendable () -> [String: HostDesktop]
    private let connect: @Sendable (HostDesktop) -> (any DesktopLink)?
    private let now: @Sendable () -> Date
    private var channels: [Channel] = []   // oldest first
    private var timer: DispatchSourceTimer?

    init(send: @escaping @Sendable (String) -> Void,
         desktops: @escaping @Sendable () -> [String: HostDesktop] = { HintsConfig.load().vnc },
         connect: @escaping @Sendable (HostDesktop) -> (any DesktopLink)? = { DesktopLinks.make($0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.send = send
        self.desktops = desktops
        self.connect = connect
        self.now = now
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in self?.sweep() }
        t.resume()
        timer = t
    }

    deinit { timer?.cancel() }

    func handle(_ f: VncFrame) { queue.async { self.handleOnQueue(f) } }

    // The relay link dropped: every channel goes (nothing to tell the phone through).
    func closeAll() {
        queue.async {
            guard !self.channels.isEmpty else { return }
            Log.write("vnc: relay gone — \(self.channels.count) channel(s) closed")
            for c in self.channels { c.link.cancel() }
            self.channels.removeAll()
        }
    }

    // For tests: runs on the queue and waits.
    func sync<T>(_ body: () -> T) -> T { queue.sync(execute: body) }
    var count: Int { queue.sync { channels.count } }

    // MARK: - on `queue`

    func handleOnQueue(_ f: VncFrame) {
        switch f {
        case .open(let ch, let name):
            guard let d = desktops()[name] else { send(VncFrame.failed(ch, error: "Diesen Desktop gibt es hier nicht.")); return }
            guard !channels.contains(where: { $0.ch == ch }) else { return }   // already open
            guard let link = connect(d) else { send(VncFrame.failed(ch, error: Self.unreachable)); return }
            while channels.count >= Self.maxChannels {
                let oldest = channels.removeFirst()
                oldest.link.cancel()
                send(VncFrame.closed(oldest.ch))
                Log.write("vnc: \(oldest.ch) closed for a new one")
            }
            let c = Channel(ch: ch, link: link, at: now())
            channels.append(c)
            Log.write("vnc: \(ch) → \(name)")
            let send = self.send
            let password = d.password
            link.start(queue: queue, ready: { [weak self, weak c] in
                guard let self, let c, self.alive(c), !c.ready else { return }
                c.ready = true
                send(VncFrame.opened(ch, password: password))
            }, data: { [weak self, weak c] bytes in
                guard let self, let c, self.alive(c) else { return }
                for frame in VncFrame.data(ch, bytes) { send(frame) }
            }, end: { [weak self, weak c] why in
                guard let self, let c, self.alive(c) else { return }
                _ = self.remove(ch)
                Log.write("vnc: \(ch) ended by the desktop\(why.map { " (\($0))" } ?? "")")
                send(c.ready ? VncFrame.closed(ch) : VncFrame.failed(ch, error: Self.unreachable))
            })
            queue.asyncAfter(deadline: .now() + Self.connectLimit) { [weak self, weak c] in
                guard let self, let c, self.alive(c), !c.ready else { return }
                _ = self.remove(ch)
                c.link.cancel()
                send(VncFrame.failed(ch, error: Self.unreachable))
            }
        case .data(let ch, let bytes):
            guard let c = channels.first(where: { $0.ch == ch }) else { return }   // not (or no longer) ours
            c.lastIn = now()
            c.link.send(bytes)
        case .close(let ch):
            if let c = remove(ch) {
                c.link.cancel()
                Log.write("vnc: \(ch) closed by the phone")
            }
        }
    }

    // Every 30 s: a channel without data from the phone for 10 min is closed.
    func sweep() {
        let t = now()
        for c in channels where t.timeIntervalSince(c.lastIn) >= Self.idleLimit {
            _ = remove(c.ch)
            c.link.cancel()
            send(VncFrame.closed(c.ch))
            Log.write("vnc: \(c.ch) idle for \(Int(Self.idleLimit / 60)) min — closed")
        }
    }

    private func alive(_ c: Channel) -> Bool { channels.contains { $0 === c } }

    private func remove(_ ch: String) -> Channel? {
        guard let i = channels.firstIndex(where: { $0.ch == ch }) else { return nil }
        return channels.remove(at: i)
    }
}

// tcp://host:port — a plain RFB server (e.g. macOS Screen Sharing).
final class TCPDesktopLink: DesktopLink, @unchecked Sendable {
    private let conn: NWConnection
    private var finished = false   // on the start queue

    init(host: String, port: NWEndpoint.Port) {
        conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
    }

    func start(queue: DispatchQueue, ready: @escaping @Sendable () -> Void, data: @escaping @Sendable (Data) -> Void,
               end: @escaping @Sendable (String?) -> Void) {
        let finish: @Sendable (String?) -> Void = { [weak self] why in
            guard let self, !self.finished else { return }
            self.finished = true
            self.conn.cancel()
            end(why)
        }
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                ready()
                self?.receive(data, finish)
            case .waiting(let e), .failed(let e): finish(e.localizedDescription)
            case .cancelled: finish(nil)
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func receive(_ data: @escaping @Sendable (Data) -> Void, _ finish: @escaping @Sendable (String?) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: VncFrame.chunk) { [weak self] content, _, complete, error in
            if let content, !content.isEmpty { data(content) }
            if let error { finish(error.localizedDescription) } else if complete { finish(nil) } else { self?.receive(data, finish) }
        }
    }

    func send(_ data: Data) { conn.send(content: data, completion: .contentProcessed { _ in }) }
    func cancel() { conn.cancel() }
}

// ws://…/websockify — RFB in binary WebSocket messages.
final class WSDesktopLink: NSObject, DesktopLink, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let url: URL
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var queue: DispatchQueue?
    private var onReady: (@Sendable () -> Void)?
    private var onData: (@Sendable (Data) -> Void)?
    private var onEnd: (@Sendable (String?) -> Void)?
    private var finished = false   // on `queue`

    init(url: URL) { self.url = url }

    func start(queue: DispatchQueue, ready: @escaping @Sendable () -> Void, data: @escaping @Sendable (Data) -> Void,
               end: @escaping @Sendable (String?) -> Void) {
        self.queue = queue
        onReady = ready
        onData = data
        onEnd = end
        let ops = OperationQueue()
        ops.underlyingQueue = queue
        ops.maxConcurrentOperationCount = 1
        let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: ops)
        let t = s.webSocketTask(with: url, protocols: ["binary"])   // as noVNC asks websockify
        t.maximumMessageSize = 16 * 1024 * 1024
        session = s
        task = t
        t.resume()
        receive()
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue?.async {
                switch result {
                case .success(.data(let d)): self.onData?(d); self.receive()
                case .success(.string(let s)): self.onData?(Data(s.utf8)); self.receive()
                case .success: self.receive()
                case .failure(let e): self.finish(e.localizedDescription)
                }
            }
        }
    }

    private func finish(_ why: String?) {
        guard !finished else { return }
        finished = true
        let end = onEnd
        cancel()
        end?(why)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onReady?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        finish(error?.localizedDescription)
    }

    func send(_ data: Data) { task?.send(.data(data)) { _ in } }

    // Also breaks the session ↔ delegate cycle.
    func cancel() {
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        onReady = nil
        onData = nil
        onEnd = nil
    }
}
