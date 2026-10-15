import Foundation
import Network

// Loopback control server on 127.0.0.1:8787. Receives POSTs from the Claude Code
// Stop / SessionStart hooks. All work runs on one serial queue.
//
// Terminal-agnostic reply model: the Stop hook LONG-POLLS `POST /turn` and blocks.
// The app speaks the summary, records the user's voice, transcribes it, and returns
// the transcript as the HTTP response. The hook then feeds that transcript back into
// the Claude session via a `{"decision":"block"}` stop decision — no tmux, no
// keystroke injection, works in Warp / iTerm / any terminal.
//
// ponytail: @unchecked Sendable — every mutation runs on `queue`; callbacks are set
// once at startup before start().
final class ControlServer: @unchecked Sendable {
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "de.developaway.parley.server")
    private var listener: NWListener?

    // UI notify when a turn starts being spoken (fired on the server queue).
    var onTurn: ((TurnPayload) -> Void)?
    var onReady: ((ReadyPayload) -> Void)?
    var onQueued: ((TurnPayload) -> Void)?   // a turn parked behind the active one
    var onParked: (([ParkedInfo]) -> Void)?  // list of resumable (paused) sessions changed
    // The pipeline: speak + record + transcribe, then call the completion with the
    // transcribed reply. `park` keeps the session alive & resumable (see /wake). If nil,
    // /turn answers empty.
    var replyProvider: ((TurnPayload, @escaping (TurnReply) -> Void) -> Void)?

    // Serialize turns: only one is spoken/recorded at a time. Others wait (their hook
    // connections stay open) and drain FIFO.
    private var replyQueue: [(TurnPayload, (TurnReply) -> Void)] = []
    private var replyActive = false

    // Parked (paused-but-resumable) sessions. Their Stop hook short-polls /wake; we hand
    // back a pending instruction to wake them — no keystrokes needed. Keyed by session key.
    private struct Parked { var label: String; var project: String; var cwd: String; var pending: String?; var lastSeen: Date }
    private var parked: [String: Parked] = [:]

    // Every session and its state (GET /sessions, POST /resume, the announcement).
    let sessions: SessionRegistry

    // What the tray / menu / POST /resume hand a parked session to continue.
    static let resumeInstruction = "Wir machen weiter."

    // Sessions are keyed by the agent's session_id; the tmux pane only as a fallback.
    static func sessionKey(session: String, pane: String) -> String { session.isEmpty ? pane : session }
    static func sessionKey(_ turn: TurnPayload) -> String { sessionKey(session: turn.session_id, pane: turn.tmux_pane) }

    init(port: UInt16 = 8787, sessions: SessionRegistry = SessionRegistry()) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.sessions = sessions
    }

    func start() {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: port) else {
            NSLog("Parley: failed to open listener on \(port)")
            return
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
        listener = l
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let chunk { buf.append(chunk) }
            if let req = HTTPParse.parse(buf) {
                self.route(req, on: conn)
                return
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.receive(conn, buffer: buf)
        }
    }

    private func route(_ req: HTTPRequest, on conn: NWConnection) {
        // /turn is answered asynchronously once the voice reply is transcribed.
        if req.method == "POST", req.path == "/turn" {
            guard let turn = Contract.decodeTurn(req.body) else {
                send(400, #"{"ok":false,"error":"bad turn payload"}"#, on: conn)
                return
            }
            sessions.queued(id: Self.sessionKey(turn), label: turn.label ?? "", project: turn.project)
            enqueueReply(turn) { [weak self] reply in
                self?.send(200, Self.turnJSON(reply), on: conn)
            }
            return
        }
        let (status, json) = handle(req)
        send(status, json, on: conn)
    }

    // /wake — a parked session's Stop hook short-polls this. Answer immediately with any
    // pending resume instruction (consuming it), else empty; either way (re)register so the
    // session stays listed as resumable.
    private func wakePoll(_ body: Data) -> String {
        let w = Contract.decodeWake(body)
        let key = Self.sessionKey(session: w?.session_id ?? "", pane: w?.tmux_pane ?? "")
        var p = parked[key] ?? Parked(label: "", project: "", cwd: "", pending: nil, lastSeen: Date())
        p.label = w?.spokenLabel ?? p.label
        p.project = w?.project ?? p.project
        p.cwd = w?.cwd ?? p.cwd
        p.lastSeen = Date()
        let pending = p.pending
        p.pending = nil
        parked[key] = p
        sessions.wakePoll(id: key, label: w?.label ?? "", project: w?.project ?? "", resumed: pending != nil)
        pruneParked()
        notifyParked()
        return Self.turnJSON(TurnReply(transcript: pending ?? "", park: false))
    }

    // MARK: - parked-session control (called from AppController)

    // Queue an instruction for a parked session; its next /wake poll (≤3s) picks it up and
    // injects it as the next turn, resuming the session. No-op if the id is unknown.
    func wake(id: String, instruction: String) {
        queue.async {
            guard var p = self.parked[id] else { return }
            p.pending = instruction
            p.lastSeen = Date()
            self.parked[id] = p
        }
    }

    func parkedList() -> [ParkedInfo] {
        queue.sync { livingParked() }
    }

    // True if any session besides `id` is alive (any state but stopped) → announce the turn.
    func othersAlive(except id: String) -> Bool {
        queue.sync { sessions.othersAlive(except: id) }
    }

    private func livingParked() -> [ParkedInfo] {
        let cutoff = Date().addingTimeInterval(-90)
        return parked.filter { $0.value.lastSeen > cutoff }
            .map { ParkedInfo(id: $0.key, label: $0.value.label, project: $0.value.project) }
            .sorted { $0.label < $1.label }
    }

    private func pruneParked() {
        let cutoff = Date().addingTimeInterval(-90)
        parked = parked.filter { $0.value.lastSeen > cutoff }
    }

    private func notifyParked() { onParked?(livingParked()) }

    private func send(_ status: Int, _ json: String, on conn: NWConnection) {
        let data = HTTPParse.response(status: status, json: json)
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - turn serialization

    private func enqueueReply(_ turn: TurnPayload, _ respond: @escaping (TurnReply) -> Void) {
        replyQueue.append((turn, respond))
        if replyActive { onQueued?(turn) }   // parked behind an in-flight turn → show as waiting
        pumpReplies()
    }

    private func pumpReplies() {
        guard !replyActive, !replyQueue.isEmpty else { return }
        guard let provider = replyProvider else {
            // No pipeline wired — answer everything empty so hooks don't hang.
            let waiting = replyQueue; replyQueue.removeAll()
            for (turn, respond) in waiting {
                let reply = TurnReply(transcript: "", park: false)
                sessions.finished(id: Self.sessionKey(turn), reply: reply)
                respond(reply)
            }
            return
        }
        replyActive = true
        let (turn, respond) = replyQueue.removeFirst()
        sessions.activate(id: Self.sessionKey(turn))
        onTurn?(turn)
        provider(turn) { [weak self] reply in
            guard let self else { return }
            self.queue.async {
                self.sessions.finished(id: Self.sessionKey(turn), reply: reply)
                respond(reply)
                self.replyActive = false
                self.pumpReplies()
            }
        }
    }

    private static func turnJSON(_ reply: TurnReply) -> String {
        let esc = reply.transcript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        struct Wire: Encodable { let transcript: String; let park: Bool; let wait: Int; let resume: String }
        let data = try? JSONEncoder().encode(Wire(transcript: reply.transcript, park: reply.park,
                                                  wait: reply.waitSeconds, resume: reply.resume))
        return data.flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"transcript":"\#(esc)","park":\#(reply.park)}"#
    }

    // MARK: - synchronous routes (also unit-tested directly)

    func handle(_ req: HTTPRequest) -> (Int, String) {
        switch (req.method, req.path) {
        case ("GET", "/health"):
            return (200, #"{"ok":true}"#)
        case ("GET", "/status"):
            return (200, LiveStatus.json())
        case ("POST", "/turn"):
            // Sync fallback (tests / no live connection): validate + notify only.
            guard let turn = Contract.decodeTurn(req.body) else {
                return (400, #"{"ok":false,"error":"bad turn payload"}"#)
            }
            onTurn?(turn)
            return (200, #"{"ok":true}"#)
        case ("POST", "/ready"):
            guard let ready = Contract.decodeReady(req.body) else {
                return (400, #"{"ok":false,"error":"bad ready payload"}"#)
            }
            onReady?(ready)
            return (200, #"{"ok":true}"#)
        case ("POST", "/wake"):
            return (200, wakePoll(req.body))
        case ("POST", "/presence"):
            // The mod's heartbeat from every Claude Code session (~5 s).
            guard let p = Contract.decodePresence(req.body), !p.session_id.isEmpty else {
                return (400, #"{"ok":false,"error":"bad presence payload"}"#)
            }
            let project = p.project?.isEmpty == false ? p.project! : ((p.cwd ?? "") as NSString).lastPathComponent
            sessions.presence(id: p.session_id, label: p.label ?? "", project: project, working: p.state == "working")
            return (200, "{}")
        case ("GET", "/sessions"):
            return (200, sessions.json())
        case ("POST", "/resume"):
            // Same as the tray's "Fortsetzen", addressed by session_id. Only a parked session
            // can be resumed; its next /wake poll (≤3 s) picks the instruction up.
            guard let id = Contract.decodeResume(req.body)?.id, sessions.isParked(id) else {
                return (404, #"{"ok":false}"#)
            }
            var p = parked[id] ?? Parked(label: "", project: "", cwd: "", pending: nil, lastSeen: Date())
            p.pending = Self.resumeInstruction
            p.lastSeen = Date()
            parked[id] = p
            return (200, #"{"ok":true}"#)
        default:
            return (404, #"{"ok":false,"error":"not found"}"#)
        }
    }
}

// Live turn state for GET /status: the phase of the turn being voiced and a rolling window
// of audio levels (TTS out while speaking, mic in while listening), 0…1. Polled ~10×/s by
// the Claude Code mod to draw a real level meter. Written from audio threads → locked.
enum LiveStatus {
    nonisolated(unsafe) private static var phase = "idle"
    nonisolated(unsafe) private static var session = ""
    nonisolated(unsafe) private static var levels = [Float](repeating: 0, count: 32)
    private static let lock = NSLock()

    static func begin(session id: String) { lock.withLock { session = id; phase = "speaking" } }
    static func set(phase p: String) { lock.withLock { phase = p } }
    static func push(_ level: Float) { lock.withLock { levels.removeFirst(); levels.append(max(0, min(1, level))) } }
    static func currentPhase() -> String { lock.withLock { phase } }

    static func json() -> String {
        lock.withLock {
            struct Wire: Encodable { let phase: String; let session: String; let levels: [Float] }
            let rounded = levels.map { ($0 * 100).rounded() / 100 }
            let data = try? JSONEncoder().encode(Wire(phase: phase, session: session, levels: rounded))
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? #"{"phase":"idle"}"#
        }
    }
}
