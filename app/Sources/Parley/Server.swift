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
    var onParked: (([ParkedInfo]) -> Void)?  // list of resumable (parked / idle) sessions changed
    // The pipeline: speak + record + transcribe, then call the completion with the
    // transcribed reply. `park` keeps the session alive & resumable (see /wake). If nil,
    // /turn answers empty.
    var replyProvider: ((TurnPayload, @escaping (TurnReply) -> Void) -> Void)?

    // Serialize turns: only one is spoken/recorded at a time. Others wait (their hook
    // connections stay open) and drain FIFO. The voice dialogs (resume, permission question,
    // phone wake) ride the same queue, so nothing ever talks over anything else.
    private struct Item { let id: Int; let turn: TurnPayload; let respond: (TurnReply) -> Void }
    private var replyQueue: [Item] = []
    private var replyActive = false
    private var nextItem = 0

    // Instructions for a folder no reachable session runs in yet (POST /dispatch, a wake routed
    // to a Zentrale that isn't running), and when a session was last started there.
    private var pending = PendingInstructions()
    private var startedAt: [String: Date] = [:]
    static let restartGuard: TimeInterval = 120   // no second session start in a folder within this

    // Starts a session in a folder (Terminal + `claude '/parley:voice'`); a stub in tests.
    var starter: (String, String?) -> Void = { SessionStarter.start(folder: $0, resume: $1) }   // folder, resume id
    var transcripts = Transcript.projects   // Claude Code's transcripts (/past, /dispatch resume)
    // Ends a session's process (POST /close; a stub in tests): nil = closing, else why not.
    var closer: (_ id: String, _ cwd: String) -> String? = { SessionCloser.close(id: $0, cwd: $1) }
    var zentraleDir: () -> String = { ZentraleSettings.load().zentraleDir }
    // A palette for the phone (POST /palette): its `palette` frame, to send and keep until confirmed.
    var onPalette: ((_ name: String, _ frame: String) -> Void)?

    // POST /permission holds the hook at most this long, then answers "ask".
    var permissionHold: TimeInterval = 110
    private let now: () -> Date

    // Parked (paused-but-resumable) sessions. Their Stop hook short-polls /wake; we hand
    // back a pending instruction to wake them — no keystrokes needed. Keyed by session key.
    private struct Parked { var label: String; var project: String; var cwd: String; var pending: String?; var lastSeen: Date }
    private var parked: [String: Parked] = [:]

    // Every session and its state (GET /sessions, POST /resume, the announcement).
    let sessions: SessionRegistry

    // What a resumed session continues with when no instruction was spoken.
    static let resumeInstruction = "Wir machen weiter."

    // Queue item for the POST /resume voice dialog (rides the turn queue, never overlaps).
    static let resumeEvent = "resume"
    // The permission question (POST /permission) and the phone's wake dialog, the same way.
    static let permissionEvent = "permission"
    static let wakeEvent = "wake"
    // The Wachhund's question (Watchdog.swift), the same way.
    static let watchdogEvent = "watchdog"
    static let dialogEvents: Set<String> = [resumeEvent, permissionEvent, wakeEvent, watchdogEvent]
    private var lastResumable: [ParkedInfo] = []

    // Sessions are keyed by the agent's session_id; the tmux pane only as a fallback.
    static func sessionKey(session: String, pane: String) -> String { session.isEmpty ? pane : session }
    static func sessionKey(_ turn: TurnPayload) -> String { sessionKey(session: turn.session_id, pane: turn.tmux_pane) }

    init(port: UInt16 = 8787, sessions: SessionRegistry = SessionRegistry(), now: @escaping () -> Date = { Date() }) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.sessions = sessions
        self.now = now
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
            receiveTurn(turn) { [weak self] reply in
                self?.send(200, Self.turnJSON(reply), on: conn)
            }
            return
        }
        // /permission is answered once the question was asked and answered (≤ permissionHold).
        if req.method == "POST", req.path == "/permission" {
            guard permission(req.body, respond: { [weak self] json in self?.send(200, json, on: conn) }) else {
                send(400, #"{"ok":false,"error":"bad permission payload"}"#, on: conn)
                return
            }
            return
        }
        let (status, json) = handle(req)
        send(status, json, on: conn)
    }

    // A hook's /turn (on `queue`): queued for its voice — unless a dispatched instruction waits
    // for its folder (a session just started there): that is the reply, at once and unvoiced;
    // the session's opening line is moot now.
    func receiveTurn(_ turn: TurnPayload, respond: @escaping (TurnReply) -> Void) {
        let key = Self.sessionKey(turn)
        sessions.queued(id: key, label: turn.label ?? "", project: turn.project, cwd: turn.cwd)
        if let instruction = takePending(turn.cwd) {
            Log.write("dispatch: handing the waiting instruction to \(turn.spokenLabel) (its turn)")
            let reply = TurnReply(transcript: instruction, park: false)
            sessions.finished(id: key, reply: reply)
            respond(reply)
            return
        }
        enqueueReply(turn, respond)
    }

    // MARK: - permission prompts (POST /permission)

    // Unknown session (voice mode off) → "ask" at once: the normal on-screen prompt. Otherwise
    // the question rides the queue like a turn; its transcript decides. An unanswered request is
    // answered "ask" after `permissionHold` (and dropped from the queue if not voiced yet).
    // On `queue`; false = bad payload.
    func permission(_ body: Data, respond: @escaping (String) -> Void) -> Bool {
        guard let p = PermissionRequest.decode(body) else { return false }
        guard sessions.knows(p.sessionId) else {
            respond(PermissionDecision.ask.json)
            return true
        }
        let project = (p.cwd as NSString).lastPathComponent
        let label = sessions.label(of: p.sessionId).flatMap { $0.isEmpty ? nil : $0 } ?? project
        let turn = TurnPayload(event: Self.permissionEvent, session_id: p.sessionId, cwd: p.cwd, project: project,
                               tmux_pane: "", speak: PermissionPrompt.question(label: label, tool: p.toolName, input: p.input),
                               label: label, listen: true)
        let wait = PermissionWait(what: "\(label) \(p.toolName)", respond: respond)
        sessions.resumeQueued(id: p.sessionId)   // shown as queued until its question is asked
        let id = enqueue(turn) { reply in wait.answer(PermissionPrompt.decide(reply.transcript)) }
        let sid = p.sessionId
        queue.asyncAfter(deadline: .now() + permissionHold) { [weak self] in
            guard let self, !wait.done else { return }
            wait.answer(.ask)
            let before = self.replyQueue.count
            self.replyQueue.removeAll { $0.id == id }
            if self.replyQueue.count < before { self.sessions.dialogFinished(id: sid) }
        }
        return true
    }

    // MARK: - the Wachhund

    // Its question rides the queue like a permission prompt; a yes hands the session the hint
    // (delivered by the mod at once — Claude Code reads it at its next step, mid-turn).
    func watchdog(id: String, question: String, hint: String) {
        queue.async {
            guard let e = self.sessions.entries[id] else { return }
            let turn = TurnPayload(event: Self.watchdogEvent, session_id: id, cwd: e.cwd, project: e.project, tmux_pane: "",
                                   speak: question, label: e.label, listen: true)
            _ = self.enqueue(turn) { [weak self] reply in
                guard PermissionPrompt.decide(reply.transcript) == .allow else {
                    Log.write("watchdog: \(e.label) — Sir lets it run")
                    return
                }
                Log.write("watchdog: hint to \(e.label)")
                self?.deliver(id, hint)
            }
        }
    }

    // One held /permission request: answered exactly once (the dialog, or the hold timeout).
    // ponytail: @unchecked Sendable — only touched on the server queue.
    private final class PermissionWait: @unchecked Sendable {
        private(set) var done = false
        private let what: String
        private let respond: (String) -> Void
        init(what: String, respond: @escaping (String) -> Void) { self.what = what; self.respond = respond }
        func answer(_ decision: PermissionDecision) {
            guard !done else { return }
            done = true
            Log.write("permission: \(what) → \(decision.rawValue)")
            respond(decision.json)
        }
    }

    // MARK: - the phone's wake word

    // "Hey Parley" during a call: the wake dialog (greeting → listen → route), only while
    // nothing is queued or being voiced.
    func wakeFromPhone() {
        queue.async {
            guard !self.replyActive, self.replyQueue.isEmpty else {
                Log.write("phone: wake while Parley is busy — ignored")
                return
            }
            let turn = TurnPayload(event: Self.wakeEvent, session_id: "", cwd: "", project: "", tmux_pane: "",
                                   speak: "", label: nil, listen: true)
            _ = self.enqueue(turn) { _ in }
        }
    }

    // Running sessions a wake utterance can be routed to.
    func routeTargets() -> [RouteTarget] {
        queue.sync { sessions.routeTargets() }
    }

    // A routed wake utterance for a session: the resume paths when it can take it now (parked
    // hook → /wake, the mod → next /presence); a hook-only session that is busy gets it by its
    // folder, at its next turn or /wake poll.
    func deliverRouted(id: String, instruction: String) {
        queue.async {
            if !self.sessions.reachable(id), let cwd = self.sessions.cwd(of: id), !cwd.isEmpty {
                self.pending.add(instruction, cwd: cwd, at: self.now())
                Log.write("route: \(id) busy without the mod → waits for its next turn in \(cwd)")
            } else {
                self.deliver(id, instruction)
            }
        }
    }

    // MARK: - dispatch (POST /dispatch, routing to the Zentrale)

    struct DispatchResult: Equatable {
        var delivered: String   // "session" | "pending" | "none"
        var started: Bool
    }

    // Hand `instruction` to the session in `cwd`: a reachable one gets it now (the resume paths);
    // else it waits there by cwd (≤ 10 min) until a session's presence / turn / wake poll shows
    // up. `start` launches a session when none is alive in the folder (not twice in 2 min).
    func dispatch(cwd: String, instruction: String, start: Bool) -> DispatchResult {
        queue.sync { dispatchOnQueue(cwd: cwd, instruction: instruction, start: start) }
    }

    // `resume`: that past session is the one to reach — started with `--resume` unless it runs.
    // ponytail: the instruction still waits by folder; another idle session in the same folder
    // could take it first. Key it by session id if that ever bites.
    private func dispatchOnQueue(cwd raw: String, instruction: String, start: Bool, resume: String? = nil) -> DispatchResult {
        let cwd = Zentrale.normalize(raw)
        prunePending()
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let here = resume.map { sessions.alive($0) } ?? sessions.session(inFolder: cwd)
        var result = DispatchResult(delivered: "none", started: false)
        if !text.isEmpty {
            if let s = here, s.reachable {
                deliver(s.id, text)
                result.delivered = "session"
            } else {
                pending.add(text, cwd: cwd, at: now())
                result.delivered = "pending"
            }
        }
        if start, here == nil, startedAt[cwd].map({ now().timeIntervalSince($0) >= Self.restartGuard }) ?? true {
            startedAt[cwd] = now()
            starter(cwd, resume)
            result.started = true
        }
        Log.write("dispatch: \(cwd) → \(result.delivered)\(result.started ? (resume == nil ? ", session started" : ", session \(resume!) resumed") : "")")
        return result
    }

    // The instruction(s) waiting for `cwd`, consumed.
    private func takePending(_ cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        prunePending()
        return pending.take(cwd: Zentrale.normalize(cwd), now: now())
    }

    private func prunePending() {
        for cwd in pending.prune(now: now()) {
            Log.write("dispatch: instruction for \(cwd) expired — no session showed up within 10 min")
        }
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
        let pending = p.pending ?? takePending(w?.cwd)
        p.pending = nil
        parked[key] = p
        sessions.wakePoll(id: key, label: w?.label ?? "", project: w?.project ?? "", resumed: pending != nil,
                          cwd: w?.cwd ?? "")
        pruneParked()
        notifyParked()
        return Self.turnJSON(TurnReply(transcript: pending ?? "", park: false))
    }

    // MARK: - resuming sessions (menu, voice command, POST /resume)

    // Resume without a dialog (menu / voice command). Unknown ids are a no-op.
    func resume(id: String, instruction: String) {
        queue.async { self.deliver(id, instruction) }
    }

    // Hand an instruction to a session: a parked hook picks it up on its next /wake poll
    // (≤3 s) and injects it as the next turn; an idle session's mod gets it as the reply to
    // its next /presence (≤2 s) and submits it as a prompt.
    private func deliver(_ id: String, _ instruction: String) {
        if sessions.parkedHookAlive(id) {
            var p = parked[id] ?? Parked(label: "", project: "", cwd: "", pending: nil, lastSeen: Date())
            p.pending = instruction
            p.lastSeen = Date()
            parked[id] = p
            sessions.wakeQueued(id: id)
        } else {
            sessions.setPending(id: id, instruction)
        }
        notifyParked()
    }

    // POST /resume: queue the voice dialog (pre-recorded line → beep → record → transcribe)
    // behind any running turn; its transcript ("" → resumeInstruction) is delivered after.
    private func enqueueResume(_ id: String) {
        guard let e = sessions.entries[id] else { return }
        let turn = TurnPayload(event: Self.resumeEvent, session_id: id, cwd: "", project: e.project,
                               tmux_pane: "", speak: "", label: e.label, listen: true)
        sessions.resumeQueued(id: id)
        _ = enqueue(turn) { _ in }
    }

    // POST /resume and the relay's `resume` frame (docs/IPHONE.md): the voice dialog for a
    // resumable session. On `queue`; false = unknown or not resumable.
    private func startResume(_ id: String) -> Bool {
        guard sessions.canResume(id) else { return false }
        enqueueResume(id)
        return true
    }

    // A phone pressed Fortsetzen (relay `resume` frame) — the POST /resume path.
    func resumeFromRelay(id: String) {
        queue.async { _ = self.startResume(id) }
    }

    // GET /sessions for the relay, read on the server queue.
    func sessionsJSON() -> String {
        queue.sync { sessions.json() }
    }

    // Book-keeping once a queue item is answered: a hook turn's reply, or the resume dialog's
    // transcript handed to its session.
    private func complete(_ turn: TurnPayload, _ reply: TurnReply) {
        let id = Self.sessionKey(turn)
        switch turn.event {
        case Self.resumeEvent:
            sessions.resumeFinished(id: id, replied: !reply.transcript.isEmpty)
            deliver(id, reply.transcript.isEmpty ? Self.resumeInstruction : reply.transcript)
        case Self.permissionEvent, Self.wakeEvent, Self.watchdogEvent:
            sessions.dialogFinished(id: id)
        default:
            sessions.finished(id: id, reply: reply)
        }
    }

    func resumableList() -> [ParkedInfo] {
        queue.sync { sessions.resumableList() }
    }

    /// The phone's tile for this session: Parley rings again at `at`, or (distantFuture) waits for
    /// Sir's call back; nil clears it.
    func setCallback(_ id: String, at: Date?) {
        queue.sync { sessions.setCallback(id, at: at) }
    }

    // No turn waits behind the one being voiced.
    func nothingQueued() -> Bool {
        queue.sync { replyQueue.isEmpty }
    }

    // How many turns wait behind the one being voiced (a Fragerunde counts them).
    func queuedCount() -> Int {
        queue.sync { replyQueue.count }
    }

    // True if any session besides `id` is alive (any state but stopped) → announce the turn.
    func othersAlive(except id: String) -> Bool {
        queue.sync { sessions.othersAlive(except: id) }
    }

    private func pruneParked() {
        let cutoff = Date().addingTimeInterval(-90)
        parked = parked.filter { $0.value.lastSeen > cutoff }
    }

    // Push the resumable list to the menu when it changed.
    private func notifyParked() {
        let list = sessions.resumableList()
        guard list != lastResumable else { return }
        lastResumable = list
        onParked?(list)
    }

    private func send(_ status: Int, _ json: String, on conn: NWConnection) {
        let data = HTTPParse.response(status: status, json: json)
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - turn serialization

    private func enqueueReply(_ turn: TurnPayload, _ respond: @escaping (TurnReply) -> Void) {
        if replyActive { onQueued?(turn) }   // parked behind an in-flight turn → show as waiting
        _ = enqueue(turn, respond)
    }

    private func enqueue(_ turn: TurnPayload, _ respond: @escaping (TurnReply) -> Void) -> Int {
        nextItem += 1
        replyQueue.append(Item(id: nextItem, turn: turn, respond: respond))
        pumpReplies()
        return nextItem
    }

    private func pumpReplies() {
        guard !replyActive, !replyQueue.isEmpty else { return }
        guard let provider = replyProvider else {
            // No pipeline wired — answer everything empty so hooks don't hang.
            let waiting = replyQueue; replyQueue.removeAll()
            for item in waiting {
                let reply = TurnReply(transcript: "", park: false)
                complete(item.turn, reply)
                item.respond(reply)
            }
            return
        }
        replyActive = true
        let item = replyQueue.removeFirst()
        let (turn, respond) = (item.turn, item.respond)
        let dialog = Self.dialogEvents.contains(turn.event)
        sessions.activate(id: Self.sessionKey(turn), speak: dialog ? nil : turn.speak)
        if !dialog { onTurn?(turn) }
        provider(turn) { [weak self] reply in
            guard let self else { return }
            self.queue.async {
                self.complete(turn, reply)
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
            // The mod's heartbeat from every Claude Code session (~2 s). A pending resume
            // instruction rides back exactly once; the mod submits it as a prompt.
            guard let p = Contract.decodePresence(req.body), !p.session_id.isEmpty else {
                return (400, #"{"ok":false,"error":"bad presence payload"}"#)
            }
            let project = p.project?.isEmpty == false ? p.project! : ((p.cwd ?? "") as NSString).lastPathComponent
            var instruction = sessions.presence(id: p.session_id, label: p.label ?? "", project: project,
                                                state: p.state ?? "idle", usage: p.usage, tasks: p.tasks, host: p.host,
                                                cwd: p.cwd ?? "")
            // An instruction waits for this folder: an idle session takes it now (a working one
            // gets it as the reply to its turn, or once it is idle).
            if instruction == nil, (p.state ?? "idle") == "idle", let text = takePending(p.cwd) {
                sessions.handedOver(id: p.session_id)
                Log.write("dispatch: handing the waiting instruction to \(p.label ?? project) (presence)")
                instruction = text
            }
            notifyParked()
            guard let instruction,
                  let data = try? JSONEncoder().encode(["instruction": instruction]),
                  let json = String(data: data, encoding: .utf8) else { return (200, "{}") }
            return (200, json)
        case ("GET", "/sessions"):
            return (200, sessions.json())
        case ("POST", "/dispatch"):
            // The Zentrale (or anything local) hands a task to a folder's session, starting one.
            guard let d = Contract.decodeDispatch(req.body) else {
                return (400, #"{"ok":false,"error":"bad dispatch payload"}"#)
            }
            if let id = d.resume, !Transcript.isSessionID(id) || Transcript.file(for: id, root: transcripts) == nil {
                return (404, #"{"ok":false,"error":"no past session with that id"}"#)
            }
            // With `resume` the folder defaults to the session's own.
            let raw = d.cwd ?? d.resume.flatMap { Transcript.file(for: $0, root: transcripts) }.flatMap { Transcript.summary($0, at: Date())?.cwd } ?? ""
            let cwd = Zentrale.normalize(raw)
            let instruction = d.instruction ?? ""
            let start = d.start ?? true
            guard raw.hasPrefix("/") || raw.hasPrefix("~"), Zentrale.isDirectory(cwd) else {
                return (400, #"{"ok":false,"error":"cwd must be an existing absolute folder"}"#)
            }
            guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || start else {
                return (400, #"{"ok":false,"error":"nothing to do"}"#)
            }
            let r = dispatchOnQueue(cwd: cwd, instruction: instruction, start: start, resume: d.resume)
            return (200, #"{"ok":true,"delivered":"\#(r.delivered)","started":\#(r.started)}"#)
        case ("POST", "/past"):
            // The Zentrale looks up a past session (title, folder, last prompt) to resume it.
            struct Query: Decodable { var q: String?; var limit: Int? }
            let query = try? JSONDecoder().decode(Query.self, from: req.body)
            let list = Transcript.past(query: query?.q, limit: min(50, max(1, query?.limit ?? 10)), root: transcripts)
            return (200, Transcript.pastJSON(list))
        case ("POST", "/palette"):
            // The Zentrale made a colour palette by voice: to the phone (now, or when it connects).
            struct Reply: Encodable { let ok: Bool; var name: String?; var error: String? }
            let reply: (Int, Reply)
            switch PaletteSpec.frame(req.body) {
            case .failure(let p): reply = (400, Reply(ok: false, error: PaletteSpec.message(p)))
            case .success(let p):
                onPalette?(p.name, p.frame)
                reply = (200, Reply(ok: true, name: p.name))
            }
            return (reply.0, (try? JSONEncoder().encode(reply.1)).map { String(decoding: $0, as: UTF8.self) } ?? "{}")
        case ("POST", "/close"):
            guard let c = Contract.decodeClose(req.body) else {
                return (400, #"{"ok":false,"error":"bad close payload"}"#)
            }
            return close(c)
        case ("POST", "/resume"):
            // The mod's resume button: answer at once, then run the short voice dialog for
            // that session through the turn queue. Only parked / idle-with-mod sessions.
            guard let id = Contract.decodeResume(req.body)?.id, startResume(id) else {
                return (404, #"{"ok":false}"#)
            }
            return (200, #"{"ok":true}"#)
        default:
            return (404, #"{"ok":false,"error":"not found"}"#)
        }
    }
}

extension ControlServer {
    // POST /close: {"id"} | {"ids":[…]} | {"project":"<label or folder name>"} (every running
    // session of it). Each closed one shows stopped and stays resumable (/past + /dispatch
    // resume). The Zentrale never closes itself. 200 when any closed, else the first failure's
    // code: 404 unknown, 403 the Zentrale, 409 not running / not closable here.
    func close(_ c: ClosePayload) -> (Int, String) {
        var ids = (c.ids ?? []) + (c.id.map { [$0] } ?? [])
        let project = c.project?.trimmingCharacters(in: .whitespaces) ?? ""
        if !project.isEmpty { ids += sessions.running(named: project) }
        struct Closed: Encodable { let id: String; let label: String }
        struct Failed: Encodable { let id: String; let error: String }
        struct Wire: Encodable { let ok: Bool; let closed: [Closed]; let failed: [Failed] }
        var closed: [Closed] = [], failed: [Failed] = [], codes: [Int] = []
        func fail(_ id: String, _ code: Int, _ why: String) { failed.append(Failed(id: id, error: why)); codes.append(code) }
        let zentrale = zentraleDir()
        var seen = Set<String>()
        for id in ids where seen.insert(id).inserted {
            guard let s = sessions.info(id) else { fail(id, 404, "unknown session"); continue }
            if s.label == Zentrale.label || (!s.cwd.isEmpty && s.cwd == zentrale) {
                fail(id, 403, "the Zentrale does not close itself"); continue
            }
            if s.state == "stopped" { fail(id, 409, "already stopped"); continue }
            if let why = closer(id, s.cwd) { fail(id, 409, why); continue }
            sessions.closed(id: id)
            parked[id] = nil
            Log.write("close: \(s.label) (\(id))")
            closed.append(Closed(id: id, label: s.label))
        }
        if !closed.isEmpty { notifyParked() }
        if ids.isEmpty {
            return project.isEmpty ? (400, #"{"ok":false,"error":"give id, ids or project"}"#)
                                   : (404, #"{"ok":false,"error":"no running session of that project"}"#)
        }
        let data = try? JSONEncoder().encode(Wire(ok: failed.isEmpty, closed: closed, failed: failed))
        return (closed.isEmpty ? codes.first ?? 400 : 200, data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
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
