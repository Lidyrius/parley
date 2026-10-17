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
    private var sentState: PhoneAudioState?
    private var speaker: String?   // the session Parley voices now — sent with every `audio` frame
    private var sink: (@Sendable (Data) -> Void)?
    private var sendText: (@Sendable (String) -> Void)?
    private var sendBinary: (@Sendable (Data) -> Void)?

    init(store: Store = .credentials, log: @escaping @Sendable (String) -> Void = { Log.write($0) }) {
        self.store = store
        self.log = log
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
    var away: Bool { store.get(.phoneAway) == "1" }
    var silent: Bool { store.get(.phoneSilent) == "1" }

    // Where a notification push goes; nil until the phone sent its alert token.
    var alertTarget: (token: String, env: String)? {
        guard let t = store.get(.phoneAlertToken), !t.isEmpty else { return nil }
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
        case .call(true):
            let (changed, state, send) = lock.withLock { () -> (Bool, PhoneAudioState, (@Sendable (String) -> Void)?) in
                guard !active else { return (false, desired, nil) }   // a repeated start keeps the call
                active = true
                generation += 1
                sentState = desired
                return (true, desired, sendText)
            }
            guard changed else { return }
            log("phone: call connected")
            send?(RelayFrame.audio(state, label: lock.withLock { speaker }))
            onChange?()
        case .call(false):
            let changed = lock.withLock { () -> Bool in
                guard active else { return false }
                active = false
                generation += 1
                sentState = nil
                return true
            }
            guard changed else { return }
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
            guard away != on else { return }
            store.set(on ? "1" : "0", .phoneAway)
            log("phone: Unterwegs-Modus \(on ? "an" : "aus")")
            onChange?()
        case .silent(let on):
            guard silent != on else { return }
            store.set(on ? "1" : "0", .phoneSilent)
            log("phone: Stumm \(on ? "an" : "aus")")
            onChange?()
        case .alert(let token, let env):
            guard store.get(.phoneAlertToken) != token else { return }
            store.set(token, .phoneAlertToken)
            store.set(env, .phonePushEnv)
            log("phone: notification push token stored (\(env))")
        case .history, .image, .say:
            onChat?(event)
        case .resume:
            break
        }
    }

    // A binary frame from the relay: the phone's mic.
    func audioIn(_ frame: Data) {
        let s = lock.withLock { active ? sink : nil }
        s?(frame)
    }

    // `ring` to the phones (one in the foreground shows its own incoming call).
    func ring(label: String) {
        let send = lock.withLock { sendText }
        send?(RelayFrame.ring(label: label))
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
