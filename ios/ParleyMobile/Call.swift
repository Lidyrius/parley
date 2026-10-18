import AVFAudio
import CallKit
import Foundation
import UIKit

/// Where the call stands.
enum CallPhase: Equatable, Sendable {
    case none
    case ringing                    // incoming, not answered yet
    case dialing                    // outgoing, waiting for the Mac and the audio session
    case connecting                 // answered, waiting for the Mac and the audio session
    case active(since: Date)

    var isActive: Bool { if case .active = self { true } else { false } }
}

/// The phone's call with Parley (docs/IPHONE.md → Protocol v2, phone behaviour): a CallKit call
/// whose audio runs over the relay. Outgoing ("Parley anrufen", Siri) and incoming (VoIP push,
/// `ring` frame) take the same path: once the relay reaches the host and CallKit has activated
/// the audio session, the engine starts and `call start` goes out; `call end` when it ends.
///
/// The simulator has no working CallKit: there the call runs without it, on an audio session
/// activated by hand, so the pipeline can still be exercised against a local relay.
@MainActor @Observable
final class CallController {
    private(set) var phase: CallPhase = .none
    /// The host's last `audio` state; the wake word is listened for only while `idle`.
    private(set) var hostAudio: HostAudio = .idle
    /// The project this call is about: the push/ring label, or what an `audio` frame named.
    private(set) var label: String?
    private(set) var muted = false
    private(set) var speaker = false
    /// Just connected, the host hasn't spoken yet: the screen stays as while connecting (no flash
    /// of "bereit") until the host speaks or listens, or a few seconds pass.
    private(set) var awaitingHost = false
    @ObservationIgnored private var awaitingTask: Task<Void, Never>?
    /// Live captions of the line being spoken (v3), timed against the frames actually played.
    private(set) var caption: Caption?
    /// The line's slides (docs/CALL-SLIDES.md), on the captions' clock.
    private(set) var slides: [Slide] = []
    @ObservationIgnored private var captionBase = 0
    @ObservationIgnored private var captionAt = Date.now
    /// "Hey Parley" was heard and sent; cleared when the host leaves idle.
    private(set) var wakeSent = false
    /// The call screen is up (it can be minimised to the overview during a call).
    var showsScreen = false
    /// Why the last call failed, for an alert.
    var failure: String?
    let meter = AudioMeter()
    let isDemo: Bool

    /// Dial the relay if it is idle (the app may have been woken in the background).
    @ObservationIgnored var ensureRelay: () -> Void = {}
    @ObservationIgnored var onEnded: () -> Void = {}
    /// The call is up (`call start` sent): what waited for it goes to the host now.
    @ObservationIgnored var onConnected: () -> Void = {}
    /// A ringing call declined on the lock screen (no "later" buttons there): the label it was for.
    @ObservationIgnored var onDeclined: (String?) -> Void = { _ in }
    /// The subtitle line spoken now, on change (nil = none any more): the Live Activity shows it.
    @ObservationIgnored var onSubtitle: (String?) -> Void = { _ in }
    @ObservationIgnored private var subtitleTask: Task<Void, Never>?
    /// Ended from the app's own ringing screen (Ablehnen, In 1 Min. …): no notification after.
    @ObservationIgnored private var endedInApp = false
    /// An unanswered ring ends itself (the host gives up at 45 s) and leaves the "later" notification.
    @ObservationIgnored private var ringExpiry: Task<Void, Never>?
    static let ringSeconds = 40.0

    @ObservationIgnored private let relay: Relay
    @ObservationIgnored private let wake = WakeListener()
    @ObservationIgnored private let audio: CallAudio
    @ObservationIgnored private var provider: CXProvider?
    @ObservationIgnored private var providerDelegate: ProviderDelegate?
    @ObservationIgnored private let callKit = CXCallController(queue: .main)
    @ObservationIgnored private var uuid: UUID?
    @ObservationIgnored private var audioActive = false
    @ObservationIgnored private var beginning = false
    /// "Annehmen" was tapped: the screen morphs at once, not only once CallKit confirms.
    private var answering = false
    /// The ringing screen (buttons, ring, "later") — until answered.
    var isRinging: Bool { phase == .ringing && !answering }
    @ObservationIgnored private var wakeArmed = true
    @ObservationIgnored private var connectTimeout: Task<Void, Never>?
    @ObservationIgnored private var lossTimeout: Task<Void, Never>?
    @ObservationIgnored private var rearm: Task<Void, Never>?

    init(relay: Relay, demo: Bool) {
        self.relay = relay
        isDemo = demo
        let out = relay.audioOut
        audio = CallAudio(meter: meter, speech: wake.feed, send: { out.send($0) })
        wake.onWake = { [weak self] in
            guard let self else { return }
            if listeningForBarge { bargeHeard() } else { wakeHeard() }
        }
        #if !targetEnvironment(simulator)
        if !demo { setUpCallKit() }
        #endif
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.routeChanged() }
        }
    }

    var isBusy: Bool { phase != .none }
    var usesCallKit: Bool { provider != nil }
    var wakeWordAvailable: Bool { isDemo || wake.isAvailable }

    /// Microphone and speech recognition, asked up front so the prompts never land mid-call.
    static func requestPermissions() async {
        if AVAudioApplication.shared.recordPermission == .undetermined {
            _ = await AVAudioApplication.requestRecordPermission()
        }
        _ = await WakeListener.requestAuthorization()
    }

    // MARK: - Outgoing

    /// "Parley anrufen" (button, Siri, Shortcuts). Throws when CallKit refuses the call.
    func startOutgoing() async throws {
        guard phase == .none else { showsScreen = true; return }
        if isDemo { startDemo(.speaking); return }
        let id = UUID()
        uuid = id
        label = nil
        phase = .dialing
        showsScreen = true
        guard provider != nil else {
            try startWithoutCallKit()
            return
        }
        do {
            try await request(CXStartCallAction(call: id, handle: Self.handle))
        } catch {
            reset()
            throw error
        }
        provider?.reportCall(with: id, updated: Self.update(label: nil))
    }

    fileprivate func performStart(_ action: CXStartCallAction) {
        guard action.callUUID == uuid else { action.fail(); return }
        try? Self.configureSession()
        provider?.reportOutgoingCall(with: action.callUUID, startedConnectingAt: .now)
        dial()
        action.fulfill()
    }

    // MARK: - Incoming

    /// A VoIP push (`reported` is PushKit's completion: it runs once CallKit has the call) or a
    /// `ring` frame (`reported` nil).
    func reportIncoming(label: String?, reported: (() -> Void)? = nil) {
        // CallKit calls back on its own queue; PushKit's completion may run there.
        let isPush = reported != nil
        nonisolated(unsafe) let reported = reported ?? {}
        if isDemo { reported(); return }
        if phase != .none {
            // Already ringing or in a call: the push and the ring frame are twins. A push still
            // reports (the same call: CallKit refuses it without a second call UI, and an active
            // call is what PushKit checks for); a ring frame just stops here.
            if isPush, let provider, let uuid {
                provider.reportNewIncomingCall(with: uuid, update: Self.update(label: label)) { _ in reported() }
            } else {
                reported()
            }
            return
        }
        let id = UUID()
        uuid = id
        self.label = label
        phase = .ringing
        if provider != nil { try? Self.configureSession() }   // now, not while answering animates
        // Not answered in 40 s (on the lock screen there is only "answer"): stop ringing, tell the
        // host, and offer "later" as a notification.
        ringExpiry?.cancel()
        ringExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.ringSeconds))
            guard !Task.isCancelled, let self, phase == .ringing, uuid == id else { return }
            provider?.reportCall(with: id, endedAt: .now, reason: .unanswered)
            finish()
        }
        // In the app already (or no CallKit, the simulator): the call screen slides up at once.
        if provider == nil || UIApplication.shared.applicationState == .active { showsScreen = true }
        ensureRelay()  // be ready by the time it is answered
        guard let provider else {
            reported()
            return
        }
        provider.reportNewIncomingCall(with: id, update: Self.update(label: label)) { error in
            reported()
            guard error != nil else { return }
            Task { @MainActor [weak self] in
                if self?.uuid == id { self?.reset() }  // e.g. Do Not Disturb, blocked
            }
        }
    }

    /// The in-app "Annehmen" (CallKit's own answer UI goes straight to `performAnswer`).
    /// A pretend call from the settings (Probeanruf): it rings in the app; answering shows Parley
    /// speaking for a few seconds, then it ends by itself — no CallKit, relay or audio.
    private(set) var isTest = false
    @ObservationIgnored private var testEnd: Task<Void, Never>?

    /// "Not now" on the ringing screen: Parley rings again in `after` s, or (nil) waits until you
    /// call back — the session's tile then offers "Rückrufen".
    func later(_ after: Int?) {
        guard phase == .ringing else { return }
        if !isTest { relay.send(Outgoing.later(after: after)) }
        hangUp()
    }

    /// The same "not now", from the notification a lock-screen decline leaves (see onDeclined).
    nonisolated static func laterAfter(action: String) -> Int?? {
        switch action {
        case "later.60": .some(60)
        case "later.300": .some(300)
        case "later.back": .some(nil)
        default: nil
        }
    }

    func startTest() {
        guard phase == .none else { return }
        isTest = true
        label = "Probeanruf"
        phase = .ringing
    }

    func answer() {
        guard phase == .ringing else { return }
        if isTest {
            phase = .active(since: .now)
            hostAudio = .speaking
            testEnd = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                self?.hostAudio = .listening
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                self?.reset()
            }
            return
        }
        if isDemo { phase = .active(since: .now); return }
        guard let uuid else { return }
        showsScreen = true
        answering = true
        guard provider != nil else {
            try? startWithoutCallKit(answering: true)
            return
        }
        Task {
            do { try await request(CXAnswerCallAction(call: uuid)) } catch { fail("Der Anruf ließ sich nicht annehmen.") }
        }
    }

    fileprivate func performAnswer(_ action: CXAnswerCallAction) {
        guard action.callUUID == uuid, phase == .ringing else { action.fail(); return }
        try? Self.configureSession()
        phase = .connecting
        // Answered on the lock screen, in a banner or in the app: opening Parley shows the call.
        showsScreen = true
        dial()
        action.fulfill()
    }

    // MARK: - In call

    func hangUp() {
        guard phase != .none else { return }
        if isTest { reset(); return }
        if phase == .ringing { endedInApp = true }
        guard let uuid, provider != nil, !isDemo else {
            finish()
            if !isDemo { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
            return
        }
        Task {
            do { try await request(CXEndCallAction(call: uuid)) } catch { finish() }
        }
    }

    func setMuted(_ on: Bool) {
        guard let uuid, provider != nil, !isDemo else { applyMuted(on); return }
        Task {
            do { try await request(CXSetMutedCallAction(call: uuid, muted: on)) } catch { applyMuted(on) }
        }
    }

    /// Settings → "Lautsprecher beim Anrufstart" (on unless turned off).
    /// Hang up once Parley is done (Einstellungen → "Nach dem Gespräch auflegen"); off = stay on.
    static let autoHangUpKey = "autoHangUp"
    static var autoHangUp: Bool { UserDefaults.standard.bool(forKey: autoHangUpKey) }
    @ObservationIgnored private var autoHangUpTask: Task<Void, Never>?
    @ObservationIgnored private var hangUpAtEnd: Task<Void, Never>?
    /// Barge-in: the recognizer listens for Sir talking over Parley (Einstellungen → "Unterbrechen").
    static let bargeInKey = "bargeIn"
    static var bargeIn: Bool { UserDefaults.standard.object(forKey: bargeInKey) as? Bool ?? true }
    @ObservationIgnored private var listeningForBarge = false
    /// The words of Parley's current and previous line: their echo is not Sir talking.
    @ObservationIgnored private var spokenWords: Set<String> = []
    @ObservationIgnored private var previousLine: Set<String> = []

    static let speakerKey = "speakerByDefault"
    static var speakerByDefault: Bool { UserDefaults.standard.object(forKey: speakerKey) as? Bool ?? true }

    func setSpeaker(_ on: Bool) {
        speaker = on
        guard !isDemo, !isTest else { return }
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(on ? .speaker : .none)
    }

    /// A `caption` frame: it arrives just before its line's first audio frame.
    func captionReceived(_ c: Caption) {
        caption = c
        let words = Set(WakeWord.tokens(c.words.joined(separator: " ")))
        spokenWords = previousLine.union(words)
        previousLine = words
        slides = []   // a new line: its slides (if any) come right after
        captionBase = audio.received
        captionAt = .now
        followSubtitles(c)
        hangUpAtEnd?.cancel()
        if c.last, Self.autoHangUp, phase.isActive, !isTest {
            // The talk's last line: the call ends the moment its last word has played — not
            // before, and without waiting for the host's `audio idle` (that stays the fallback).
            hangUpAtEnd = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(30))
                    guard let self, phase.isActive else { return }
                    if captionTime(at: .now) >= c.end - 0.1, audio.played >= audio.received {
                        showsScreen = false
                        hangUp()
                        return
                    }
                }
            }
        }
    }

    /// The line's subtitles, line by line, to `onSubtitle` — kept a moment after it ends, so the
    /// activity doesn't flicker between lines.
    private func followSubtitles(_ c: Caption) {
        subtitleTask?.cancel()
        guard !isDemo else { return }
        subtitleTask = Task { [weak self] in
            var shown: String?
            while !Task.isCancelled {
                guard let self, phase.isActive else { return }
                let t = captionTime(at: .now)
                let line = t > c.end + 3 ? nil : c.line(at: t)
                if line != shown { shown = line; onSubtitle(line) }
                if line == nil { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func slidesReceived(_ s: [Slide]) { slides = s }

    /// The slide to show now, if the line has one due.
    func slide(at date: Date) -> Slide? { slides.isEmpty ? nil : Slide.current(slides, at: captionTime(at: date)) }

    /// Seconds of the caption's line played so far (demo: wall clock).
    func captionTime(at date: Date) -> Double {
        if let frozen = demoAt { return frozen }
        return isDemo ? date.timeIntervalSince(captionAt).truncatingRemainder(dividingBy: (caption?.end ?? 1) + 1.5)
                      : Double(max(0, audio.played - captionBase)) * PCM.frameDuration
    }

    /// `-demoAt <seconds>`: the demo line stands still there (screenshots, swipe checks).
    @ObservationIgnored private lazy var demoAt: Double? = {
        guard isDemo, let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-demoAt"),
              i + 1 < ProcessInfo.processInfo.arguments.count else { return nil }
        return Double(ProcessInfo.processInfo.arguments[i + 1])
    }()

    /// A binary frame from the host: Parley's voice.
    func play(_ frame: Data) {
        guard phase.isActive else { return }
        audio.play(frame)
    }

    /// An `audio` frame.
    func hostAudioChanged(_ state: HostAudio, label: String?) {
        // Another session took the voice → the screen and CallKit's caller name follow.
        if let label, label != self.label {
            self.label = label
            if let uuid { provider?.reportCall(with: uuid, updated: Self.update(label: label)) }
        }
        if state != .idle {   // something goes on after all: stay on
            autoHangUpTask?.cancel()
            hangUpAtEnd?.cancel()
        }
        if state != .speaking { audio.unsilence() }
        guard state != hostAudio else { return }
        if state == .idle, hostAudio != .idle, Self.autoHangUp, phase.isActive, !isTest {
            // The talk is over (the host sends idle only when no turn waits) and we hang up: the
            // screen keeps its look (no "bereit", no wake word), the call ends the moment the
            // last line is played out — no pause, no tone.
            autoHangUpTask?.cancel()
            autoHangUpTask = Task { [weak self] in
                for _ in 0..<80 {
                    guard let self, audio.played < audio.received else { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard !Task.isCancelled, let self, phase.isActive else { return }
                showsScreen = false
                hangUp()
            }
            return
        }
        hostAudio = state
        if state != .idle { awaitingHost = false; awaitingTask?.cancel() }
        autoHangUpTask?.cancel()
        if state != .idle {
            wakeArmed = true
            wakeSent = false
            rearm?.cancel()
        }
        updateWake()
    }

    /// The relay opened, closed, or the host came or went.
    func relayChanged() {
        switch phase {
        case .dialing, .connecting:
            begin()
        case .active:
            if relay.canSend {
                lossTimeout?.cancel()
                lossTimeout = nil
            } else if lossTimeout == nil {
                // The relay redials by itself; give it a moment before calling the call lost.
                lossTimeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(25))
                    guard !Task.isCancelled else { return }
                    self?.fail("Die Verbindung zu Parley auf dem Mac ist abgebrochen.")
                }
            }
        case .none, .ringing:
            break
        }
    }

    /// The level the waveform shows: the host's voice while it speaks, else the mic.
    func level(at date: Date) -> Float {
        if isDemo || isTest { return Demo.level(hostAudio, at: date) }
        return hostAudio == .speaking ? meter.out : meter.mic
    }

    // MARK: - Lifecycle

    /// Relay + audio session ready → engine (started off the main actor), `call start`.
    private func begin() {
        guard phase == .dialing || phase == .connecting, relay.canSend, audioActive, !beginning else { return }
        beginning = true
        let outgoing = phase == .dialing
        connectTimeout?.cancel()
        // Loudspeaker by default — only instead of the earpiece: AirPods, the car and headsets keep
        // their route. Before the engine starts: switching after rebuilds its I/O (a second stall).
        if Self.speakerByDefault, !isDemo,
           AVAudioSession.sharedInstance().currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }) {
            setSpeaker(true)
        }
        Task {
            defer { beginning = false }
            do {
                try await audio.start()
            } catch {
                fail("Das Mikrofon ließ sich nicht starten.")
                return
            }
            guard phase == .dialing || phase == .connecting else { return }   // ended meanwhile
            audio.muted = muted
            relay.send(Outgoing.call(started: true))
            awaitingHost = true
            awaitingTask?.cancel()
            awaitingTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.awaitingHost = false
            }
            phase = .active(since: .now)
            if outgoing, let uuid { provider?.reportOutgoingCall(with: uuid, connectedAt: .now) }
            updateWake()
            onConnected()
        }
    }

    /// Reach the host, or give up after a while.
    private func dial() {
        ensureRelay()
        connectTimeout?.cancel()
        connectTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, phase == .dialing || phase == .connecting else { return }
            fail("Parley auf dem Mac ist gerade nicht erreichbar.")
        }
        begin()
    }

    private func startWithoutCallKit(answering: Bool = false) throws {
        do {
            try Self.configureSession()
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            reset()
            throw error
        }
        if answering { phase = .connecting }
        audioActive = true
        dial()
    }

    fileprivate func audioSessionActivated() {
        audioActive = true
        if phase.isActive { audio.restart() } else { begin() }
    }

    fileprivate func audioSessionDeactivated() {
        audioActive = false
        audio.stop()
    }

    fileprivate func applyMuted(_ on: Bool) {
        muted = on
        audio.muted = on
        updateWake()
    }

    private func fail(_ message: String) {
        guard phase != .none else { return }
        failure = message
        if let provider, let uuid { provider.reportCall(with: uuid, endedAt: .now, reason: .failed) }
        finish()
        if provider == nil, !isDemo { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    /// Hung up, declined, failed or ended by the system.
    fileprivate func finish() {
        guard phase != .none else { return }
        // Also for a declined call: the host waits a minute for a "later" from the notification,
        // then voices on the Mac again.
        let declinedOnLockScreen = phase == .ringing && !endedInApp && !isTest && !isDemo
        let declinedLabel = label
        relay.send(Outgoing.call(started: false))
        reset()
        onEnded()
        if declinedOnLockScreen { onDeclined(declinedLabel) }
    }

    private func reset() {
        subtitleTask?.cancel()
        onSubtitle(nil)
        hangUpAtEnd?.cancel()
        autoHangUpTask?.cancel()
        connectTimeout?.cancel()
        lossTimeout?.cancel()
        lossTimeout = nil
        rearm?.cancel()
        wake.stop()
        audio.stop()
        phase = .none
        uuid = nil
        label = nil
        hostAudio = .idle
        isTest = false
        endedInApp = false
        ringExpiry?.cancel()
        testEnd?.cancel()
        caption = nil   // the next call starts clean: no old subtitles or slides
        slides = []
        muted = false
        audio.muted = false
        speaker = false
        audioActive = false
        answering = false
        awaitingHost = false
        awaitingTask?.cancel()
        wakeArmed = true
        wakeSent = false
        showsScreen = false
    }

    // MARK: - Wake word

    private func updateWake() {
        guard phase.isActive, !muted, !isDemo else { stopListening(); return }
        if hostAudio == .idle, wakeArmed {
            if listeningForBarge { stopListening() }
            wake.start()
        } else if hostAudio == .speaking, Self.bargeIn {
            guard !listeningForBarge else { return }
            listeningForBarge = true
            wake.listenForBarge { [weak self] heard in Barge.isInterruption(heard, spoken: self?.spokenWords ?? []) }
        } else {
            stopListening()
        }
    }

    private func stopListening() {
        listeningForBarge = false
        wake.stop()
    }

    /// Sir talks over Parley: quiet at once, and the host stops the line and listens — what was
    /// just said is in its last seconds of mic audio. No hang-up after this line, of course.
    private func bargeHeard() {
        guard phase.isActive, hostAudio == .speaking else { return }
        audio.silence()
        hangUpAtEnd?.cancel()
        autoHangUpTask?.cancel()
        relay.send(Outgoing.barge)
    }

    private func wakeHeard() {
        guard phase.isActive, hostAudio == .idle, wakeArmed else { return }
        wakeArmed = false
        wakeSent = true
        relay.send(Outgoing.wake)
        updateWake()
        // Paused until the host leaves idle; should it never (an older host, a lost frame),
        // listen again after a while instead of going deaf for the rest of the call.
        rearm?.cancel()
        rearm = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, hostAudio == .idle else { return }
            wakeArmed = true
            wakeSent = false
            updateWake()
        }
    }

    // MARK: - Demo

    func startDemo(_ state: Demo.CallState) {
        switch state {
        case .incoming:
            label = "Tippfrei"
            phase = .ringing
        case .connecting:
            phase = .dialing
        case .speaking, .listening, .idle:
            phase = .active(since: .now.addingTimeInterval(-167))
            hostAudio = HostAudio(rawValue: state.rawValue) ?? .idle
            wakeSent = state == .listening
            if state != .idle {   // listening: the line just spoken stays
                captionReceived(Demo.caption)
                slidesReceived(Demo.slides)
            }
        }
        showsScreen = true
    }

    // MARK: - CallKit

    private static let handle = CXHandle(type: .generic, value: "Parley")

    private static func update(label: String?) -> CXCallUpdate {
        let u = CXCallUpdate()
        u.remoteHandle = handle
        u.localizedCallerName = PushPayload.callerName(label)
        u.hasVideo = false
        u.supportsHolding = false
        u.supportsGrouping = false
        u.supportsUngrouping = false
        u.supportsDTMF = false
        return u
    }

    private func setUpCallKit() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = false
        config.iconTemplateImageData = UIImage(systemName: "waveform", withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .semibold))?.pngData()
        let provider = CXProvider(configuration: config)
        let delegate = ProviderDelegate(call: self)
        provider.setDelegate(delegate, queue: .main)
        self.provider = provider
        providerDelegate = delegate
    }

    private func request(_ action: CXCallAction) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            callKit.request(CXTransaction(action: action)) { error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            }
        }
    }

    /// `.playAndRecord` + `.voiceChat` (voice processing, Bluetooth HFP); CarPlay and the car's
    /// mic come with the CallKit call's route.
    private static func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        if CallAudio.usesMicrophone, session.category == .playAndRecord, session.mode == .voiceChat,
           session.categoryOptions.contains(.allowBluetoothHFP) { return }   // already (set while ringing)
        if CallAudio.usesMicrophone {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        } else {
            try session.setCategory(.playback, mode: .spokenAudio)  // simulator without a mic
        }
        try? session.setPreferredIOBufferDuration(0.02)
    }

    private func routeChanged() {
        guard phase != .none, !isDemo else { return }
        speaker = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
    }
}

/// CallKit calls back on the main queue (`setDelegate(_:queue: .main)`).
@MainActor
private final class ProviderDelegate: NSObject, @preconcurrency CXProviderDelegate {
    weak var call: CallController?

    init(call: CallController) {
        self.call = call
    }

    func providerDidReset(_ provider: CXProvider) {
        call?.finish()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        if let call { call.performStart(action) } else { action.fail() }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        if let call { call.performAnswer(action) } else { action.fail() }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        call?.finish()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        call?.applyMuted(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        call?.audioSessionActivated()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        call?.audioSessionDeactivated()
    }
}
