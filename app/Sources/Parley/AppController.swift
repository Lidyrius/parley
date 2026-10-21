import Foundation
import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct SessionInfo: Identifiable, Equatable {
    var id: String        // tmux_pane (or session_id fallback) — routing key
    var project: String
    var pane: String
    var status: String
}

// Ties the control server to the audio + tmux pipeline and exposes session state
// to the menu-bar UI. The per-turn sequence is:
//   pause media -> speak -> beep -> record (VAD) -> transcribe -> tmux inject ->
//   resume media -> complete (drain next).
// While the iPhone has a call connected (docs/IPHONE.md, protocol v2) every step runs through
// the phone instead — voice out as paced PCM frames, the reply from the phone's mic — chosen
// per step, so a call that ends mid-turn hands the rest back to the Mac's speaker and mic.
@MainActor
final class AppController: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    @Published var parked: [ParkedInfo] = []   // resumable sessions: parked (hook polls /wake, or the mod)
    @Published var snapshots: [Snapshot] = []
    @Published var shared: [Share] = []        // v7: sessions shared with a guest (the menu can end them)
    @Published var phoneHello: (device: String, at: Date)?   // the last phone that came onto the relay (setup step 8)
    @Published var lastError: String?
    @Published var muted = false   // manual mute toggle (menu)
    @Published var relayConnected: Bool?   // iPhone relay: nil = not configured, else reachable
    @Published var phoneCall = false       // the iPhone's call is connected: all audio goes through it
    @Published var phoneAway = false       // Unterwegs-Modus: updates ring the phone
    // The Mac locked for a minute counts as Unterwegs (menu: "Unterwegs, wenn der Mac gesperrt ist").
    @Published var autoAwayOnLock = Keychain.get(.autoAwayOnLock) == "1" {
        didSet {
            Keychain.set(autoAwayOnLock ? "1" : "", for: .autoAwayOnLock)
            phone.setLockedAway(autoAwayOnLock && macLocked)
        }
    }
    private var macLocked = false
    // Ohne Floskeln (menu): only the session's own line and Sir's answer — no "Ich habe zwei
    // Updates", no "Update zu X", no thanks for calling back, no ack after the answer.
    @Published var brief = Keychain.get(.brief) == "1" {
        didSet { Keychain.set(brief ? "1" : "", for: .brief) }
    }
    // Barge-in at the Mac (menu: "Parley unterbrechen"): talking over Parley stops it, it listens.
    @Published var bargeIn = Keychain.get(.bargeOff) != "1" {
        didSet {
            Keychain.set(bargeIn ? "" : "1", for: .bargeOff)
            if bargeIn { BargeMonitor.requestAuthorization() }
        }
    }
    // Einstellungen → App-Symbol: applies at once, kept in the Keychain.
    @Published var appIcon = AppIconChoice.saved {
        didSet {
            Keychain.set(appIcon == .porzellan ? "" : appIcon.rawValue, for: .appIcon)
            AppIconChoice.apply(appIcon)
        }
    }
    private var appearanceWatch: NSKeyValueObservation?
    private var speaking: TTSPlayer?       // the Mac's voice right now (barge-in cuts it)
    private var localBarged = false
    private var localPreroll: [Int16] = []  // the last 2 s of mic when Sir barged in
    private var lockTimer: Task<Void, Never>?
    @Published var pushKeyId: String?      // APNs key chosen ("Push-Schlüssel wählen…")

    // Muted when the user toggled it OR the Mac is in a Focus / Do-Not-Disturb mode.
    var effectivelyMuted: Bool { muted || FocusStatus.doNotDisturbActive() }

    static let shared = AppController()

    let server = ControlServer()
    private let mic = MicCapture()
    private let hud = RecordingHUD()
    // Fresh TTSPlayer per playback: its deinit tears down the AVAudioEngine, which releases
    // the output device promptly so the mic can grab it. A single long-lived engine (tried
    // once) held the device far longer when merely stopped → the mic sat at 0 buffers for
    // ~10s across retries. The player is a local in each playback func, alive for its span.
    private var started = false
    private var onboardingPlayer: TTSPlayer?
    private var relay: RelayClient?
    private var relayGen = 0   // drops state reports of a replaced relay client
    let phone = PhoneHub()
    lazy var shares = ShareHub(server: server)   // shared sessions (Shares.swift)
    private let apns = APNsClient()
    private var audioWork = 0  // queue items + ack clips in flight; 0 → the phone hears `audio idle`
    static let ringTimeout: TimeInterval = 45
    static let maxPutOff = 3   // "not now" repeats before a line gives up on the phone
    static let callBackWait: TimeInterval = 30 * 60   // "Ich rufe zurück": how long the line waits for Sir's call

    func start() {
        guard !started else { return }   // idempotent: launch + menu .task may both call
        started = true
        mic.prepareInput()   // expensive AUHAL setup now → near-instant mic starts later
        if bargeIn { BargeMonitor.requestAuthorization() }
        AppIconChoice.apply(appIcon)
        appearanceWatch = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in AppIconChoice.apply(AppController.shared.appIcon) }
        }
        Notifier.requestAuth()
        server.onTurn = { [weak self] turn in
            Task { @MainActor in
                self?.upsert(SessionInfo(id: self?.routeKey(turn.tmux_pane, turn.session_id) ?? turn.session_id,
                                         project: turn.spokenLabel, pane: turn.tmux_pane, status: "speaking"))
            }
        }
        server.onReady = { [weak self] ready in
            Task { @MainActor in self?.playReady(ready) }
        }
        server.onQueued = { [weak self] turn in
            Task { @MainActor in
                guard let self else { return }
                self.upsert(SessionInfo(id: self.routeKey(turn.tmux_pane, turn.session_id),
                                        project: turn.spokenLabel, pane: turn.tmux_pane, status: "queued"))
                Notifier.notify(title: "Parley", body: "Projekt \(turn.spokenLabel) wartet auf Antwort")
            }
        }
        server.onParked = { [weak self] list in
            Task { @MainActor in self?.parked = list }
        }
        // A session's label appeared → pre-render its "Update zu" + resume lines in the
        // background, so the first announcement / resume click is instant.
        server.sessions.onLabel = { label in
            Task { await ProjectClips.shared.prerender(label: label, config: AppConfig.load()) }
        }
        // The long-poll pipeline: speak → record → transcribe → return the reply text,
        // which the hook feeds back into the Claude session (terminal-agnostic).
        server.replyProvider = { [weak self] turn, done in
            Task { @MainActor in
                self?.beginAudioWork()
                let reply = await self?.runTurn(turn) ?? TurnReply(transcript: "", park: false)
                self?.endAudioWork()
                done(reply)
            }
        }
        let server = self.server
        phone.onWake = { server.wakeFromPhone() }
        server.remindersFile = Reminders.file
        server.snapshotsFile = Snapshots.file
        server.sessions.namesFile = Reminders.file.deletingLastPathComponent().appendingPathComponent("session-names.json")
        server.onReminded = { r in Notifier.notify(title: "Parley · Wiedervorlage", body: "An \(r.label): \(r.text)") }
        server.onPalette = { [weak self] name, frame in
            Log.write("palette: \(name) → the phone")
            Task { @MainActor in
                self?.pendingPalette = (name, frame)
                self?.phone.reply(frame)
            }
        }
        // v3: the phone's session view — history (from Claude Code's transcript), its images,
        // and typed messages (delivered like a routed instruction).
        let shares = self.shares
        shares.toSir = { [phone] in phone.reply($0) }
        // A guest asks to join: on the Mac, and as an alert on Sir's phone — its socket is often
        // closed (background), so the ask frame alone would never reach it; the tap opens the app,
        // whose hello brings the ask again (below).
        shares.notify = { [phone, apns] title, body in
            Task { @MainActor in Notifier.notify(title: title, body: body) }
            if let target = phone.alertTarget {
                Task.detached { _ = await apns.notify(token: target.token, env: target.env, title: title, body: body, session: "") }
            }
        }
        // v7: a guest's question (<speak to="Max">) goes to him; unanswered it comes back to Sir.
        server.askGuest = { [shares] id, turn, respond in shares.ask(share: id, turn, respond: respond) }
        shares.voiceForSir = { [server] turn, respond in server.voiceForSir(turn, respond: respond) }
        shares.callGuest = { [weak self] line, turn, share in await self?.callGuest(line, turn: turn, share: share) }
        shares.welcomeGuest = { [weak self] line, text, share in await self?.welcomeGuest(line, text: text, share: share) }
        shares.guestCalled = { [weak self] line, share in await self?.guestCalled(line, share: share) }
        let apns = self.apns
        shares.push = { token, env, title, body, session in
            Task.detached { _ = await apns.notify(token: token, env: env, title: title, body: body, session: session) }
        }
        phone.onChat = { [phone, weak self] event in
            // An answer (typed, or tapped in the Live Activity) closes that session's question there.
            if case .say(let id, _) = event {
                Task { @MainActor in if self?.activityAsk?.id == id { self?.activityAsk = nil } }
            }
            // A palette made by voice: again on every (re)connect until the phone confirms it.
            if case .hello(let device) = event {
                Task { @MainActor in self?.phoneHello = (device.isEmpty ? "Ihrem Handy" : device, Date()) }
                Task { @MainActor in if let p = self?.pendingPalette { phone.reply(p.frame) } }
                // Guests still waiting for Sir's yes: the ask again, in case the phone missed it.
                for s in shares.list() where s.state == "asking" { phone.reply(Shares.askFrame(s)) }
                return
            }
            if case .paletteSaved(let name) = event {
                Log.write("palette: the phone saved \(name)")
                Task { @MainActor in if self?.pendingPalette?.name == name { self?.pendingPalette = nil } }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                switch event {
                case .history(let id, let before):
                    // ponytail: re-reads the 3 MB tail per poll (~3 s while the view is open); cache by mtime if it shows.
                    let page: (items: [Transcript.Item], more: Bool) =
                        Transcript.file(for: id).map { Transcript.page($0, before: before) } ?? (items: [], more: false)
                    phone.reply(Transcript.historyFrame(session: id, items: page.items, before: before, more: page.more))
                case .image(let id, let key):
                    phone.reply(Transcript.imageFrame(key: key, jpeg: Transcript.file(for: id).flatMap { Transcript.image(in: $0, key: key) }))
                case .say(let id, let text):
                    Log.write("phone: typed message for \(id) (\(text.count) chars)")
                    server.deliverRouted(id: id, instruction: text)
                case .snapshotSave(let name, let ids):
                    _ = server.saveSnapshot(name: name, ids: ids)   // the list goes out with /sessions
                case .snapshotOpen(let id):
                    if let (s, outcomes) = server.openSnapshot(id) { phone.reply(Snapshots.frame(s, outcomes)) }
                case .snapshotDelete(let id):
                    _ = server.deleteSnapshot(id)
                case .shareCreate(let session):
                    if let (s, link) = shares.create(session: session) { phone.reply(Shares.linkFrame(s, link: link)) }
                case .shareApprove(let id, let role, let listen, let full, let mine):
                    shares.approve(id, role: role, listen: listen, full: full, mine: mine)
                case .shareRemove(let id):
                    shares.remove(id)
                default: break
                }
            }
        }
        phone.onChange = { [weak self] in Task { @MainActor in self?.syncPhone() } }
        syncPhone()
        let push = APNsCredentials.load()
        pushKeyId = push.isComplete ? push.keyId : nil
        Task { await ProjectClips.shared.prerenderGreetings(config: AppConfig.load()) }
        server.start()
        startRelay()
        shares.start()
        activityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickLiveActivity() }
        }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickWatchdog() }
            self?.server.tickReminders()
            self?.shares.tick()
        }
        let center = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.screenLocked(locked) }
            }
        }
    }

    // Locked → after a minute (not for a quick lock) updates ring the phone; unlocked → back at once.
    private func screenLocked(_ locked: Bool) {
        macLocked = locked
        lockTimer?.cancel()
        guard locked else { phone.setLockedAway(false); return }
        lockTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, !Task.isCancelled, macLocked else { return }
            phone.setLockedAway(autoAwayOnLock)
        }
    }

    // MARK: - the Wachhund (Watchdog.swift)

    // Every 30 s: each working session's transcript tail → a finding → Sir is asked (at the Mac /
    // on a call), or told by notification (Unterwegs without a call) — once per kind per 30 min.
    private func tickWatchdog() {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(server.sessionsJSON().utf8))) as? [String: Any],
              let list = obj["sessions"] as? [[String: Any]] else { return }
        let now = Date()
        for s in list where s["state"] as? String == "working" {
            guard let id = s["id"] as? String, let file = Transcript.file(for: id) else { continue }
            let since = Date(timeIntervalSince1970: ((s["since"] as? NSNumber)?.doubleValue ?? 0) / 1000)
            let written = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let tail = Transcript.tailLines(file, bytes: 256 * 1024)
            if Watchdog.turnEnded(tail) { continue }   // it waits for Sir, it doesn't hang
            let calls = Watchdog.calls(tail)
            guard let finding = Watchdog.check(state: "working", since: since, lastWrite: written, calls: calls, now: now),
                  watchdogMemory.shouldReport(id, finding, now: now) else { continue }
            let label = (s["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (s["project"] as? String ?? "Eine Session")
            let question = Watchdog.question(label: label, finding)
            Log.write("watchdog: \(label) — \(finding.kind)")
            if phone.away && !phone.callActive {
                // Unterwegs: no call for this — a notification; tapping it opens the session to answer.
                if let target = phone.alertTarget {
                    let apns = self.apns
                    Task.detached { await apns.notify(token: target.token, env: target.env, title: "Parley · \(label)", body: question, session: id) }
                }
            } else {
                server.watchdog(id: id, question: question, hint: Watchdog.hint(finding))
            }
        }
    }

    // MARK: - the iPhone's Live Activity (docs/LIVE-ACTIVITIES.md)

    private var activityFeed = LiveActivityFeed()
    private var activityAsk: LiveActivity.Ask?   // Stumm: the latest question, until answered
    private var widgetFeed = WidgetPushFeed()
    private var pendingPalette: (name: String, frame: String)?   // a palette made by voice, until the phone has it
    private var watchdogMemory = WatchdogMemory()
    private var watchdogTimer: Timer?
    private var activityTimer: Timer?
    private var seenActivityToken: String?

    // Every 2 s: the sessions as the activity shows them → start / update / end by push.
    private func tickLiveActivity() {
        let now = Date()
        let update = phone.activityTarget
        if update?.token != seenActivityToken {
            seenActivityToken = update?.token
            activityFeed.phoneReports(running: update != nil, at: now)
        }
        guard apns.configured else { return }
        let start = phone.activityStartTarget
        let sessions = server.sessionsJSON()
        if let ask = activityAsk, !LiveActivity.isOpen(ask, sessions: sessions) { activityAsk = nil }
        let content = LiveActivity.content(fromSessions: sessions, ask: activityAsk)
        // The widgets: a silent push now and then, which the app stores for them.
        if let alert = phone.alertTarget {
            let widget = LiveActivity.widget(fromSessions: sessions)
            if widgetFeed.due(widget, now: now) {
                let apns = self.apns, body = LiveActivity.widgetPayload(widget)
                Task.detached {
                    let r = await apns.background(token: alert.token, env: alert.env, body: body)
                    Log.write("widgets: silent push → \(r.status)\(r.reason.map { " \($0)" } ?? "")")
                }
            }
        }
        guard let action = activityFeed.step(content, away: phone.away, canStart: start != nil,
                                             canUpdate: update != nil, now: now) else { return }
        let (target, body, priority, what): ((token: String, env: String)?, Data, Int, String) = switch action {
        case .start(let c): (start, LiveActivity.payload(.start, c, now: now), 10, "start")
        case .update(let c, let p): (update, LiveActivity.payload(.update, c, now: now), p, "update")
        case .end(let c): (update, LiveActivity.payload(.end, c, now: now), 10, "end")
        }
        guard let target else { return }
        let apns = self.apns, phone = self.phone
        Task.detached {
            let r = await apns.liveActivity(token: target.token, env: target.env, body: body, priority: priority)
            Log.write("live activity: \(what) → \(r.status)\(r.reason.map { " \($0)" } ?? "")")
            // A token APNs no longer knows: that activity (or the phone's start token) is gone.
            guard r.status == 410 || r.reason == "BadDeviceToken" else { return }
            phone.handle(what == "start" ? .activityStart(token: "", env: target.env) : .activity(token: "", env: target.env))
        }
    }

    private func syncPhone() {
        if phoneCall && !phone.callActive { lastCallEnd = Date() }
        if !phoneCall && phone.callActive { greetCaller() }
        phoneCall = phone.callActive
        phoneAway = phone.away
    }

    // Sir called in: Parley greets him at once and listens ("Zu Diensten, Sir. Was darf ich für Sie
    // tun?") — no "Hey Parley" needed. Only when nothing else runs: a call that answers a ring or
    // calls back a waiting line has its turn, and Fortsetzen sends its resume right after the
    // call starts (a dialog, or Sir's timer ending — then the session reports by itself).
    private func greetCaller() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, phone.callActive, !server.resumedRecently() else { return }
            server.wakeFromPhone()
        }
    }

    // MARK: - Fragerunde

    // After a call, the next updates don't ring at once while other sessions still work: for up to
    // the phone's setting (Einstellungen → Fragerunde, 90 s by default, 0 = off) they gather (queued,
    // shown so in the Island) and then come as one round — "Ich habe drei Updates für Sie, Sir."
    // Sir calling in meanwhile starts the round right away. Permission prompts never wait.
    private var lastCallEnd: Date?

    // Only while more can come: another session still working. Nothing else at work → it rings
    // at once (waiting would only delay this one update). Sir's own timer ("ruf mich in 2
    // Minuten zurück") never waits: its turn rings at once, and one queued behind ends the wait —
    // as does a Wiedervorlage for Sir.
    private func gatherRound(session: String) async {
        let gap = TimeInterval(phone.roundSeconds)
        guard gap > 0, let end = lastCallEnd, !phone.callActive else { return }
        let ready = end.addingTimeInterval(gap)
        guard Date() < ready, server.othersWorking(except: session) else { return }
        if server.afterWait(session) { Log.write("Fragerunde: skipped — Sir's timer ran out"); return }
        Log.write("Fragerunde: gathering until \(ready.formatted(date: .omitted, time: .standard))")
        LiveStatus.set(phase: "queued")
        while Date() < ready, !phone.callActive, phone.away, !Task.isCancelled,
              server.othersWorking(except: session), !server.timerQueued() {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let why = Date() >= ready ? "waited long enough" : server.timerQueued() ? "Sir's timer ran out" : "nothing else at work"
        Log.write("Fragerunde: ringing now (\(why))")
        LiveStatus.set(phase: "speaking")
    }

    /// "Ich habe drei Updates für Sie, Sir." — before the first of several in a new call.
    private func announceRound(_ config: AppConfig) async {
        let n = 1 + server.queuedCount()
        guard n > 1 else { return }
        let de = config.language.lowercased().hasPrefix("de")
        let words = ["zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun"]
        let count = n - 2 < words.count ? words[n - 2] : "\(n)"
        Log.write("Fragerunde: \(n) updates")
        await speakLine(de ? "Ich habe \(count) Updates für Sie, Sir." : "I have \(n) updates for you, Sir.", config: config)
    }

    // `audio` state for the phone: speaking while any queue item or ack clip runs (the phone
    // and listener refine it), idle once all are done and no turn waits — the phone listens for
    // its wake word then, or hangs up after the talk; never between two queued turns.
    private func beginAudioWork() {
        audioWork += 1
        phone.setAudioState(.speaking)
    }

    private func endAudioWork() {
        audioWork = max(0, audioWork - 1)
        if audioWork == 0, server.nothingQueued() { phone.setAudioState(.idle) }
    }

    // MARK: - /ready greeting

    // Arm the session on /ready. No greeting clip is played: the skill's first <speak>
    // label is the spoken greeting (avoids a double greeting — clip + spoken line).
    private func playReady(_ ready: ReadyPayload) {
        StatsStore.shared.startSession()
        upsert(SessionInfo(id: routeKey(ready.tmux_pane, ready.session_id),
                           project: ready.project, pane: ready.tmux_pane, status: "ready"))
        let project = ready.project.isEmpty ? "" : " · \(ready.project)"
        Notifier.notify(title: "Parley", body: "Voice-Modus aktiv\(project)")
    }

    // MARK: - /turn pipeline

    // Returns the transcribed voice reply ("" = user said nothing → end conversation).
    // The server hands this back to the blocking Stop hook, which injects it into the
    // Claude session. No terminal/tmux coupling.
    private func runTurn(_ turn: TurnPayload) async -> TurnReply {
        let key = routeKey(turn.tmux_pane, turn.session_id)
        LiveStatus.begin(session: turn.session_id)
        phone.setSpeaker(turn.spokenLabel.isEmpty ? "Parley" : turn.spokenLabel)   // wake dialog: Parley itself
        defer { LiveStatus.set(phase: "idle") }
        switch turn.event {
        case ControlServer.resumeEvent: return await runResume(turn)
        case ControlServer.wakeEvent: return await runWake()
        case ControlServer.permissionEvent, ControlServer.watchdogEvent: return await runPermission(turn)
        case ControlServer.reminderEvent: return await runReminder(turn)
        default: break
        }
        upsert(SessionInfo(id: key, project: turn.project, pane: turn.tmux_pane, status: "speaking"))
        let config = AppConfig.load()
        resumeGen += 1   // a new turn began → cancel any pending debounced media resume
        Log.write("turn start project=\(turn.project) ttsReady=\(config.ttsReady) sttReady=\(config.sttReady)")

        // Muted (manual toggle or macOS Do-Not-Disturb) → stay silent: no TTS, no mic, no
        // pill. Return "" so the hook ends the turn cleanly; the loop resumes when unmuted.
        // Muting is about the Mac: a connected (or ringing) phone call still carries the turn.
        func mutedTurn() -> TurnReply {
            Log.write("muted (manual=\(muted) dnd=\(FocusStatus.doNotDisturbActive())) → skipping turn")
            setStatus(key, "muted")
            // Stumm: nicht sprechen, aber die Zusammenfassung als Notification zeigen, damit
            // du mitbekommst, dass der Turn fertig ist — auch ohne dass ich rede.
            Notifier.notify(title: "Parley · \(turn.spokenLabel)", body: turn.speak)
            return TurnReply(transcript: "", park: false)
        }
        // Unterwegs + Stumm: no call, no voice on the Mac — a notification, and the session waits
        // (parked) for a reply typed on the phone.
        if phone.away && phone.silent && !phone.callActive { return silentTurn(turn, key: key) }
        let ringing = shouldRing
        if effectivelyMuted && !phone.callActive && !ringing { return mutedTurn() }

        // Kick off Google TTS synthesis IMMEDIATELY — it runs in parallel with everything
        // below. Its observed duration feeds the TTSTiming prediction model.
        let synthStart = Date()
        let synthFlag = SynthFlag()
        let prefetch: Task<Data?, Never>? = config.useGoogle ? Task { [synthFlag] in
            defer { synthFlag.done = true }
            let req = GoogleTTS.request(text: turn.speak, apiKey: config.googleKey, voice: config.googleVoice)
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            TTSTiming.record(chars: turn.speak.count, seconds: Date().timeIntervalSince(synthStart))
            return GoogleTTS.pcm(from: data)
        } : nil

        // Predicted answers (<reply>): render their lines now, in parallel with everything
        // below — ready long before the user stops talking.
        let replies = turn.wantsListen ? turn.replies ?? [] : []
        let replyClips: Task<[Data?], Never>? = replies.isEmpty || !config.useGoogle ? nil : Task {
            await withTaskGroup(of: (Int, Data?).self) { group in
                for (i, r) in replies.enumerated() { group.addTask { (i, await GoogleTTS.synth(r.say, config: config)) } }
                var clips = [Data?](repeating: nil, count: replies.count)
                for await (i, pcm) in group { clips[i] = pcm }
                return clips
            }
        }

        // Unterwegs-Modus: ring the phone (VoIP push + `ring`) and wait ≤ 45 s for the call; the
        // synthesis above keeps running meanwhile. No answer → the Mac's speaker as always.
        // "Not now" on the phone puts the line off: ring again in a minute or five, or wait for
        // Sir's call back (the phone's tile offers "Rückrufen") — then thank him first.
        var calledBack = false
        if ringing { await gatherRound(session: ControlServer.sessionKey(turn)) }
        let rang = ringing && !phone.callActive
        if rang, case .reached(let back) = await reachPhone(label: turn.spokenLabel, session: ControlServer.sessionKey(turn), key: key) {
            calledBack = back
        }
        // Unterwegs and not on the phone: the Mac stays silent — the line waits as a notification.
        if phone.away && !phone.callActive { prefetch?.cancel(); return silentTurn(turn, key: key) }
        if effectivelyMuted && !phone.callActive { prefetch?.cancel(); return mutedTurn() }
        if calledBack, !brief { await thankForCallingBack(config) }
        if ringing, phone.callActive, !brief { await announceRound(config) }

        // Wait out the previous turn's background ack clip so this turn's audio never
        // overlaps it (only ever blocks if Claude replied faster than the ack played).
        await ackTask?.value
        ackTask = nil

        // Another session alive (any state but stopped) → announce which one is speaking,
        // "Update zu <Name>" (cached, plays instantly — so media must pause right away then).
        let announcement: Data? = !brief && server.othersAlive(except: ControlServer.sessionKey(turn))
            ? await ProjectClips.shared.clipData(label: turn.spokenLabel, language: config.language, config: config)
            : nil

        // Smart media pause: don't silence YouTube while we're still WAITING for the TTS.
        // Hold until the synthesis is done — or until ~1s before its PREDICTED completion
        // (learned model), so the pause lands just ahead of playback. With an announcement
        // (instant audio) or without a prefetch, pause immediately.
        if announcement == nil, let _ = prefetch {
            let target = max(0, TTSTiming.predict(chars: turn.speak.count) - 1.0)
            while !synthFlag.done, Date().timeIntervalSince(synthStart) < target {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        await pauseMediaIfPlaying()

        if let ann = announcement {
            Log.write("multi-instance → announcing \(turn.spokenLabel)")
            await playClip(ann, rate: config.speakingRate)
        }

        Log.write("speak start (listen=\(turn.wantsListen))")
        let prefetchedPCM: Data? = prefetch == nil ? nil : await prefetch!.value
        await speakAndBeep(turn.speak, config: config, prefetched: prefetchedPCM, beep: turn.wantsListen,
                           slides: turn.slides ?? [], session: ControlServer.sessionKey(turn),
                           last: !turn.wantsListen && server.nothingQueued())
        Log.write("speak done")
        // Barge-in: Sir talked over Parley — listen now (even after a speak-only line), with
        // the seconds he already spoke.
        let barged = phone.takeBarge() || takeLocalBarge()
        if barged { Log.write("barge-in: listening") }

        // speak-only turn (<speak-end>): no mic, no pill. Resume media (queue permitting),
        // end cleanly so the hook exits — Claude reports back on its own.
        if !turn.wantsListen && !barged {
            scheduleResume()
            setStatus(key, "idle")
            // Ich melde mich selbst zurück (Background-Arbeit fertig) — Notification fängt
            // dich, falls du weg bist und die Ansage verpasst.
            Notifier.notify(title: "Parley · \(turn.spokenLabel)", body: turn.speak)
            Log.write("turn end (speak-only)")
            return TurnReply(transcript: "", park: false)
        }

        // Record → transcribe. If the reply is actually a CONTROL command (resume a paused
        // project by voice) it's handled here and we re-record for THIS session's real
        // answer — the current question still stands. Capped so it can't loop forever.
        var wav = Data()
        var text = ""
        var sttFailed = false   // Groq unreachable / refused: not silence
        for hop in 0..<4 {
            setStatus(key, "listening")
            Log.write("record start")
            wav = await record(preroll: barged && hop == 0)
            Log.write("record done bytes=\(wav.count)")

            setStatus(key, "transcribing")
            let heard = await transcribeChecked(wav, config: config)
            sttFailed = heard == nil
            text = heard ?? ""
            Log.write("transcribe done chars=\(text.count)\(sttFailed ? " (failed)" : "")")

            // Resumable = parked: its hook polls /wake, or the mod gets it via /presence.
            let targets = text.isEmpty || hop >= 3 ? [] : server.resumableList()
            guard !targets.isEmpty,
                  let cmd = await ControlCommand.detect(text, labels: targets.map { $0.label }, config: config),
                  cmd.resume, let target = matchParked(cmd.target, in: targets) else { break }

            let instruction = cmd.instruction.isEmpty ? ControlServer.resumeInstruction : cmd.instruction
            server.resume(id: target.id, instruction: instruction)
            Log.write("control: resume \(target.label) → \"\(instruction)\"")
            await speakAndBeep("Verstanden, Sir — ich nehme \(target.label) wieder auf. Und für dieses Projekt?",
                               config: config, beep: true)
            // loop: listen again for the current session's actual reply
        }

        // "Warte X Minuten" — the reply asks to pause before continuing. Confirm, resume
        // media for the wait, and tell the hook to sleep then re-inject a resume prompt so
        // Claude picks up automatically. (Checked before STOP, which also matches "warte".)
        if !text.isEmpty {
            let wait = await extractWait(text, config: config)
            if wait > 0 {
                let human = humanDuration(wait)
                Log.write("wait requested: \(wait)s")
                StatsStore.shared.recordTurn(speak: turn.speak, transcript: text,
                                             recordSeconds: 0, intent: "WAIT", project: turn.project)
                await speakLine("Verstanden, Sir. Ich warte \(human) und melde mich dann.", config: config)
                scheduleResume()   // let media play during the pause
                setStatus(key, "idle")
                let resume = "[Parley] Die vom Nutzer angeforderte Wartezeit von \(human) ist vorbei. " +
                    "Fahre jetzt fort: prüfe, ob alles wie erwartet funktioniert hat, und berichte kurz." +
                    "\n\nSeine Antwort davor, vollständig:\n\(text)"   // a long reply that mentions waiting must not get lost
                return TurnReply(transcript: "", park: false, waitSeconds: wait, resume: resume)
            }
        }

        // Classify (fast, ~0.3 s) — needed for the ack clip, stats and the STOP decision. In
        // parallel: which predicted answer (<reply>) it is, if the session gave any.
        let heard = text
        async let picked = heard.isEmpty ? nil : pickReply(heard, options: replies.map(\.on), config: config)
        var intent = text.isEmpty ? .other : await classify(text, config: config)
        Log.write("classified: \(intent.rawValue)")
        let recordSeconds = Double(max(0, wav.count - 44)) / 2.0 / 16000.0   // 16 kHz mono 16-bit WAV
        StatsStore.shared.recordTurn(speak: turn.speak, transcript: text,
                                     recordSeconds: recordSeconds, intent: intent.rawValue,
                                     project: turn.project)

        // Play the spoken acknowledgment in the BACKGROUND. Returning the transcript now
        // lets the hook inject it immediately, so Claude starts working while the ack line
        // ("Alles klar, ich sehe es mir an") is still playing — no waiting on playback. The
        // next turn awaits this task before it speaks, so audio never overlaps.
        // ORDER inside the task: hi-fi restored → ack clip → THEN media resume, so the
        // video never plays over the acknowledgment.
        // A predicted answer matched → its own line instead of the generic ack (pre-rendered,
        // plays at once). One that asks back opens the mic again; both answers go on.
        var line: AckLine?
        var pick = await picked
        if pick == nil, !replies.isEmpty { Log.write("reply: none of \(replies.count) fits") }
        // Asking back after an answer that already says what to do would be wrong: generic ack.
        if let i = pick, replies[i].listen == true, heard.split(whereSeparator: \.isWhitespace).count > 12 {
            Log.write("reply: \(replies[i].on) asks back, but the answer is already detailed → generic ack")
            pick = nil
        }
        if let i = pick {
            let r = replies[i], clip = (await replyClips?.value)?[i] ?? nil
            Log.write("reply: \(r.on) → \"\(r.say)\" (rendered=\(clip != nil))")
            if r.listen == true {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await waitForHiFiOutput()
                await speakAndBeep(r.say, config: config, prefetched: clip, beep: true)
                setStatus(key, "listening")
                let more = await transcribe(await record(), config: config)
                Log.write("reply follow-up chars=\(more.count)")
                text += "\n\n[Parley hat nachgefragt: „\(r.say)“]" + (more.isEmpty ? "" : "\n\(more)")
                intent = more.isEmpty ? .other : await classify(more, config: config)
            } else if !brief {
                line = AckLine(say: r.say, clip: clip)
                text += "\n\n[Parley hat darauf bereits geantwortet: „\(r.say)“ – nicht wiederholen.]"
            }
        }
        startAck(intent: intent, hasText: !text.isEmpty, line: line, config: config)

        // "Stop heißt Stop": a STOP reply is NOT fed back. The STOP ack clip still plays
        // (background) as the sign-off; returning "" makes the hook exit cleanly.
        // "Stop heißt Stop" — the reply isn't fed back. But the session PARKS instead of
        // ending, so it stays resumable by voice/menu. Likewise a silent turn parks.
        if intent == .stop || text.isEmpty {
            let reply = Self.quietEnd(stop: intent == .stop, sttFailed: sttFailed)
            setStatus(key, reply.park ? "paused" : "idle")
            Log.write(intent == .stop ? "turn end (stop → parked, resumable)"
                      : reply.park ? "turn end (silence → parked, resumable)" : "turn end (transcription failed → not parked)")
            return reply
        }
        setStatus(key, "sent")
        Log.write("turn end")
        return TurnReply(transcript: text, park: false)
    }

    // A listening turn with nothing to feed back: "Stopp" and silence park (resumable); a failed
    // transcription just ends the turn — a network error must not leave its hook parked for good.
    nonisolated static func quietEnd(stop: Bool, sttFailed: Bool) -> TurnReply {
        TurnReply(transcript: "", park: stop || !sttFailed)
    }

    // Resume a session from the menu (mouse fallback for the voice command) — no dialog.
    func resume(_ id: String) { server.resume(id: id, instruction: ControlServer.resumeInstruction) }

    // Re-read the resumable list (menu opened — parked sessions may have gone stale since).
    func refreshResumable() {
        parked = server.resumableList()
        snapshots = server.snapshotList()
        shared = shares.list().filter { $0.state != "invited" }
    }

    // The menu's Snapshots: open one, or keep the running sessions under a name Sir types.
    func openSnapshot(_ id: String) {
        DispatchQueue.global(qos: .userInitiated).async { [server] in _ = server.openSnapshot(id) }
    }

    func saveSnapshot() {
        let alert = NSAlert()
        alert.messageText = "Snapshot sichern"
        alert.informativeText = "Merkt sich Name, Session-ID und Ordner jeder laufenden Session."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Name, z. B. Kunde Müller"
        alert.accessoryView = field
        alert.addButton(withTitle: "Sichern")
        alert.addButton(withTitle: "Abbrechen")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if server.saveSnapshot(name: field.stringValue) == nil { lastError = "Snapshot: Name fehlt oder keine Session läuft" }
        snapshots = server.snapshotList()
    }

    // POST /resume (the mod's button): a short voice dialog instead of a hook turn — the
    // pre-recorded "Ich habe die Arbeit an X wieder aufgenommen…" line, then beep → record →
    // transcribe exactly like a listening turn. No "Update zu" announcement. The transcript
    // ("" → the default instruction) goes back to the server, which hands it to the session.
    private func runResume(_ turn: TurnPayload) async -> TurnReply {
        let config = AppConfig.load()
        resumeGen += 1
        Log.write("resume dialog start project=\(turn.project)")
        let ringing = shouldRing
        var calledBack = false
        if ringing, case .reached(let back) = await reachPhone(label: turn.spokenLabel, session: ControlServer.sessionKey(turn), key: nil) {
            calledBack = back
        }
        if phone.away && !phone.callActive {
            Log.write("Unterwegs, phone not reached → resuming without dialog (the Mac stays silent)")
            return TurnReply(transcript: "", park: false)
        }
        if effectivelyMuted && !phone.callActive {
            Log.write("muted → resuming without dialog")
            return TurnReply(transcript: "", park: false)
        }
        await ackTask?.value
        ackTask = nil
        if calledBack, !brief { await thankForCallingBack(config) }

        // Cached line (or synthesized live + cached); nil → speakAndBeep synthesizes the text.
        let (clip, line) = await ProjectClips.shared.resumeClip(label: turn.spokenLabel, config: config)
        await pauseMediaIfPlaying()
        await speakAndBeep(line, config: config, prefetched: clip, beep: true)

        LiveStatus.set(phase: "listening")
        let wav = await record()
        LiveStatus.set(phase: "transcribing")
        let text = await transcribe(wav, config: config)
        Log.write("resume dialog done chars=\(text.count)")

        startAck(intent: .other, hasText: !text.isEmpty, config: config)
        return TurnReply(transcript: text, park: false)
    }

    // The acknowledgment in the BACKGROUND, then the media resume (debounced; only once the
    // whole cue is idle). The next queue item awaits it, so audio never overlaps.
    private func startAck(intent: Intent, hasText: Bool, line: AckLine? = nil, config: AppConfig) {
        if brief { scheduleResume(); return }
        beginAudioWork()
        ackTask = Task { [weak self] in
            await self?.playAck(intent: intent, hasText: hasText, line: line, config: config)
            self?.scheduleResume()
            self?.endAudioWork()
        }
    }

    // MARK: - iPhone: wake word, ringing, permission questions (docs/IPHONE.md, protocol v2)

    // Ring only in Unterwegs-Modus with no call yet, and when the phone can be reached at all
    // (a VoIP push, or the relay for a phone in the foreground).
    private var shouldRing: Bool {
        phone.away && !phone.silent && !phone.callActive && ((apns.configured && phone.pushTarget != nil) || relayConnected == true)
    }

    private func silentTurn(_ turn: TurnPayload, key: String) -> TurnReply {
        Log.write("Unterwegs + Stumm → notification for \(turn.spokenLabel)")
        if let target = phone.alertTarget {
            let apns = self.apns, session = ControlServer.sessionKey(turn)
            Task.detached {
                await apns.notify(token: target.token, env: target.env, title: "Parley · \(turn.spokenLabel)",
                                  body: turn.speak, session: session)
            }
        } else {
            Log.write("phone: no notification token yet — open the app once with Stumm on")
        }
        setStatus(key, "paused")
        // The question with its predicted answers into the Live Activity: a tap answers it.
        if turn.wantsListen {
            activityAsk = LiveActivity.Ask(id: ControlServer.sessionKey(turn), label: turn.spokenLabel, text: turn.speak,
                                           options: (turn.replies ?? []).map(\.on))
        }
        return TurnReply(transcript: "", park: turn.wantsListen)
    }

    enum RingOutcome: Equatable { case answered, missed, later(TimeInterval?) }
    enum Reach { case reached(calledBack: Bool), notReached }

    /// Rings, and follows the phone's "not now": rings again after the delay, or waits up to
    /// 30 min for Sir's own call (the tile offers "Rückrufen"). `key`: the menu row to mark waiting.
    /// `callBack`: a call Sir didn't take counts as "Ich rufe zurück" too (not for a permission
    /// prompt — its hook gives up after two minutes).
    private func reachPhone(label: String, session: String, key: String?, callBack: Bool = true) async -> Reach {
        func ring() async -> RingOutcome {
            let o = await ringPhone(label: label)
            guard o == .missed, callBack else { return o }
            Log.write("phone: not answered → waits for Sir's call back")
            return .later(nil)
        }
        var outcome = await ring()
        var calledBack = false
        var putOff = 0
        while case .later(let after) = outcome {
            // The whole queue waits meanwhile: three "not now" in a row, then the Mac's way.
            putOff += 1
            guard putOff <= Self.maxPutOff else {
                Log.write("phone: put off \(Self.maxPutOff) times → not reached")
                outcome = .missed
                break
            }
            if let key { setStatus(key, "waiting") }
            if let after {
                let at = Date().addingTimeInterval(after)
                server.setCallback(session, at: at)
                while Date() < at, !phone.callActive, !Task.isCancelled { try? await Task.sleep(nanoseconds: 250_000_000) }
                server.setCallback(session, at: nil)
                outcome = phone.callActive ? .answered : await ring()
            } else {
                server.setCallback(session, at: .distantFuture)
                calledBack = await phone.waitForCall(timeout: Self.callBackWait)
                server.setCallback(session, at: nil)
                Log.write(calledBack ? "phone: Sir called back" : "phone: no call back in 30 min")
                outcome = calledBack ? .answered : .missed
            }
        }
        return outcome == .answered ? .reached(calledBack: calledBack) : .notReached
    }

    private func thankForCallingBack(_ config: AppConfig) async {
        let de = config.language.lowercased().hasPrefix("de")
        await speakLine(de ? "Danke für Ihren Rückruf, Sir." : "Thank you for calling back, Sir.", config: config)
    }

    // VoIP push + `ring`, then wait ≤ 45 s for `call start` — or the phone's "not now".
    private func ringPhone(label: String) async -> RingOutcome {
        Log.write("phone: ringing for \(label) (Unterwegs-Modus)")
        _ = phone.takeLater()   // an old "not now" or decline is not this ring's
        _ = phone.takeDeclined()
        phone.ring(label: label)
        if let target = phone.pushTarget, apns.configured {
            let apns = self.apns
            Task.detached { await apns.push(token: target.token, env: target.env, label: label) }
        }
        var deadline = Date().addingTimeInterval(Self.ringTimeout)
        while !phone.callActive {
            if let later = phone.takeLater() { return .later(later) }
            // Declined on the lock screen: its notification offers "later" — give it a minute.
            if phone.takeDeclined() {
                deadline = max(deadline, Date().addingTimeInterval(60))
                Log.write("phone: declined — a minute for a \"later\" from the notification")
            }
            guard Date() < deadline, !Task.isCancelled else {
                Log.write("phone: no answer in 45 s → the Mac's speaker")
                return .missed
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        Log.write("phone: call answered — voicing through the phone")
        return .answered
    }

    // v7 part 3: a guest's question on his own call line (Shares.swift) — ring his phone (his
    // room's `ring` + a VoIP push naming the share), ask in Parley's voice, listen, transcribe.
    // Runs beside Sir's own line; nil = he didn't pick up (his Rückfrage screen stays open).
    func callGuest(_ line: PhoneHub, turn: TurnPayload, share: Share) async -> String? {
        let name = share.guest?.name ?? "Gast"
        guard await ringGuest(line, label: "Rückfrage · \(share.label)", share: share) else { return nil }
        let config = AppConfig.load()
        line.setSpeaker(share.label)
        await speakToGuest(line, turn.speak, slides: turn.slides ?? [], session: ControlServer.sessionKey(turn), beep: true, config: config)
        guard line.callActive else { return nil }
        let text = await listenToGuest(line, config: config)
        Log.write("share: \(name) answered on the phone (\(text.count) chars)")
        if line.callActive {
            await speakToGuest(line, text.isEmpty ? "Ich gebe die Frage weiter." : "Danke, ich gebe es weiter.", beep: false, config: config)
            line.setAudioState(.idle)   // the phone hangs up once the line goes quiet
        }
        return text
    }

    /// The guest called himself (his "Anrufen", or "Hey Parley" in his call): Parley asks what to
    /// pass on and hands his words to the session like a typed message. nil = nothing to pass on.
    func guestCalled(_ line: PhoneHub, share: Share) async -> String? {
        guard line.callActive, let g = share.guest else { return nil }
        let config = AppConfig.load()
        line.setSpeaker(share.label)
        guard !g.listen else {
            await speakToGuest(line, "Hallo \(g.name). Bei \(share.label) hören Sie nur zu – ich kann nichts weitergeben.", beep: false, config: config)
            if line.callActive { line.setAudioState(.idle) }
            return nil
        }
        await speakToGuest(line, "Ja, \(g.name)? Was soll ich \(share.label) sagen?", beep: true, config: config)
        guard line.callActive else { return nil }
        let text = await listenToGuest(line, config: config)
        Log.write("share: \(g.name) called in for \(share.label) (\(text.count) chars)")
        if line.callActive {
            await speakToGuest(line, text.isEmpty ? "Gut, dann bis später." : "Danke, ich gebe es weiter.", beep: false, config: config)
            line.setAudioState(.idle)
        }
        return text.isEmpty ? nil : text
    }

    /// One line on a guest's call — with his captions and slides, just as on Sir's phone.
    private func speakToGuest(_ line: PhoneHub, _ text: String, slides: [SlideSpec] = [], session: String = "",
                              beep: Bool, config: AppConfig) async {
        let voice = PhoneVoice(link: line, rate: config.speakingRate)
        if let pcm = await GoogleTTS.synth(text, config: config) {
            let t = Captions.timings(text: text, pcm: pcm, sampleRate: PhoneAudioFormat.ttsRate, rate: config.speakingRate)
            if let t { line.reply(Captions.frame(t, last: !beep)) }
            if !slides.isEmpty { sendSlides(slides, timed: t, session: session, to: line) }
            voice.enqueue(pcm)
        }
        _ = await voice.finish(beep: beep)
    }

    private func listenToGuest(_ line: PhoneHub, config: AppConfig) async -> String {
        let wav: Data
        switch await PhoneListener(link: line).record() {
        case .finished(let w): wav = w
        case .callEnded(let w, _): wav = w
        }
        return await transcribe(wav, config: config)
    }

    /// His line rings (ring frame + VoIP push) until he picks up: false if he can't or doesn't.
    private func ringGuest(_ line: PhoneHub, label: String, share: Share) async -> Bool {
        let name = share.guest?.name ?? "Gast"
        _ = line.takeLater()
        _ = line.takeDeclined()
        guard !line.callActive else { return true }
        line.ring(label: label)
        if let target = line.pushTarget, apns.configured {
            let apns = self.apns, id = share.id
            Task.detached { await apns.push(token: target.token, env: target.env, label: label, share: id) }
        }
        Log.write("share: ringing \(name) for \(share.label)")
        var deadline = Date().addingTimeInterval(Self.ringTimeout)
        while !line.callActive {
            if line.takeLater() != nil { Log.write("share: \(name) can't talk now"); return false }
            if line.takeDeclined() { deadline = min(deadline, Date()) }
            guard Date() < deadline else { Log.write("share: \(name) didn't pick up"); return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    /// Just let in: Parley rings the guest and welcomes him, then hangs up (nothing to answer).
    func welcomeGuest(_ line: PhoneHub, text: String, share: Share) async {
        guard await ringGuest(line, label: "Willkommen · \(share.label)", share: share) else { return }
        let config = AppConfig.load()
        line.setSpeaker(share.label)
        await speakToGuest(line, text, beep: false, config: config)
        if line.callActive { line.setAudioState(.idle) }   // the phone hangs up once the line goes quiet
    }

    // "Hey Parley" during a call: greeting → listen → route the utterance to a running session
    // or the Zentrale → confirm. Nothing said → nothing happens.
    private func runWake() async -> TurnReply {
        let none = TurnReply(transcript: "", park: false)
        guard phone.callActive else { Log.write("wake: call gone — skipped"); return none }
        let config = AppConfig.load()
        await ackTask?.value
        ackTask = nil
        Log.write("wake: greeting")
        let (clip, line) = await ProjectClips.shared.greetClip(config: config)
        await speakAndBeep(line, config: config, prefetched: clip, beep: true)
        LiveStatus.set(phase: "listening")
        let wav = await record()
        LiveStatus.set(phase: "transcribing")
        let text = await transcribe(wav, config: config)
        guard !text.isEmpty else { Log.write("wake: nothing said"); return none }

        let target = await WakeRouter.route(text, sessions: server.routeTargets(), apiKey: config.groqKey) { req in
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        }
        let confirmation: String
        if let id = target.id {
            server.deliverRouted(id: id, instruction: text)
            confirmation = "Verstanden, ich gebe das an \(target.label) weiter."
        } else {
            // The Zentrale is Parley itself — it takes the job on, it doesn't pass it on.
            _ = deliverToZentrale(text)
            confirmation = Zentrale.takeOver.randomElement()!
        }
        Log.write("wake: \"\(text.prefix(80))\" → \(target.label)")
        await speakLine(confirmation, config: config)
        return none
    }

    // The Zentrale's folder (created from the template when missing), then POST /dispatch's
    // path: delivered if it runs, else pending + a session started. true = started now.
    private func deliverToZentrale(_ text: String) -> Bool {
        let z = ZentraleSettings.load()
        do {
            if try Zentrale.ensure(z, template: Zentrale.templateDir()) { Log.write("zentrale: created \(z.zentraleDir)") }
        } catch {
            Log.write("zentrale: could not create \(z.zentraleDir): \(error.localizedDescription)")
        }
        return server.dispatch(cwd: z.zentraleDir, instruction: text, start: true).started
    }

    // POST /permission: "<Projekt> möchte … — erlauben?", listen; the server decides from the
    // transcript ("" → ask: the normal on-screen prompt).
    private func runPermission(_ turn: TurnPayload) async -> TurnReply {
        let none = TurnReply(transcript: "", park: false)
        let config = AppConfig.load()
        resumeGen += 1
        let ringing = shouldRing
        if effectivelyMuted && !phone.callActive && !ringing { Log.write("muted → permission left to the screen"); return none }
        if ringing { _ = await reachPhone(label: turn.spokenLabel, session: ControlServer.sessionKey(turn), key: nil, callBack: false) }
        if effectivelyMuted && !phone.callActive { return none }
        if phone.away && !phone.callActive { Log.write("Unterwegs, phone not reached → permission left to the screen"); return none }
        await ackTask?.value
        ackTask = nil
        await pauseMediaIfPlaying()
        Log.write("permission: asking \"\(turn.speak)\"")
        await speakAndBeep(turn.speak, config: config, beep: true)
        LiveStatus.set(phase: "listening")
        let wav = await record()
        LiveStatus.set(phase: "transcribing")
        let text = await transcribe(wav, config: config)
        let decision = PermissionPrompt.decide(text)
        startAck(intent: decision == .allow ? .cont : (decision == .deny ? .stop : .other),
                 hasText: decision != .ask, config: config)
        return TurnReply(transcript: text, park: false)
    }

    // A Wiedervorlage for Sir (Reminders.swift), spoken like an update: the phone rings when
    // Unterwegs; muted, Stumm or not reached → a notification (and an alert on the phone).
    private func runReminder(_ turn: TurnPayload) async -> TurnReply {
        let none = TurnReply(transcript: "", park: false)
        let config = AppConfig.load()
        resumeGen += 1
        if !(phone.away && phone.silent), shouldRing { _ = await reachPhone(label: "Parley", session: "", key: nil) }
        if (effectivelyMuted || phone.away) && !phone.callActive {
            Log.write("reminder → notification")
            Notifier.notify(title: "Parley · Erinnerung", body: turn.speak)
            if phone.away, let target = phone.alertTarget {
                let apns = self.apns, body = turn.speak
                Task.detached { await apns.notify(token: target.token, env: target.env, title: "Parley · Erinnerung", body: body, session: "") }
            }
            return none
        }
        await ackTask?.value
        ackTask = nil
        await pauseMediaIfPlaying()
        await speakAndBeep(turn.speak, config: config, beep: false, last: server.nothingQueued())
        scheduleResume()
        return none
    }

    // "Push-Schlüssel wählen…": the APNs auth key (AuthKey_<KEYID>.p8) → credentials.json.
    func choosePushKey() {
        let panel = NSOpenPanel()
        panel.title = "APNs-Schlüssel wählen (AuthKey_<KEYID>.p8)"
        panel.allowedContentTypes = [UTType(filenameExtension: "p8") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let keyId = APNs.keyId(fileName: url.lastPathComponent) else {
            alert("Kein APNs-Schlüssel", "Der Dateiname muss AuthKey_<KEYID>.p8 sein — so lädt Apple den Schlüssel herunter.")
            return
        }
        guard let pem = try? String(contentsOf: url, encoding: .utf8), (try? APNs.privateKey(pem: pem)) != nil else {
            alert("Schlüssel nicht lesbar", "\(url.lastPathComponent) enthält keinen gültigen P-256-Schlüssel.")
            return
        }
        let team = Keychain.get(.apnsTeamId) ?? ""
        Keychain.set(keyId, for: .apnsKeyId)
        Keychain.set(team.isEmpty ? APNsCredentials.defaultTeam : team, for: .apnsTeamId)
        Keychain.set(pem, for: .apnsKeyP8)
        pushKeyId = keyId
        Log.write("apns: push key \(keyId) stored")
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // Fuzzy-match a spoken project name to a resumable session (either contains the other).
    private func matchParked(_ spoken: String, in list: [ParkedInfo]) -> ParkedInfo? {
        let t = spoken.lowercased().trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return list.first { p in
            let l = p.label.lowercased()
            return l == t || l.contains(t) || t.contains(l)
        }
    }

    private var ackTask: Task<Void, Never>?
    struct AckLine { var say: String; var clip: Data? }   // a matched <reply>: its line + pre-rendered audio

    // Pause anything playing and remember it for the deferred resume; 0.4s beat if we
    // actually paused something. osascript/perl are blocking → off the main actor.
    private func pauseMediaIfPlaying() async {
        guard !phone.callActive else { return }   // the Mac's media doesn't compete with a phone call
        let newly = await Task.detached { MediaControl.shared.pausePlaying() }.value
        guard !newly.isEmpty else { return }
        for t in newly where !pendingMediaResume.contains(t) { pendingMediaResume.append(t) }
        Log.write("paused media: \(newly.joined(separator: ","))")
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    // Media paused across the whole queued conversation burst; resumed only once no
    // further turn is waiting (a queued turn would immediately re-pause it anyway).
    private var pendingMediaResume: [String] = []
    private var hasQueuedTurn: Bool { sessions.contains { $0.status == "queued" } }
    // Bumped whenever a new turn begins; a pending debounced resume checks it and bails if
    // the burst continued — so media only resumes after the WHOLE audio cue is done.
    private var resumeGen = 0

    // Debounced, fire-and-forget: waits out a short grace so a following turn (queued now
    // or arriving within the window) can pre-empt the resume. Only resumes once nothing is
    // queued and no newer turn started. Never awaited by the pipeline (no added latency).
    private func scheduleResume() {
        guard !pendingMediaResume.isEmpty else { return }
        let gen = resumeGen
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)   // grace: let the next clip/turn pre-empt
            guard gen == self.resumeGen, !self.hasQueuedTurn, !self.pendingMediaResume.isEmpty else {
                Log.write("media resume skipped (cue continued)"); return
            }
            let tokens = self.pendingMediaResume
            self.pendingMediaResume = []
            await self.waitForHiFiOutput()
            await Task.detached { MediaControl.shared.resume(tokens) }.value
            Log.write("resumed media: \(tokens.joined(separator: ","))")
        }
    }

    // AirPods: releasing the mic makes Bluetooth renegotiate from HFP (16/24 kHz) back to
    // hi-fi A2DP — audio played/resumed during the switch is swallowed. Wait until the
    // output device is back at a hi-fi rate (instant on speakers; 3s cap).
    private func waitForHiFiOutput() async {
        guard !phone.callActive else { return }   // the voice goes to the phone
        let start = Date()
        while let sr = AudioDevices.defaultOutputSampleRate(), sr < 40_000,
              Date().timeIntervalSince(start) < 3.0 {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        let waited = Date().timeIntervalSince(start)
        if waited > 0.2 { Log.write("waited \(String(format: "%.1f", waited))s for hi-fi output") }
    }

    // Settle after mic teardown, then play the intent's cached Jarvis line (or a chime) —
    // but only once the output is back in hi-fi mode (AirPods HFP→A2DP switch), else the
    // ack clip itself gets swallowed.
    private func playAck(intent: Intent, hasText: Bool, line: AckLine?, config: AppConfig) async {
        var own: Data? = line?.clip
        if own == nil, let line { own = await GoogleTTS.synth(line.say, config: config, timeout: 6) }   // not rendered in time
        try? await Task.sleep(nanoseconds: 300_000_000)
        await waitForHiFiOutput()
        if let own {
            await playClip(own, rate: config.speakingRate)
        } else if hasText, let data = LineClips.randomClipData(for: intent) {
            await playClip(data, rate: config.speakingRate)
        } else {
            await playChime()
        }
    }

    // Speak the summary + beep, then FULLY release the audio output device before the
    // mic engine starts. A still-running (or merely stopped-but-alive) output engine
    // starves the input engine → the mic tap never fires (0 buffers). Fresh player per
    // turn + explicit release + a short settle avoids that device contention.
    // During a call the line goes to the phone; if the call ends first, the part not yet heard
    // (and the beep) plays on the Mac.
    private func speakAndBeep(_ text: String, config: AppConfig, prefetched: Data? = nil, beep: Bool = true,
                              slides: [SlideSpec] = [], session: String = "", last: Bool = false) async {
        if phone.callActive {
            let voice = PhoneVoice(link: phone, rate: config.speakingRate)
            var captioned = false
            await synthesize(text, config: config, prefetched: prefetched) { pcm in
                // Live captions: word times from the (whole, Google) line, just before its first
                // frame — and the line's slides at the times of their words, images after.
                if !captioned {
                    let t = config.useGoogle
                        ? Captions.timings(text: text, pcm: pcm, sampleRate: PhoneAudioFormat.ttsRate, rate: config.speakingRate) : nil
                    if let t { phone.reply(Captions.frame(t, last: last)) }
                    Log.write("phone: caption \(t.map { "\($0.words.count) words, \(Int($0.end)) s" } ?? "none")")
                    if !slides.isEmpty { sendSlides(slides, timed: t, session: session) }
                }
                captioned = true
                voice.enqueue(pcm)
            }
            guard let rest = await voice.finish(beep: beep) else { return }
            if phone.away { Log.write("phone: call ended while speaking (Unterwegs → not on the Mac)"); return }
            Log.write("phone: call ended while speaking → the rest on the Mac's speaker")
            await speakLocal(text, config: config, prefetched: rest, beep: beep)
            return
        }
        await speakLocal(text, config: config, prefetched: prefetched, beep: beep)
    }

    // The line's 24 kHz PCM into `sink`: the prefetched synthesis, else Google (inline retry),
    // else ElevenLabs (streamed).
    private func synthesize(_ text: String, config: AppConfig, prefetched: Data?, into sink: (Data) -> Void) async {
        if let pcm = prefetched {
            sink(pcm)
            Log.write("google tts prefetched (\(pcm.count) bytes)")
        } else if config.useGoogle {
            await synthGoogle(text, config: config, into: sink)   // prefetch failed → inline retry
        } else if config.ttsReady {
            await synthElevenLabs(text, config: config, into: sink)
        } else {
            NSLog("Parley: TTS not configured")
        }
    }

    private func speakLocal(_ text: String, config: AppConfig, prefetched: Data?, beep: Bool) async {
        // Unterwegs: the Mac stays silent; only a call voices anything.
        if phone.away { Log.write("Unterwegs → not on the Mac's speaker"); return }
        let player = TTSPlayer(rate: config.speakingRate)
        localBarged = false
        localPreroll = []
        let watch = text.isEmpty ? nil : watchForBarge(text, player: player)
        speaking = player
        do { try player.start() } catch { Log.write("tts engine start failed: \(error)") }
        await synthesize(text, config: config, prefetched: prefetched) { if !localBarged { player.enqueue(pcmChunk: $0) } }
        // Audible "you can talk now" beep after the speech — but ONLY on listen turns.
        // A speak-end turn plays a silent 0.02s finish marker instead (no cue: nobody is
        // being asked to talk). Beeping BEFORE the mic starts is fine because the prepared
        // AUHAL start is near-instant; beeping AFTER mic start is silent on this system.
        // A barge-in cuts the voice (its silence() fires the beep's completion) and skips the beep.
        if !localBarged {
            await withCheckedContinuation { cont in
                if beep { player.scheduleBeep { cont.resume() } }
                else { player.scheduleBeep(seconds: 0.02, amplitude: 0.0) { cont.resume() } }
            }
            if !localBarged { try? await Task.sleep(nanoseconds: 120_000_000) }
        }
        speaking = nil
        player.stop()
        if let watch { localPreroll = watch() }
        // Minimal settle before the mic claims the device — AUHAL needs far less than the
        // old cold engine start; the watchdog covers the rare stuck case.
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    /// Barge-in at the Mac: an on-device recognizer listens while `player` speaks `line` —
    /// through the player's echo-cancelled mic (speakers), or the built-in mic when the voice
    /// goes to Bluetooth headphones (no echo there; their own mic would drop them to call
    /// quality). Returns the stop, which hands back the last 2 s of mic; nil = not listening.
    private func watchForBarge(_ line: String, player: TTSPlayer) -> (() -> [Int16])? {
        guard bargeIn, let monitor = BargeMonitor(line: line) else { return nil }
        monitor.onBarge = { Task { @MainActor [weak self] in self?.bargeHeard() } }
        let feed: @Sendable (AVAudioPCMBuffer) -> Void = { monitor.feed($0) }
        if let out = AudioDevices.defaultDevice(input: false), AudioDevices.isBluetooth(out) {
            // ponytail: a Bluetooth *speaker* echoes into the built-in mic un-cancelled; the word
            // rule (only words not in the line count) is the guard there.
            guard let builtIn = AudioDevices.builtInInput() else { return nil }
            let mic = AUHALInput()
            guard mic.prepare(device: builtIn), mic.start(onBuffer: feed) else { mic.teardown(); return nil }
            monitor.start()
            Log.write("barge: listening on the built-in mic")
            return { mic.teardown(); return monitor.stop() }
        }
        guard player.listen(feed) else { return nil }
        monitor.start()
        Log.write("barge: listening (echo-cancelled)")
        return { monitor.stop() }
    }

    private func bargeHeard() {
        guard let speaking, !localBarged else { return }
        localBarged = true
        speaking.silence()
        Log.write("barge-in at the Mac: Parley stops")
    }

    private func takeLocalBarge() -> Bool {
        defer { localBarged = false }
        return localBarged
    }

    // Google Cloud TTS (Chirp3 HD): one-shot synthesize → PCM → enqueue.
    private func synthGoogle(_ text: String, config: AppConfig, into sink: (Data) -> Void) async {
        let req = GoogleTTS.request(text: text, apiKey: config.googleKey, voice: config.googleVoice)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200, let pcm = GoogleTTS.pcm(from: data) else {
                Log.write("google tts http \(code): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
                lastError = "Google TTS HTTP \(code)"
                Notifier.notify(title: "Parley — Fehler",
                                body: code == 429 ? "Google-Kontingent erschöpft." : "Sprachausgabe fehlgeschlagen (HTTP \(code)).")
                return
            }
            sink(pcm)
            Log.write("google tts ok (\(pcm.count) bytes, \(config.googleVoice))")
        } catch {
            Log.write("google tts error: \(error.localizedDescription)")
            lastError = "Google TTS: \(error.localizedDescription)"
        }
    }

    private func synthElevenLabs(_ text: String, config: AppConfig, into sink: (Data) -> Void) async {
        let req = ElevenLabs.streamRequest(
            text: text, config: .init(apiKey: config.elevenLabsKey, voiceID: config.voiceID))
        do {
            Log.write("elevenlabs streaming")
            let (bytes, _) = try await URLSession.shared.bytes(for: req)
            var chunk = Data()
            for try await b in bytes {
                chunk.append(b)
                if chunk.count >= 4096 { sink(chunk); chunk.removeAll(keepingCapacity: true) }
            }
            if !chunk.isEmpty { sink(chunk) }
            Log.write("elevenlabs stream complete")
        } catch {
            Log.write("tts error: \(error.localizedDescription)")
            lastError = "TTS: \(error.localizedDescription)"
        }
    }

    // MARK: - onboarding tutorial helpers (reuse the real audio + mic + classifier)

    /// Play a pre-rendered tutorial line (settled + hi-fi, so it's audible after any prior IO).
    func onboardingSpeak(_ pcm: Data) async {
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard !Task.isCancelled else { return }
        await waitForHiFiOutput()
        guard !Task.isCancelled else { return }

        let player = TTSPlayer(rate: AppConfig.load().speakingRate)
        do { try player.start() } catch { return }
        onboardingPlayer = player
        player.enqueue(pcmChunk: pcm)
        let seconds = Double(pcm.count / 2) / ElevenLabs.sampleRate / max(0.5, AppConfig.load().speakingRate)
        try? await Task.sleep(nanoseconds: UInt64((seconds + 0.3) * 1_000_000_000))
        player.stop()
        if onboardingPlayer === player { onboardingPlayer = nil }
    }

    /// Stop a tutorial line immediately when the user advances, goes back, or skips.
    func stopOnboardingSpeak() {
        onboardingPlayer?.stop()
        onboardingPlayer = nil
    }

    /// Record one reply (shows the pill) and report what the user did — for the interactive
    /// tutorial steps. Returns the transcript + whether it was STOP + any wait seconds.
    func onboardingListen() async -> (text: String, isStop: Bool, waitSeconds: Int) {
        let cfg = AppConfig.load()
        let wav = await record()
        let text = await transcribe(wav, config: cfg)
        guard !text.isEmpty else { return ("", false, 0) }
        async let intent = classify(text, config: cfg)
        async let wait = extractWait(text, config: cfg)
        let (i, w) = await (intent, wait)
        return (text, i == .stop, w)
    }

    // Seconds the user asked to wait (0 = not a wait request).
    private func extractWait(_ text: String, config: AppConfig) async -> Int {
        guard !config.groqKey.isEmpty else { return 0 }
        do {
            let (data, resp) = try await URLSession.shared.data(for: Classifier.waitRequest(text: text, apiKey: config.groqKey))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return 0 }
            return Classifier.parseWait(data)
        } catch { return 0 }
    }

    // A line's slides to the phone: the timed list now, each image as it is ready.
    private func sendSlides(_ specs: [SlideSpec], timed: Captions.Timed?, session: String, to line: PhoneHub? = nil) {
        let phone = line ?? self.phone   // a guest's call line, else Sir's
        let items = Slides.items(specs, timed: timed, prefix: "slide-\(UUID().uuidString.prefix(8))")
        phone.reply(Slides.frame(items))
        Log.write("phone: \(items.count) slide(s) for this line")
        let images = zip(specs, items).compactMap { s, o in s.image.map { (o.id, $0) } }
        guard !images.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            for (id, source) in images {
                phone.reply(Transcript.imageFrame(key: id, jpeg: Slides.image(source, session: session)))
            }
        }
    }

    // Speak a one-off line (no beep, no listen) — used for the wait confirmation. Settles
    // after the mic teardown + waits for hi-fi output first (same as playAck), otherwise the
    // line renders into a still-contended device and is silent.
    private func speakLine(_ text: String, config: AppConfig) async {
        guard config.useGoogle, let pcm = await GoogleTTS.synth(text, config: config, timeout: 6) else { return }
        try? await Task.sleep(nanoseconds: 300_000_000)
        await waitForHiFiOutput()
        if phone.callActive, let t = Captions.timings(text: text, pcm: pcm, sampleRate: PhoneAudioFormat.ttsRate, rate: config.speakingRate) {
            phone.reply(Captions.frame(t))
        }
        await playClip(pcm, rate: config.speakingRate)
    }

    private func humanDuration(_ seconds: Int) -> String {
        if seconds % 60 == 0 { let m = seconds / 60; return m == 1 ? "eine Minute" : "\(m) Minuten" }
        if seconds < 60 { return "\(seconds) Sekunden" }
        return "\(seconds / 60) Minuten und \(seconds % 60) Sekunden"
    }

    // The session's predicted answer the transcript matches (index), nil = none / no Groq.
    private func pickReply(_ text: String, options: [String], config: AppConfig) async -> Int? {
        guard !options.isEmpty, !config.groqKey.isEmpty,
              let (data, resp) = try? await URLSession.shared.data(for: Classifier.replyRequest(text: text, options: options, apiKey: config.groqKey)),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Classifier.parseReply(data, count: options.count)
    }

    private func classify(_ text: String, config: AppConfig) async -> Intent {
        guard !config.groqKey.isEmpty else { return .other }
        do {
            let (data, resp) = try await URLSession.shared.data(for: Classifier.request(text: text, apiKey: config.groqKey))
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                Log.write("groq classify http \(code): \(String(data: data, encoding: .utf8)?.prefix(160) ?? "")")
                return .other
            }
            return Classifier.parse(data)
        } catch { return .other }
    }

    private func playClip(_ data: Data, rate: Double = 1.0) async {
        var data = data
        if phone.callActive {
            let voice = PhoneVoice(link: phone, rate: rate)
            voice.enqueue(data)
            guard let rest = await voice.finish(beep: false) else { return }
            Log.write("phone: call ended during a clip → the rest on the Mac's speaker")
            data = rest
            guard !data.isEmpty else { return }
        }
        if phone.away { return }   // Unterwegs: never on the Mac's speaker
        let player = TTSPlayer(rate: rate)
        do { try player.start() } catch { return }
        player.enqueue(pcmChunk: data)
        let seconds = Double(data.count / 2) / ElevenLabs.sampleRate / max(0.5, rate)   // faster rate → shorter
        try? await Task.sleep(nanoseconds: UInt64((seconds + 0.3) * 1_000_000_000))
        player.stop()
    }

    private func playChime() async {
        if phone.callActive {
            let voice = PhoneVoice(link: phone, rate: 1)
            voice.enqueue(PCMFrames.bytes(PCMFrames.int16(Tones.turnChime(sampleRate: Double(PhoneAudioFormat.ttsRate)))))
            if await voice.finish(beep: false) == nil { return }   // call ended → chime on the Mac
        }
        if phone.away { return }   // Unterwegs: never on the Mac's speaker
        let player = TTSPlayer()
        do { try player.start() } catch { Log.write("chime start failed: \(error)"); return }
        player.scheduleChime(frequency: 523.25, seconds: 0.32, amplitude: 0.4, decay: 8)
        await withCheckedContinuation { cont in
            player.scheduleChime(frequency: 783.99, seconds: 0.6, amplitude: 0.4, decay: 5.5) { cont.resume() }
        }
        player.stop()
    }

    // During a call the reply comes from the phone's mic. A call that ends before anything was
    // said hands the listening to the Mac (beep first, so the user knows); a started reply is kept.
    /// `preroll`: barge-in — Sir already started talking, so the phone's last seconds count too.
    private func record(preroll: Bool = false) async -> Data {
        if phone.callActive {
            hud.show()
            let hud = self.hud
            let outcome = await PhoneListener(link: phone).record(preroll: preroll ? phone.recentMic() : []) { level in
                Task { @MainActor in hud.push(level) }
            }
            hud.finish()
            switch outcome {
            case .finished(let wav):
                return wav
            case .callEnded(let wav, let spoke):
                if spoke { return wav }
                if phone.away { Log.write("phone: call ended before a reply (Unterwegs → not on the Mac)"); return Data() }
                Log.write("phone: call ended before a reply → listening on the Mac")
                await speakLocal("", config: AppConfig.load(), prefetched: Data(), beep: true)
            }
        }
        // Unterwegs: the Mac never listens (only a call does).
        if phone.away { Log.write("Unterwegs → no listening on the Mac"); return Data() }
        hud.show()
        mic.onLevel = { [weak self] level in
            LiveStatus.push(level)
            Task { @MainActor in self?.hud.push(level) }
        }
        let wav = await withCheckedContinuation { cont in
            mic.start(preroll: preroll ? localPreroll : []) { wav in cont.resume(returning: wav) }
        }
        mic.onLevel = nil
        hud.finish()
        return wav
    }

    private func transcribe(_ wav: Data, config: AppConfig) async -> String {
        await transcribeChecked(wav, config: config) ?? ""
    }

    // nil = the transcription failed (not configured, HTTP error, network); "" = nothing said.
    private func transcribeChecked(_ wav: Data, config: AppConfig) async -> String? {
        guard config.sttReady else { NSLog("Parley: STT not configured"); return nil }
        // Too little captured audio → skip Groq (it rejects < 0.01s) and end cleanly.
        // 44-byte WAV header + ~0.2s of 16 kHz mono 16-bit.
        let minBytes = 44 + (16000 * 2) / 5
        guard wav.count >= minBytes else {
            NSLog("Parley: recording too short (\(wav.count) bytes) — no reply, no speech or no mic input")
            return ""
        }
        var req = Groq.transcriptionRequest(wav: wav, apiKey: config.groqKey, boundary: "parleyBoundary")
        req.timeoutInterval = 20   // fail fast instead of hanging the hook for the 60s default
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                NSLog("Parley: STT HTTP \(code): \(body)")
                lastError = "STT HTTP \(code)"
                // Groq blocks VPN / datacenter IPs with a 403 "check your network settings".
                let hint = code == 403 ? "Groq blockt dieses Netzwerk — VPN aus?" : "Transkription fehlgeschlagen (HTTP \(code))."
                Notifier.notify(title: "Parley — Fehler", body: hint)
                return nil   // never feed an error body back as the reply
            }
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let clean = Groq.cleanTranscript(text)
            if clean.isEmpty && !text.isEmpty { Log.write("stt: dropped Whisper hallucination \"\(text)\"") }
            return clean
        } catch {
            NSLog("Parley: STT error: \(error.localizedDescription)")
            lastError = "STT: \(error.localizedDescription)"
            Notifier.notify(title: "Parley — Fehler", body: "Groq nicht erreichbar (Netzwerk/VPN?).")
            return nil
        }
    }

    // MARK: - iPhone relay (docs/IPHONE.md)

    // "Handy verbinden…": with a relay configured, make sure room + secret exist, connect, and
    // open the relay's pairing page (QR code) in the browser; without one, say how to set it.
    func pairIPhone() {
        guard let config = RelayConfig.pair(), let page = RelayLink.pairPage(config) else {
            showRelayHint()
            return
        }
        startRelay()
        NSWorkspace.shared.open(page)
    }

    // Connect to the relay when it is configured (launch, pairing); a no-op on unchanged settings.
    func startRelay() {
        let config = RelayConfig.load().withKey()
        guard relay?.config != config else { return }
        stopRelay()
        let server = self.server
        guard let client = RelayClient(config: config, sessions: { server.sessionsJSON() },
                                       resume: { server.resumeFromRelay(id: $0) }) else { return }
        relayGen += 1
        let gen = relayGen
        let phone = self.phone
        client.onEvent = { phone.handle($0) }
        client.onAudio = { phone.audioIn($0) }
        phone.attach(text: { [weak client] in client?.sendText($0) }, audio: { [weak client] in client?.sendAudio($0) })
        client.onState = { [weak self] up in
            if !up { phone.handle(.call(false)) }   // no relay, no call audio
            Task { @MainActor in
                guard let self, self.relayGen == gen else { return }
                self.relayConnected = up
            }
        }
        relay = client
        relayConnected = false
        client.start()
    }

    func stopRelay() {
        relay?.stop()
        relay = nil
        relayConnected = nil
        phone.detach()
    }

    private func showRelayHint() {
        let alert = NSAlert()
        alert.messageText = "Relay nicht eingerichtet"
        alert.informativeText = """
            Fürs iPhone braucht Parley die Adresse deines Relays. Trag sie in credentials.json ein, \
            z. B. "relayUrl": "https://parley-relay.<konto>.workers.dev", und wähle dann erneut \
            „Handy verbinden…“.

            \(Keychain.fileURL.path)
            """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Im Finder zeigen")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([Keychain.fileURL])
        }
    }

    // MARK: - session table helpers

    private func routeKey(_ pane: String, _ session: String?) -> String {
        pane.isEmpty ? (session ?? "unknown") : pane
    }

    private func upsert(_ info: SessionInfo) {
        if let i = sessions.firstIndex(where: { $0.id == info.id }) { sessions[i] = info }
        else { sessions.append(info) }
    }

    private func setStatus(_ id: String, _ status: String) {
        LiveStatus.set(phase: status)
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].status = status
    }
}

// Completion flag readable from the smart-pause poll loop (prefetch task sets it).
final class SynthFlag: @unchecked Sendable { var done = false }
