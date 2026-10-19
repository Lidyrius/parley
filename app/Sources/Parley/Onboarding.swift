import SwiftUI
import AppKit
import AVFoundation
import CoreImage
import Speech
import UserNotifications

// First-run onboarding in ten steps, "logo with echo" (docs/design/screens/macos/01-willkommen):
// warm dark, a round badge with three clay rings, one-line subtitles, ten progress dots. Clients,
// the two API keys (checked as they are pasted), language + voice, notifications, every macOS
// permission in one list, the relay for the phone, pairing it in the window, a short tutorial.

private let onboardKeyLangs = ["Deutsch", "English", "Français", "Español", "Italiano", "Nederlands"]
private func langCode(_ l: String) -> String {
    switch l {
    case "English": return "en-US"; case "Français": return "fr-FR"; case "Español": return "es-ES"
    case "Italiano": return "it-IT"; case "Nederlands": return "nl-NL"; default: return "de-DE"
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    // docs/design/screens/macos/01-willkommen/AUFTRAG.md — ten steps in the "logo with echo" look.
    enum Step: Int, CaseIterable { case welcome, integrations, keys, voice, notify, permissions, relay, pair, tutorial, done }
    @Published var step: Step = .welcome

    init(start: Step = .welcome) {
        ClientIntegrations.refreshDetection()
        step = start
        let firstRun = Keychain.get(.onboarded) != "1"
        installClaude = firstRun ? ClientIntegrations.detected(.claudeCode) : ClientIntegrations.enabled(.claudeCode)
        installCodex = firstRun ? ClientIntegrations.detected(.codex) : ClientIntegrations.enabled(.codex)
        let url = Keychain.get(.relayUrl) ?? ""
        if !url.isEmpty, RelayLink.normalize(url) != RelayLink.publicRelay {
            relayChoice = .address
            relayAddress = url
        }
        refreshPermissions()
    }

    // Tutorial sub-state (the `.tutorial` step walks `tutSteps`).
    @Published var tutIndex = 0
    @Published var tutTrying = false
    @Published var tutResult: Bool? = nil
    private var tutorialPlaybackTask: Task<Void, Never>?
    private var tutorialGeneration = 0
    /// Unterwegs only once a phone is paired.
    var tutSteps: [TutorialStep] { TutorialStep.allCases.filter { $0 != .away || paired != nil || phonePaired } }
    var tutStep: TutorialStep { tutSteps[min(tutIndex, tutSteps.count - 1)] }
    var tutLast: Bool { tutIndex >= tutSteps.count - 1 }
    private var phonePaired: Bool { Keychain.get(.phonePushToken) != nil }

    @Published var googleKey = Keychain.get(.googleAPIKey) ?? "" { didSet { if googleKey != oldValue { googleCheck = .idle; scheduleCheck() } } }
    @Published var groqKey = Keychain.get(.groqAPIKey) ?? "" { didSet { if groqKey != oldValue { groqCheck = .idle; scheduleCheck() } } }
    @Published var language = Keychain.get(.language) ?? "Deutsch"
    // Star name; seed from the saved voice so a tutorial-only re-show uses the real voice.
    @Published var voiceName = String(Keychain.get(.googleVoice)?.split(separator: "-").last ?? "Alnilam")
    @Published var notifyMode = AppConfig.load().notifyMode { didSet { refreshPermissions() } }
    @Published var voices: [String] = ["Alnilam", "Aoede", "Charon", "Kore", "Puck", "Fenrir"]
    @Published var installClaude = ClientIntegrations.enabled(.claudeCode)
    @Published var installCodex = ClientIntegrations.enabled(.codex)

    var detectedClaude: Bool { ClientIntegrations.detected(.claudeCode) }
    var detectedCodex: Bool { ClientIntegrations.detected(.codex) }

    enum Check: Equatable { case idle, checking, ok, fail(String) }
    @Published var googleCheck: Check = .idle
    @Published var groqCheck: Check = .idle

    var totalSteps: Int { Step.allCases.count }
    var canContinue: Bool {
        switch step {
        case .keys: return googleCheck == .ok && groqCheck == .ok   // must verify to proceed
        case .permissions: return permissions[.mic] == .granted
        case .relay: return relayReady
        case .pair: return paired != nil
        default: return true
        }
    }

    func openGoogleConsole() {
        NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/apis/library/texttospeech.googleapis.com")!)
    }
    func openGroqConsole() {
        NSWorkspace.shared.open(URL(string: "https://console.groq.com/keys")!)
    }

    // MARK: - keys: checked by themselves once pasted (debounced) — no button

    private var checkTask: Task<Void, Never>?

    private func scheduleCheck() {
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.checkKeys()
        }
    }

    /// Verify the keys present with a tiny live request; updates the per-key status.
    func checkKeys() {
        guard !OnboardingPresenter.snapshotting else { return }
        let voice = "\(langCode(language))-Chirp3-HD-\(voiceName)"
        if !googleKey.isEmpty, googleCheck != .ok {
            googleCheck = .checking
            Task { [googleKey] in
                let r = await Validation.google(googleKey, voice: voice)
                if googleKey == self.googleKey { self.googleCheck = r; if r == .ok { self.loadVoices() } }
            }
        }
        if !groqKey.isEmpty, groqCheck != .ok {
            groqCheck = .checking
            Task { [groqKey] in
                let r = await Validation.groq(groqKey)
                if groqKey == self.groqKey { self.groqCheck = r }
            }
        }
    }

    @Published var forward = true   // step direction — drives the slide transition

    func next() {
        guard var s = Step(rawValue: step.rawValue + 1) else { return }
        // Voice just chosen → render the tutorial in that voice, before other cache clips.
        if step == .voice { VoicePreview.stop(); prepareTutorial() }
        // Checked keys are kept at once: the tutorial's "Ausprobieren" listens with the saved ones.
        if step == .keys { Keychain.set(googleKey, for: .googleAPIKey); Keychain.set(groqKey, for: .groqAPIKey) }
        if s == .pair && phoneLater { s = .tutorial }   // no relay set up: no pairing
        if s == .keys { checkKeys() }   // a second run: the saved keys count once checked
        forward = true
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { step = s }
    }
    func back() {
        guard var s = Step(rawValue: step.rawValue - 1) else { return }
        if step == .tutorial { stopTutorialAudio() }
        if s == .pair && phoneLater { s = .relay }
        if s == .keys { checkKeys() }
        forward = false
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { step = s }
    }

    // MARK: - permissions (step 6): everything Parley asks macOS for, one list

    enum Permission: CaseIterable { case mic, speech, notifications, terminal, music }
    enum Grant: Equatable { case granted, asking, needed, denied }
    @Published var permissions: [Permission: Grant] = [:]

    /// The rows shown: notifications only when Parley sends any.
    var permissionRows: [Permission] { Permission.allCases.filter { $0 != .notifications || notifyMode == "system" } }

    func refreshPermissions() {
        var p: [Permission: Grant] = [:]
        p[.mic] = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        default: .needed
        }
        p[.speech] = switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .denied, .restricted: .denied
        default: .needed
        }
        for (k, v) in p where permissions[k] != .asking { permissions[k] = v }
        Task { [weak self] in
            let n = await Self.notificationGrant()
            let t = await Self.automationGrant("com.apple.Terminal", ask: false)
            let m = await Self.automationGrant("com.apple.Music", ask: false)
            guard let self else { return }
            if permissions[.notifications] != .asking { permissions[.notifications] = n }
            if permissions[.terminal] != .asking { permissions[.terminal] = t }
            if permissions[.music] != .asking { permissions[.music] = m }
        }
    }

    func request(_ p: Permission) async {
        permissions[p] = .asking
        switch p {
        case .mic:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .speech:
            _ = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        case .notifications:
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        case .terminal:
            permissions[p] = await Self.automationGrant("com.apple.Terminal", ask: true)
        case .music:
            permissions[p] = await Self.automationGrant("com.apple.Music", ask: true)
        }
        if p != .terminal && p != .music { permissions[p] = nil }
        refreshPermissions()
    }

    /// "Alle erlauben": macOS asks one after the other.
    func allowAll() {
        Task {
            for p in permissionRows where permissions[p] == .needed { await request(p) }
        }
    }

    func openSettings(_ p: Permission) {
        let pane = switch p {
        case .mic: "Privacy_Microphone"
        case .speech: "Privacy_SpeechRecognition"
        case .notifications: "Notifications"
        case .terminal, .music: "Privacy_Automation"
        }
        let url = p == .notifications ? "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
                                      : "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        NSWorkspace.shared.open(URL(string: url)!)
    }

    private static func notificationGrant() async -> Grant {
        guard Bundle.main.bundleIdentifier != nil else { return .needed }
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        default: return .needed
        }
    }

    /// Apple Events to `bundle` (Terminal: the Zentrale starts / closes sessions; Music: pausing it).
    /// The app has to run to be asked — Parley opens it in the background first.
    nonisolated private static func automationGrant(_ bundle: String, ask: Bool) async -> Grant {
        if ask, NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            let c = NSWorkspace.OpenConfiguration()
            c.activates = false
            c.hides = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: c)
            try? await Task.sleep(for: .seconds(1))
        }
        return await Task.detached {
            var target = AEAddressDesc()
            let id = Array(bundle.utf8)
            guard AECreateDesc(typeApplicationBundleID, id, id.count, &target) == noErr else { return Grant.needed }
            defer { AEDisposeDesc(&target) }
            switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask) {
            case noErr: return .granted
            case OSStatus(errAEEventNotPermitted): return .denied
            default: return .needed      // would need consent / not running yet
            }
        }.value
    }

    // MARK: - relay (step 7) and pairing (step 8)

    enum RelayChoice { case publicRelay, own, address }
    @Published var relayChoice: RelayChoice = .publicRelay
    @Published var phoneLater = false
    @Published var ownSteps: [Bool?] = [nil, nil, nil]   // signed in · deployed · checked
    @Published var ownBusy = false
    @Published var ownNote: String?
    @Published var relayAddress = ""
    @Published var addressCheck: Check = .idle

    var relayReady: Bool {
        switch relayChoice {
        case .publicRelay: true
        case .own: ownSteps[2] == true
        case .address: addressCheck == .ok
        }
    }

    func choosePublicRelay() {
        relayChoice = .publicRelay
        phoneLater = false
        Keychain.set("", for: .relayUrl)   // empty = the public relay (end-to-end encrypted)
    }

    func ownRelay() {
        relayChoice = .own
        phoneLater = false
        guard !ownBusy, ownSteps[2] != true else { return }
        ownBusy = true
        ownNote = nil
        ownSteps = [nil, nil, nil]
        Task {
            defer { ownBusy = false }
            guard await RelaySetup.hasNode() else {
                ownNote = "Dafür braucht es Node.js (nodejs.org). Oder fügen Sie rechts die Adresse eines Relais ein."
                return
            }
            guard let dir = RelaySetup.workDir() else { ownNote = "Das Relais fehlt in dieser Parley-Version."; return }
            ownSteps[0] = await RelaySetup.login(in: dir)
            guard ownSteps[0] == true else { ownNote = "Die Anmeldung bei Cloudflare hat nicht geklappt."; return }
            guard let url = await RelaySetup.deploy(in: dir) else {
                ownSteps[1] = false
                ownNote = "Bereitstellen hat nicht geklappt – „Deploy to Cloudflare“ in der Anleitung geht auch."
                return
            }
            ownSteps[1] = true
            relayAddress = url
            ownSteps[2] = await RelaySetup.check(url)
            if ownSteps[2] == true { Keychain.set(url, for: .relayUrl) } else { ownNote = "Das Relais antwortet noch nicht – gleich noch einmal." }
        }
    }

    func checkAddress() {
        relayChoice = .address
        phoneLater = false
        let url = RelayLink.normalize(relayAddress)
        guard !url.isEmpty else { addressCheck = .idle; return }
        addressCheck = .checking
        Task {
            let ok = await RelaySetup.check(url)
            addressCheck = ok ? .ok : .fail("kein Parley-Relais")
            if ok { Keychain.set(url, for: .relayUrl) }
        }
    }

    func later() {
        if step == .relay { phoneLater = true }
        next()
    }

    @Published var pairLink: String?
    @Published var paired: String?        // the phone's name once it came onto the relay
    private var pairShown = Date.distantFuture

    /// The QR code for step 8: the relay's pairing page, so a phone without Parley lands there.
    func preparePairing() {
        // Screenshots: never the real room and key (the pictures go into the repository).
        if OnboardingPresenter.snapshotting { pairLink = "https://parley-relay.example/pair#beispiel"; return }
        guard let c = RelayConfig.pair() else { pairLink = nil; return }
        AppController.shared.startRelay()
        pairLink = RelayLink.pairPage(c)?.absoluteString
        pairShown = Date()
    }

    func phoneSaidHello(_ hello: (device: String, at: Date)?) {
        guard step == .pair, paired == nil, let hello, hello.at >= pairShown else { return }
        paired = hello.device
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if self.step == .pair { self.next() }
        }
    }

    // MARK: - tutorial

    /// The Chirp3-HD voice the user picked in onboarding (not yet saved to config).
    var selectedVoice: String { "\(langCode(language))-Chirp3-HD-\(voiceName)" }

    @Published var previewLoading = false

    /// Preview the selected voice — full quality via the user's key, cached; bundled fallback.
    func previewVoice() {
        VoicePreview.play(voice: selectedVoice, sentence: VoicePreview.sentence(for: language),
                          key: googleKey) { [weak self] loading in self?.previewLoading = loading }
    }

    /// Render the tutorial audio in the CHOSEN voice — called right after the voice step,
    /// so tutorial phrases are ready before any other (lazy) cache sentences.
    func prepareTutorial() {
        let lang = language, key = googleKey, voice = selectedVoice
        Task { await TutorialClips.shared.render(lang: lang, key: key, voice: voice) }
    }

    /// Play the current tutorial step's pre-rendered line.
    func playTutLine() {
        guard !OnboardingPresenter.snapshotting else { return }
        stopTutorialAudio()
        tutResult = nil
        tutorialGeneration += 1
        let generation = tutorialGeneration
        let step = tutStep, lang = language, key = googleKey, voice = selectedVoice
        tutorialPlaybackTask = Task { [weak self] in
            guard let self else { return }
            if let pcm = await TutorialClips.shared.clip(step, lang: lang, key: key, voice: voice),
               !Task.isCancelled,
               self.tutorialGeneration == generation {
                await AppController.shared.onboardingSpeak(pcm)
            }
            if self.tutorialGeneration == generation { self.tutorialPlaybackTask = nil }
        }
    }

    func stopTutorialAudio() {
        tutorialGeneration += 1
        tutorialPlaybackTask?.cancel()
        tutorialPlaybackTask = nil
        AppController.shared.stopOnboardingSpeak()
    }

    func skipTutorial() {
        guard step == .tutorial else { return }
        stopTutorialAudio()
        forward = true
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { step = .done }
    }

    /// Interactive "Ausprobieren": record + check the expected action.
    func tryTut() {
        guard !tutTrying else { return }
        stopTutorialAudio()
        tutTrying = true; tutResult = nil
        let expect = tutStep.expect
        Task {
            let r = await AppController.shared.onboardingListen()
            let ok = expect == .stop ? r.isStop : (expect == .wait ? r.waitSeconds > 0 : true)
            await MainActor.run { self.tutResult = ok; self.tutTrying = false }
        }
    }

    /// Advance within the tutorial; on the last step, continue to the final screen.
    func tutForward() {
        if tutLast { stopTutorialAudio(); next(); return }
        forward = true
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { tutIndex += 1 }
        playTutLine()
    }

    /// Fetch the Chirp3-HD voice list for the chosen language (best-effort).
    func loadVoices() {
        guard !googleKey.isEmpty else { return }
        let code = langCode(language)
        var req = URLRequest(url: URL(string: "https://texttospeech.googleapis.com/v1/voices?languageCode=\(code)")!)
        req.setValue(googleKey, forHTTPHeaderField: "X-Goog-Api-Key")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["voices"] as? [[String: Any]] else { return }
            let names = arr.compactMap { $0["name"] as? String }
                .filter { $0.contains("Chirp3-HD") }
                .map { String($0.split(separator: "-").last ?? "") }
                .sorted()
            Task { @MainActor in if !names.isEmpty { self.voices = names; if !names.contains(self.voiceName) { self.voiceName = names[0] } } }
        }.resume()
    }

    func finish() {
        Keychain.set(googleKey, for: .googleAPIKey)
        Keychain.set(groqKey, for: .groqAPIKey)
        Keychain.set(language, for: .language)
        Keychain.set("\(langCode(language))-Chirp3-HD-\(voiceName)", for: .googleVoice)
        Keychain.set(notifyMode, for: .notifyMode)
        ClientIntegrations.save(claudeCode: installClaude, codex: installCodex)
        Keychain.set("1", for: .onboarded)
        Keychain.set(String(TutorialClips.version), for: .tutorialSeen)
        ClientIntegrations.sync()
        AppController.shared.startRelay()
    }
}

// MARK: - the look: "Logo mit Echo" — warm dark, clay accent, a badge with three rings

private let clay = Color(red: 0.851, green: 0.467, blue: 0.341)

struct OnboardingView: View {
    @StateObject private var m: OnboardingModel
    @ObservedObject private var app = AppController.shared
    var onDone: () -> Void

    init(startAt: OnboardingModel.Step = .welcome, onDone: @escaping () -> Void) {
        _m = StateObject(wrappedValue: OnboardingModel(start: startAt))
        self.onDone = onDone
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.17, green: 0.15, blue: 0.14), Color(red: 0.11, green: 0.10, blue: 0.10)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 0) {
                progress.padding(.top, 20)
                Spacer(minLength: 0)
                content
                    .frame(maxWidth: 540).padding(.horizontal, 44)
                    .id(m.step)                                   // recreate per step → entrance re-fires
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: m.forward ? 34 : -34)),
                        removal:   .opacity.combined(with: .offset(x: m.forward ? -34 : 34))))
                Spacer(minLength: 0)
                bottomBar.padding(.horizontal, 36).padding(.bottom, 24)
            }
            .clipped()
        }
        .frame(width: 660, height: 580)
        .preferredColorScheme(.dark)
        .tint(clay)
        .onAppear { m.loadVoices() }
        .onChange(of: app.phoneHello?.at) { _, _ in m.phoneSaidHello(app.phoneHello) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in m.refreshPermissions() }
    }

    /// Ten dots: the current one long, the done ones in muted clay.
    private var progress: some View {
        HStack(spacing: 5) {
            ForEach(0..<m.totalSteps, id: \.self) { i in
                Capsule()
                    .fill(i == m.step.rawValue ? clay : i < m.step.rawValue ? clay.opacity(0.45) : Color.white.opacity(0.16))
                    .frame(width: i == m.step.rawValue ? 18 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.25), value: m.step)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch m.step {
        case .welcome:
            hero(nil, "Guten Tag, Sir.", "Parley spricht Claude Codes Antworten – und hört Ihre.")
        case .integrations:
            VStack(spacing: 18) {
                hero("rectangle.2.swap", "Wo soll Parley laufen?", "Erkannte Clients sind schon ausgewählt.")
                VStack(spacing: 10) {
                    integrationChoice(.claudeCode, title: "Claude Code", subtitle: "Stop-Hook und /parley:voice").entrance(3)
                    integrationChoice(.codex, title: "Codex", subtitle: "Plugin und $parley-voice").entrance(4)
                }
                if !m.detectedClaude && !m.detectedCodex {
                    HStack(spacing: 10) {
                        Text("Kein Client gefunden.").foregroundStyle(.secondary)
                        Button("Claude Code installieren") { ClientIntegrations.openDownload(for: .claudeCode) }.buttonStyle(.link)
                        Button("Codex installieren") { ClientIntegrations.openDownload(for: .codex) }.buttonStyle(.link)
                    }.font(.system(size: 11)).entrance(5)
                }
            }
        case .keys:
            VStack(spacing: 16) {
                hero("key.fill", "Zwei Schlüssel", "Beide praktisch gratis. Einfügen – Parley prüft sofort.")
                VStack(spacing: 10) {
                    keyCard("Google Cloud TTS", "1 Mio. Zeichen gratis", text: $m.googleKey, check: m.googleCheck, open: m.openGoogleConsole)
                    keyCard("Groq", "Developer-Key", text: $m.groqKey, check: m.groqCheck, open: m.openGroqConsole)
                }.entrance(3)
            }
        case .voice:
            VStack(spacing: 18) {
                hero("globe", "Sprache & Stimme", "Worin spreche ich, und mit welcher Stimme?")
                VStack(spacing: 0) {
                    pickerRow("Sprache", selection: $m.language, options: onboardKeyLangs)
                        .onChange(of: m.language) { _, _ in m.loadVoices() }
                    Divider().overlay(Color.white.opacity(0.06))
                    pickerRow("Stimme", selection: $m.voiceName, options: m.voices)
                        .onChange(of: m.voiceName) { _, _ in m.previewVoice() }
                    Divider().overlay(Color.white.opacity(0.06))
                    HStack(spacing: 12) {
                        Button { m.previewVoice() } label: {
                            Image(systemName: m.previewLoading ? "ellipsis" : "play.fill")
                                .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 30, height: 30).background(Circle().fill(clay))
                        }.buttonStyle(.plain).disabled(m.previewLoading)
                        Waveform().frame(height: 22)
                        Text("Hörprobe").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 14).padding(.vertical, 12)
                }
                .background(card).entrance(3)
            }
        case .notify:
            VStack(spacing: 18) {
                hero("bell.badge", "Benachrichtigungen", "Wie sage ich Bescheid, wenn ein Projekt wartet?")
                HStack(spacing: 10) {
                    notifyCard("In der Pill", "Unten mittig", "pill").entrance(3)
                    notifyCard("Mitteilung", "macOS-Standard", "system").entrance(4)
                    notifyCard("Keine", "Ganz still", "none").entrance(5)
                }
            }
        case .permissions:
            VStack(spacing: 16) {
                hero("hand.raised.fill", "Berechtigungen", "Einmal erlauben – danach fragt Parley nie wieder.")
                VStack(spacing: 0) {
                    ForEach(Array(m.permissionRows.enumerated()), id: \.element) { i, p in
                        if i > 0 { Divider().overlay(Color.white.opacity(0.06)) }
                        permissionRow(p)
                    }
                }.background(card).entrance(3)
            }
        case .relay:
            VStack(spacing: 16) {
                hero("antenna.radiowaves.left.and.right", "Parley aufs Handy",
                     "Unterwegs klingelt Parley auf Ihrem Handy – über ein kleines Relais.")
                relayCards.entrance(3)
            }
        case .pair:
            pairStep
        case .tutorial:
            tutorialCard
        case .done:
            VStack(spacing: 16) {
                hero(nil, "Bereit, Sir.", "Tippen Sie das in einer neuen Session – dann bin ich da.")
                VStack(spacing: 10) {
                    if m.installClaude { clientCommand(.claudeCode, command: "/parley:voice").entrance(3) }
                    if m.installCodex { clientCommand(.codex, command: "$parley-voice").entrance(4) }
                    if !m.installClaude && !m.installCodex {
                        Text("Die Clients lassen sich später im Setup verbinden.").font(.system(size: 12)).foregroundStyle(.secondary).entrance(3)
                    }
                }
            }
        }
    }

    // MARK: steps 7–9

    @ViewBuilder private var relayCards: some View {
        VStack(spacing: 10) {
            choiceCard(selected: m.relayChoice == .publicRelay, action: m.choosePublicRelay) {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill").foregroundStyle(clay)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Parleys Relais").font(.system(size: 13, weight: .semibold))
                        Text("Sofort bereit · Ende-zu-Ende verschlüsselt").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    badge("empfohlen")
                }
            }
            HStack(alignment: .top, spacing: 10) {
                choiceCard(selected: m.relayChoice == .own, action: m.ownRelay) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "cloud.fill").foregroundStyle(clay)
                            Text("Eigenes Relais").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("1 Klick").font(.system(size: 10, weight: .semibold)).foregroundStyle(clay)
                        }
                        if m.relayChoice == .own {
                            checkLine("Bei Cloudflare angemeldet", m.ownSteps[0])
                            checkLine("Relais bereitgestellt", m.ownSteps[1])
                            checkLine("Verbindung geprüft", m.ownSteps[2])
                            if let note = m.ownNote { Text(note).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                            if !m.relayAddress.isEmpty, m.ownSteps[1] == true {
                                Text(m.relayAddress.replacingOccurrences(of: "https://", with: "")).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Ihr Cloudflare-Konto, kostenlos. Sie bestätigen nur im Browser.").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                choiceCard(selected: m.relayChoice == .address, action: { m.relayChoice = .address; m.phoneLater = false }) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "link").foregroundStyle(clay)
                            Text("Adresse einfügen").font(.system(size: 13, weight: .semibold))
                        }
                        Text("Sie haben schon ein Relais.").font(.system(size: 11)).foregroundStyle(.secondary)
                        if m.relayChoice == .address {
                            TextField("https://…workers.dev", text: $m.relayAddress)
                                .textFieldStyle(.roundedBorder).font(.system(size: 11))
                                .onSubmit { m.checkAddress() }
                                .onChange(of: m.relayAddress) { _, _ in m.addressCheck = .idle }
                            HStack(spacing: 5) { status(m.addressCheck, idle: "Eingabe drücken zum Prüfen") }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var pairStep: some View {
        HStack(spacing: 26) {
            ZStack {
                ForEach(0..<3) { i in
                    Circle().stroke(clay.opacity(0.28 - Double(i) * 0.08), lineWidth: 1.2).frame(width: 230 + CGFloat(i) * 46)
                }
                if let link = m.pairLink, let image = QRImage.make(link) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 170, height: 170)
                        .padding(12).background(RoundedRectangle(cornerRadius: 16).fill(.white))
                } else {
                    RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).frame(width: 194, height: 194)
                        .overlay(Text("Kein Relais").foregroundStyle(.secondary))
                }
            }
            .frame(width: 230, height: 230)
            .entrance(0)
            VStack(alignment: .leading, spacing: 10) {
                Text("Handy koppeln").font(.system(size: 24, weight: .bold)).entrance(1)
                Text("Mit der Kamera scannen – fertig.").font(.system(size: 13)).foregroundStyle(.secondary).entrance(1)
                VStack(alignment: .leading, spacing: 7) {
                    hint("iphone", "Öffnet Parley oder führt zum Download")
                    hint("lock.fill", "Verschlüsselt, nur Ihr Raum")
                    hint("antenna.radiowaves.left.and.right", "Android genauso")
                }.entrance(2)
                Group {
                    if let name = m.paired {
                        Label("Verbunden mit \(name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Warte auf Ihr Handy …", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(clay)
                            .symbolEffect(.pulse)
                    }
                }
                .font(.system(size: 12, weight: .semibold)).padding(.top, 4).entrance(3)
            }
        }
        .onAppear { m.preparePairing() }
    }

    @ViewBuilder private var tutorialCard: some View {
        let step = m.tutStep
        VStack(spacing: 16) {
            echo(symbol: "speaker.wave.2.fill").entrance(0)
            Text("PROBE \(m.tutIndex + 1) VON \(m.tutSteps.count) · \(step.title(m.language).uppercased())")
                .font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(clay).entrance(1)
            Text("„\(step.displayLine(m.language))“")
                .font(.system(size: 16)).italic().multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).entrance(2)
            if step.expect != .none {
                HStack(spacing: 10) {
                    Button { m.tryTut() } label: {
                        Label(m.tutTrying ? "Höre zu …" : "Ausprobieren", systemImage: "mic.fill")
                    }.buttonStyle(SecondaryButton()).disabled(m.tutTrying)
                    if let ok = m.tutResult {
                        Label(ok ? "Genau so, Sir." : "Nicht erkannt – kein Problem.",
                              systemImage: ok ? "checkmark.circle.fill" : "info.circle")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(ok ? .green : .secondary)
                    }
                }.entrance(3)
            }
        }
        .onAppear { m.playTutLine() }
        .onDisappear { m.stopTutorialAudio() }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if m.step != .welcome {
                Button("Zurück") { m.back() }.buttonStyle(SecondaryButton())
            }
            Spacer()
            switch m.step {
            case .welcome:
                Button("Einrichten · 2 Min.") { m.next() }.buttonStyle(PrimaryButton())
            case .done:
                Button("Los geht's") { m.finish(); onDone() }.buttonStyle(PrimaryButton())
            case .tutorial:
                Button("Überspringen") { m.skipTutorial() }.buttonStyle(SecondaryButton())
                Button(m.tutLast ? "Fertig" : "Weiter") { m.tutForward() }.buttonStyle(PrimaryButton())
            case .permissions:
                if m.permissionRows.contains(where: { m.permissions[$0] == .needed }) {
                    Button("Alle erlauben") { m.allowAll() }.buttonStyle(SecondaryButton())
                }
                Button("Weiter") { m.next() }.buttonStyle(PrimaryButton()).disabled(!m.canContinue)
            case .relay, .pair:
                Button("Später") { m.later() }.buttonStyle(SecondaryButton())
                Button("Weiter") { m.next() }.buttonStyle(PrimaryButton()).disabled(!m.canContinue)
            default:
                Button("Weiter") { m.next() }.buttonStyle(PrimaryButton()).disabled(!m.canContinue)
            }
        }
    }

    // MARK: - building blocks

    /// The echo: a round badge with three concentric clay rings; nil symbol = the app's icon.
    private func echo(symbol: String?) -> some View {
        let inner: CGFloat = symbol == nil ? 92 : 60
        return ZStack {
            ForEach(0..<3) { i in
                Circle().stroke(clay.opacity(0.32 - Double(i) * 0.09), lineWidth: 1.2)
                    .frame(width: inner + 30 + CGFloat(i) * 28)
            }
            if let symbol {
                Circle().fill(clay.opacity(0.14)).overlay(Circle().stroke(clay.opacity(0.35)))
                    .frame(width: inner, height: inner)
                Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(clay)
            } else {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: inner, height: inner)
            }
        }
        .frame(height: inner + 86)
    }

    private func hero(_ symbol: String?, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 10) {
            echo(symbol: symbol).entrance(0)
            Text(title).font(.system(size: 26, weight: .bold)).multilineTextAlignment(.center).entrance(1)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(1).minimumScaleFactor(0.85).entrance(2)
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.green.opacity(0.14)))
    }

    private func choiceCard<C: View>(selected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> C) -> some View {
        Button(action: action) {
            content()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? clay.opacity(0.12) : Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? clay.opacity(0.6) : Color.white.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func checkLine(_ text: String, _ done: Bool?) -> some View {
        HStack(spacing: 6) {
            Group {
                switch done {
                case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case false?: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                case nil: if m.ownBusy { ProgressView().controlSize(.mini) } else { Image(systemName: "circle").foregroundStyle(.tertiary) }
                }
            }.frame(width: 14)
            Text(text).font(.system(size: 11))
        }
    }

    private func hint(_ symbol: String, _ text: String) -> some View {
        Label { Text(text).font(.system(size: 12)) } icon: { Image(systemName: symbol).foregroundStyle(clay).frame(width: 16) }
    }

    @ViewBuilder private func status(_ check: OnboardingModel.Check, idle: String) -> some View {
        switch check {
        case .idle: Text(idle).font(.system(size: 10)).foregroundStyle(.tertiary)
        case .checking: ProgressView().controlSize(.mini); Text("prüfe …").font(.system(size: 10)).foregroundStyle(.secondary)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green); Text("gültig").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
        case .fail(let why): Image(systemName: "xmark.circle.fill").foregroundStyle(.red); Text(why).font(.system(size: 10)).foregroundStyle(.red)
        }
    }

    private func keyCard(_ label: String, _ hint: String, text: Binding<String>,
                         check: OnboardingModel.Check, open: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 13, weight: .semibold))
                Text("· \(hint)").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Konsole öffnen", action: open).buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(clay)
            }
            HStack(spacing: 10) {
                SecureField("Einfügen", text: text).textFieldStyle(.roundedBorder)
                HStack(spacing: 4) { status(check, idle: "") }.frame(minWidth: 70, alignment: .trailing)
            }
        }
        .padding(12).background(card)
    }

    // Custom dropdown in a card row: label left, value right.
    private func pickerRow(_ label: String, selection: Binding<String>, options: [String]) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Menu {
                ForEach(options, id: \.self) { opt in
                    Button { selection.wrappedValue = opt } label: {
                        if opt == selection.wrappedValue { Label(opt, systemImage: "checkmark") } else { Text(opt) }
                    }
                }
            } label: {
                HStack {
                    Text(selection.wrappedValue).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .menuStyle(.button).buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func notifyCard(_ title: String, _ subtitle: String, _ value: String) -> some View {
        let on = m.notifyMode == value
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { m.notifyMode = value }
            Notifier.preview(value)   // live example on select
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.35))
                    switch value {
                    case "pill": Capsule().fill(clay).frame(width: 64, height: 9).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 9)
                    case "system": RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.22)).frame(width: 52, height: 15)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(7)
                    default: EmptyView()
                    }
                }
                .frame(height: 56)
                Label(title, systemImage: value == "pill" ? "waveform" : value == "system" ? "bell" : "bell.slash")
                    .font(.system(size: 12, weight: .semibold))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? clay.opacity(0.12) : Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? clay.opacity(0.6) : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private func permissionRow(_ p: OnboardingModel.Permission) -> some View {
        let (symbol, title, subtitle): (String, String, String) = switch p {
        case .mic: ("mic.fill", "Mikrofon", "Ihre Antworten aufnehmen")
        case .speech: ("waveform", "Spracherkennung", "Reinreden unterbricht Parley")
        case .notifications: ("bell.fill", "Mitteilungen", "Wenn ein Projekt wartet")
        case .terminal: ("terminal", "Terminal steuern", "Sessions starten und schließen")
        case .music: ("music.note", "Musik pausieren", "Optional – während Parley spricht")
        }
        return HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(clay)
                .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            switch m.permissions[p] {
            case .granted?:
                Label("erlaubt", systemImage: "checkmark.circle.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
            case .asking?:
                Text("macOS fragt …").font(.system(size: 11)).foregroundStyle(.secondary)
            case .denied?:
                Button("Systemeinstellungen öffnen") { m.openSettings(p) }.buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(clay)
            default:
                Button("Erlauben") { Task { await m.request(p) } }.buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(clay)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private func integrationChoice(_ client: ClientIntegrations.Client, title: String, subtitle: String) -> some View {
        let detected = client == .claudeCode ? m.detectedClaude : m.detectedCodex
        let enabled = client == .claudeCode ? m.installClaude : m.installCodex
        return choiceCard(selected: enabled, action: {
            if client == .claudeCode { m.installClaude.toggle() } else { m.installCodex.toggle() }
        }) {
            HStack(spacing: 12) {
                ClientBrandIcon(client: client).frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 14, weight: .semibold))
                        if detected { badge("erkannt") }
                    }
                    Text(detected ? subtitle : "Nicht gefunden – später verbinden").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(enabled ? clay : .clear).overlay(Circle().strokeBorder(enabled ? clay : Color.white.opacity(0.3), lineWidth: 1.5))
                    .frame(width: 16, height: 16)
            }
        }
        .disabled(!detected)
        .opacity(detected ? 1 : 0.55)
    }

    private func clientCommand(_ client: ClientIntegrations.Client, command: String) -> some View {
        HStack(spacing: 12) {
            ClientBrandIcon(client: client).frame(width: 26, height: 26)
            Text(client.displayName).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Text(command).font(.system(size: 13, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 4).background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.3)))
            Button("Kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(clay)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(card)
    }
}

/// A still waveform for the voice preview row.
private struct Waveform: View {
    var body: some View {
        GeometryReader { g in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<Int(g.size.width / 4), id: \.self) { i in
                    Capsule().fill(clay)
                        .frame(width: 2, height: max(3, g.size.height * (0.25 + 0.75 * abs(sin(Double(i) * 0.9) * cos(Double(i) * 0.23)))))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// A QR code for the pairing step (CoreImage, crisp).
enum QRImage {
    static func make(_ text: String) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

private extension ClientIntegrations.Client {
    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

private struct ClientBrandIcon: View {
    let client: ClientIntegrations.Client

    var body: some View {
        if let url = Bundle.module.url(forResource: client.assetName, withExtension: "png", subdirectory: "branding"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .accessibilityHidden(true)
        } else {
            Image(systemName: client == .claudeCode ? "chevron.left.forwardslash.chevron.right" : "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

private extension ClientIntegrations.Client {
    var assetName: String {
        switch self {
        case .claudeCode: return "claude-code"
        case .codex: return "codex"
        }
    }
}

private struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { PrimaryLabel(configuration: configuration) }
    fileprivate struct PrimaryLabel: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label.font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? .white : Color.white.opacity(0.45))
                .padding(.horizontal, 18).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(enabled
                    ? clay.opacity(configuration.isPressed ? 0.8 : 1)
                    : clay.opacity(0.35)))   // muted when disabled
        }
    }
}
private struct SecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(configuration.isPressed ? 0.14 : 0.08)))
    }
}

// Hosts onboarding in a plain window (reliable for a menu-bar / LSUIElement app).
@MainActor
final class OnboardingPresenter {
    static let shared = OnboardingPresenter()
    private var window: NSWindow?

    static var isComplete: Bool { Keychain.get(.onboarded) == "1" }

    // `PARLEY_ONBOARDING_SNAPSHOTS=<dir>`: every step as 10-umgesetzt-NN.png, then quit — nothing
    // else of the app starts (no server, no relay), no sound, no real pairing code.
    static var snapshotting = false

    func snapshots(to dir: String) {
        Self.snapshotting = true
        Task { @MainActor in
            for step in OnboardingModel.Step.allCases {
                show(startAt: step)
                window?.alphaValue = 0.01
                try? await Task.sleep(for: .seconds(1.8))
                if let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let file = URL(fileURLWithPath: dir).appendingPathComponent(String(format: "10-umgesetzt-%02d.png", step.rawValue + 1))
                    try? rep.representation(using: .png, properties: [:])?.write(to: file)
                }
                window?.close()
                window = nil
            }
            exit(0)
        }
    }
    static var tutorialCurrent: Bool { (Int(Keychain.get(.tutorialSeen) ?? "0") ?? 0) >= TutorialClips.version }

    // First run → full onboarding. Already onboarded but the tutorial changed → tutorial only.
    func showIfNeeded() {
        if !Self.isComplete { show(startAt: .welcome) }
        else if !Self.tutorialCurrent { show(startAt: .tutorial) }
    }

    /// Force a fresh onboarding from the welcome step, discarding any window already open.
    func restart() {
        window?.close(); window = nil
        show(startAt: .welcome)
    }

    func show(startAt: OnboardingModel.Step = .welcome) {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 580),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Parley"
        w.isReleasedWhenClosed = false
        w.center()
        w.contentView = NSHostingView(rootView: OnboardingView(startAt: startAt, onDone: { [weak self] in
            self?.window?.close(); self?.window = nil
        }))
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// Live key verification for onboarding — a tiny request each; maps to OnboardingModel.Check.
enum Validation {
    static func google(_ key: String, voice: String) async -> OnboardingModel.Check {
        guard !key.isEmpty else { return .fail("kein Schlüssel") }
        let req = GoogleTTS.request(text: "Hallo", apiKey: key, voice: voice)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let c = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if c == 200 { return .ok }
            if c == 403 { return .fail("HTTP 403 — API aktiviert?") }
            if c == 400 { return .fail("HTTP 400 — Schlüssel/Stimme?") }
            return .fail("HTTP \(c)")
        } catch { return .fail("Netzwerkfehler") }
    }

    static func groq(_ key: String) async -> OnboardingModel.Check {
        guard !key.isEmpty else { return .fail("kein Schlüssel") }
        var req = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/models")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let c = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if c == 200 { return .ok }
            if c == 401 { return .fail("HTTP 401 — Schlüssel ungültig") }
            return .fail("HTTP \(c)")
        } catch { return .fail("Netzwerkfehler") }
    }
}

// Staggered entrance: fade + gentle rise + scale, ordered. Re-fires each step because the
// content carries .id(step). Mirrors VoiceInk's subtle onboarding reveals.
private struct Entrance: ViewModifier {
    let order: Int
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .scaleEffect(on ? 1 : 0.98, anchor: .center)
            .offset(y: on ? 0 : 12)
            .onAppear {
                withAnimation(.easeOut(duration: 0.34).delay(0.04 + Double(order) * 0.07)) { on = true }
            }
    }
}
private extension View { func entrance(_ order: Int = 0) -> some View { modifier(Entrance(order: order)) } }
