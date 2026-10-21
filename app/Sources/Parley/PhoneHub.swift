import Foundation

// The host's side of the phone (docs/IPHONE.md, protocol v2): whether a call is connected,
// Unterwegs-Modus, the VoIP push token, the `audio` state frames, and where the phone's mic
// frames go. The relay client feeds it; the audio code reads it as its CallLink.
//
// Unterwegs-Modus and the push token are kept in credentials.json: away, the phone is usually
// NOT connected to the relay (iOS suspends the app), so the host must still know to ring it.
// ponytail: @unchecked Sendable — every field is behind `lock`; callbacks are set once at startup.
final class PhoneHub: CallLink, @unchecked Sendable {
    struct Store: Sendable {
        var get: @Sendable (Keychain.Key) -> String?
        var set: @Sendable (String, Keychain.Key) -> Void

        static let credentials = Store(get: { Keychain.get($0) }, set: { Keychain.set($0, for: $1) })

        // In memory, for tests.
        static func memory() -> Store {
            final class Box: @unchecked Sendable { var d: [Keychain.Key: String] = [:]; let l = NSLock() }
            let b = Box()
            return Store(get: { k in b.l.withLock { b.d[k] } },
                         set: { v, k in b.l.withLock { b.d[k] = v.isEmpty ? nil : v } })
        }
    }

    var onChange: (@Sendable () -> Void)?   // call or Unterwegs-Modus changed (menu)
    var onWake: (@Sendable () -> Void)?     // `wake` during a connected call
    var onChat: (@Sendable (PhoneEvent) -> Void)?   // history / image / say (v3)

    private let lock = NSLock()
    private let store: Store
    private let log: @Sendable (String) -> Void
    private var active = false
    private var generation = 0
    private var desired: PhoneAudioState = .idle
    private var later: TimeInterval?? = nil       // the ringing phone's "not now" (see takeLater)
    private var declined = false                  // `call end` with no call: the ring was declined
    private var sentState: PhoneAudioState?
    private var rate = PhoneAudioFormat.sampleRate   // the call's down rate
    private var speaker: String?   // the session Parley voices now — sent with every `audio` frame
    private var sink: (@Sendable (Data) -> Void)?
    private var sendText: (@Sendable (String) -> Void)?
    private var sendBinary: (@Sendable (Data) -> Void)?

    init(store: Store = .credentials, log: @escaping @Sendable (String) -> Void = { Log.write($0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.log = log
        self.now = now
    }

    // MARK: - a call that is gone without a word

    // A call streams the phone's mic all the time (zeros when muted). Nothing for this long:
    // the phone has hung up and its `call end` got lost (the app suspended right after) — the
    // call is over here too, so the next update rings instead of talking into the void.
    static let silentCall: TimeInterval = 6
    private let now: @Sendable () -> Date
    private var lastAudio = Date.distantPast
    private var liveTimer: DispatchSourceTimer?

    // Internal for tests: one look (every second while a call runs).
    func checkAlive() {
        let gone = lock.withLock { active && now().timeIntervalSince(lastAudio) > Self.silentCall }
        guard gone else { return }
        log("phone: call gone — no audio from the phone for \(Int(Self.silentCall)) s (its \"call end\" got lost)")
        handle(.call(false))
    }

    private func watchAlive(_ on: Bool) {
        lock.withLock {
            liveTimer?.cancel()
            liveTimer = nil
            guard on else { return }
            let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in self?.checkAlive() }
            t.resume()
            liveTimer = t
        }
    }

    // MARK: - the relay link

    func attach(text: @escaping @Sendable (String) -> Void, audio: @escaping @Sendable (Data) -> Void) {
        lock.withLock { sendText = text; sendBinary = audio }
    }

    // The relay link is gone: no call can be connected through it any more.
    func detach() {
        lock.withLock { sendText = nil; sendBinary = nil }
        handle(.call(false))
    }

    // MARK: - state

    var callActive: Bool { lock.withLock { active } }
    var downRate: Int { lock.withLock { rate } }
    // Unterwegs: chosen on the phone, or the Mac locked for a minute (with that setting on).
    var away: Bool { chosenAway || lock.withLock { lockedAway } }
    var chosenAway: Bool { store.get(.phoneAway) == "1" }
    private var lockedAway = false

    func setLockedAway(_ on: Bool) {
        let changed = lock.withLock { () -> Bool in
            guard lockedAway != on else { return false }
            lockedAway = on
            return true
        }
        guard changed else { return }
        log(on ? "Mac gesperrt → Unterwegs" : "Mac entsperrt → zurück am Mac")
        onChange?()
    }
    var silent: Bool { store.get(.phoneSilent) == "1" }
    /// Fragerunde (the phone's settings): how long an update waits for others still at work.
    var roundSeconds: Int { store.get(.roundSeconds).flatMap(Int.init) ?? Self.roundDefault }
    static let roundDefault = 90, roundMax = 600

    // Where a notification push goes; nil until the phone sent its alert token.
    var alertTarget: (token: String, env: String)? {
        guard let t = store.get(.phoneAlertToken), !t.isEmpty else { return nil }
        return (t, store.get(.phonePushEnv) ?? "production")
    }

    // The Live Activity: its push-to-start token, and the running one's update token (nil = none).
    var activityStartTarget: (token: String, env: String)? {
        guard let t = store.get(.phoneActivityStart), !t.isEmpty else { return nil }
        return (t, store.get(.phonePushEnv) ?? "production")
    }
    var activityTarget: (token: String, env: String)? {
        guard let t = store.get(.phoneActivityToken), !t.isEmpty else { return nil }
        return (t, store.get(.phonePushEnv) ?? "production")
    }

    // Where a VoIP push goes; nil until the phone sent `push`.
    var pushTarget: (token: String, env: String)? {
        guard let t = store.get(.phonePushToken), !t.isEmpty else { return nil }
        return (t, store.get(.phonePushEnv) ?? "production")
    }

    // A phone frame (resume is handled by the server).
    func handle(_ event: PhoneEvent) {
        switch event {
        case .call(true, let down):
            let (changed, state, send) = lock.withLock { () -> (Bool, PhoneAudioState, (@Sendable (String) -> Void)?) in
                rate = down
                guard !active else { return (false, desired, nil) }   // a repeated start keeps the call
                active = true
                bargeFlag = false
                recent.removeAll()
                generation += 1
                sentState = desired
                lastAudio = now()
                return (true, desired, sendText)
            }
            guard changed else { return }
            watchAlive(true)
            log("phone: call connected (voice at \(down / 1000) kHz)")
            send?(RelayFrame.audio(state, label: lock.withLock { speaker }))
            onChange?()
        case .call(false, _):
            let changed = lock.withLock { () -> Bool in
                guard active else { declined = true; return false }
                active = false
                generation += 1
                sentState = nil
                return true
            }
            guard changed else { return }
            watchAlive(false)
            log("phone: call ended")
            onChange?()
        case .wake:
            guard callActive else { log("phone: wake without a call — ignored"); return }
            onWake?()
        case .push(let token, let env):
            guard store.get(.phonePushToken) != token || store.get(.phonePushEnv) != env else { return }
            store.set(token, .phonePushToken)
            store.set(env, .phonePushEnv)
            log("phone: VoIP push token stored (\(env))")
        case .away(let on):
            guard chosenAway != on else { return }
            store.set(on ? "1" : "0", .phoneAway)
            log("phone: Unterwegs-Modus \(on ? "an" : "aus")")
            onChange?()
        case .silent(let on):
            guard silent != on else { return }
            store.set(on ? "1" : "0", .phoneSilent)
            log("phone: Stumm \(on ? "an" : "aus")")
            onChange?()
        case .brief(let on):
            guard (store.get(.brief) == "1") != on else { return }
            store.set(on ? "1" : "", .brief)
            log("phone: Ohne Floskeln \(on ? "an" : "aus")")
            onChange?()
        case .round(let seconds):
            let s = min(Self.roundMax, max(0, seconds))
            guard roundSeconds != s else { return }
            store.set(String(s), .roundSeconds)
            log("phone: Fragerunde \(s == 0 ? "aus" : "bis \(s) s")")
        case .alert(let token, let env):
            guard store.get(.phoneAlertToken) != token else { return }
            store.set(token, .phoneAlertToken)
            store.set(env, .phonePushEnv)
            log("phone: notification push token stored (\(env))")
        case .activityStart(let token, let env):
            guard store.get(.phoneActivityStart) != token else { return }
            store.set(token, .phoneActivityStart)
            store.set(env, .phonePushEnv)
            log(token.isEmpty ? "phone: Live Activity push-to-start token dropped" : "phone: Live Activity push-to-start token stored (\(env))")
            onChange?()
        case .activity(let token, let env):
            guard (store.get(.phoneActivityToken) ?? "") != token else { return }
            store.set(token, .phoneActivityToken)
            if !token.isEmpty { store.set(env, .phonePushEnv) }
            log(token.isEmpty ? "phone: Live Activity ended" : "phone: Live Activity update token stored (\(env))")
            onChange?()
        case .later(let after):
            lock.withLock { later = .some(after) }
            log(after.map { "phone: not now — ring again in \(Int($0)) s" } ?? "phone: not now — Sir calls back")
        case .barge:
            guard lock.withLock({ () -> Bool in
                guard active else { return false }
                bargeFlag = true
                return true
            }) else { return }
            log("phone: Sir interrupts — stopping the line")
        case .history, .image, .say, .hello, .paletteSaved, .snapshotSave, .snapshotOpen, .snapshotDelete,
             .shareCreate, .shareApprove, .shareRemove, .join, .answer:
            onChat?(event)
        case .resume:
            break
        }
    }

    // A binary frame from the relay: the phone's mic.
    func audioIn(_ frame: Data) {
        let s = lock.withLock { () -> (@Sendable (Data) -> Void)? in
            guard active else { return nil }
            lastAudio = now()
            recent.append(frame)
            if recent.count > Self.prerollFrames { recent.removeFirst(recent.count - Self.prerollFrames) }
            return sink
        }
        s?(frame)
    }

    // MARK: - barge-in

    static let prerollFrames = 100   // 2 s of the phone's mic (20 ms frames)
    private var recent: [Data] = []
    private var bargeFlag = false

    /// Sir talked over Parley (the phone heard it): the line stops; the listener starts with `recentMic`.
    var barged: Bool { lock.withLock { bargeFlag } }

    func takeBarge() -> Bool {
        lock.withLock {
            defer { bargeFlag = false }
            return bargeFlag
        }
    }

    /// The last 2 s of the phone's mic — what Sir said before the host listened.
    func recentMic() -> [Data] { lock.withLock { recent } }

    // `ring` to the phones (one in the foreground shows its own incoming call).
    func ring(label: String) {
        let send = lock.withLock { sendText }
        send?(RelayFrame.ring(label: label))
    }

    /// The ringing phone's "not now", once: .some(seconds) = ring again then, .some(nil) = Sir
    /// calls back himself, nil = nothing said.
    func takeLater() -> TimeInterval?? {
        lock.withLock { defer { later = nil }; return later }
    }

    /// A declined ring, once (the phone may still send a "not now" from its notification).
    func takeDeclined() -> Bool {
        lock.withLock { defer { declined = false }; return declined }
    }

    // Waits up to `timeout` for a call to connect; true as soon as one is.
    func waitForCall(timeout: TimeInterval, poll: TimeInterval = 0.1) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !callActive {
            guard Date() < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
        }
        return true
    }

    // MARK: - CallLink

    var callGeneration: Int { lock.withLock { generation } }

    func isLive(_ generation: Int) -> Bool { lock.withLock { active && self.generation == generation } }

    // A text frame to the phone (v3 answers: history, image), whether or not a call is up.
    func reply(_ frame: String) {
        lock.withLock { sendText }?(frame)
    }

    func sendAudio(_ frame: Data) {
        let send = lock.withLock { active ? sendBinary : nil }
        send?(frame)
    }

    // Tracked always; sent (on change) only while a call is connected.
    func setAudioState(_ state: PhoneAudioState) {
        let send = lock.withLock { () -> (@Sendable (String) -> Void)? in
            desired = state
            guard active, sentState != state else { return nil }
            sentState = state
            return sendText
        }
        send?(RelayFrame.audio(state, label: lock.withLock { speaker }))
    }

    // The session whose turn is voiced now: the phone's call screen (and CallKit) names it.
    // A change mid-call goes out at once with the current state.
    func setSpeaker(_ label: String) {
        let out = lock.withLock { () -> (String, (@Sendable (String) -> Void)?)? in
            guard speaker != label else { return nil }
            speaker = label
            guard active else { return nil }
            sentState = desired
            return (RelayFrame.audio(desired, label: label), sendText)
        }
        if let (frame, send) = out { send?(frame) }
    }

    func setAudioSink(_ sink: (@Sendable (Data) -> Void)?) {
        lock.withLock { self.sink = sink }
    }
}
