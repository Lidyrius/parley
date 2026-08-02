import SwiftUI
import AppKit
import AVFoundation

// First-run onboarding — a multi-step, full-window flow in the VoiceInk visual idiom:
// a blurred sidebar-material background, a hero header (tinted SF-symbol tile + big title
// + muted subtitle), segmented progress, and a bottom bar (Back / Continue). Collects the
// API keys, language + voice, notification style, and microphone permission, writes them
// to the shared credential store, and marks onboarding complete.

private let onboardKeyLangs = ["Deutsch", "English", "Français", "Español", "Italiano", "Nederlands"]
private func langCode(_ l: String) -> String {
    switch l {
    case "English": return "en-US"; case "Français": return "fr-FR"; case "Español": return "es-ES"
    case "Italiano": return "it-IT"; case "Nederlands": return "nl-NL"; default: return "de-DE"
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable { case welcome, integrations, keys, voice, notify, mic, tutorial, done }
    @Published var step: Step = .welcome

    init(start: Step = .welcome) {
        ClientIntegrations.refreshDetection()
        step = start
        let firstRun = Keychain.get(.onboarded) != "1"
        installClaude = firstRun ? ClientIntegrations.detected(.claudeCode) : ClientIntegrations.enabled(.claudeCode)
        installCodex = firstRun ? ClientIntegrations.detected(.codex) : ClientIntegrations.enabled(.codex)
    }

    // Tutorial sub-state (the `.tutorial` step walks all TutorialStep cases).
    @Published var tutIndex = 0
    @Published var tutTrying = false
    @Published var tutResult: Bool? = nil
    private var tutorialPlaybackTask: Task<Void, Never>?
    private var tutorialGeneration = 0
    var tutStep: TutorialStep { TutorialStep(rawValue: tutIndex) ?? .principle }
    var tutLast: Bool { tutIndex >= TutorialStep.allCases.count - 1 }
    @Published var googleKey = Keychain.get(.googleAPIKey) ?? "" { didSet { googleCheck = .idle } }
    @Published var groqKey = Keychain.get(.groqAPIKey) ?? "" { didSet { groqCheck = .idle } }
    @Published var language = Keychain.get(.language) ?? "Deutsch"
    // Star name; seed from the saved voice so a tutorial-only re-show uses the real voice.
    @Published var voiceName = String(Keychain.get(.googleVoice)?.split(separator: "-").last ?? "Alnilam")
    @Published var notifyMode = AppConfig.load().notifyMode
    @Published var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
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
        case .integrations: return true
        case .keys: return googleCheck == .ok && groqCheck == .ok   // must verify to proceed
        default: return true
        }
    }

    func openGoogleConsole() {
        NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/apis/library/texttospeech.googleapis.com")!)
    }
    func openGroqConsole() {
        NSWorkspace.shared.open(URL(string: "https://console.groq.com/keys")!)
    }
    // Step-by-step GitHub Pages guides (screenshots).
    func openGoogleGuide() { NSWorkspace.shared.open(URL(string: "https://lidyrius.github.io/parley/keys/google.html")!) }
    func openGroqGuide() { NSWorkspace.shared.open(URL(string: "https://lidyrius.github.io/parley/keys/groq.html")!) }

    /// Verify both keys with a tiny live request; updates the per-key status.
    func checkKeys() {
        googleCheck = googleKey.isEmpty ? .fail("kein Schlüssel") : .checking
        groqCheck = groqKey.isEmpty ? .fail("kein Schlüssel") : .checking
        let voice = "\(langCode(language))-Chirp3-HD-\(voiceName)"
        Task { [googleKey, groqKey] in
            async let g = Validation.google(googleKey, voice: voice)
            async let q = Validation.groq(groqKey)
            let (gc, qc) = await (g, q)
            await MainActor.run {
                self.googleCheck = gc; self.groqCheck = qc
                if gc == .ok { self.loadVoices() }
            }
        }
    }

    @Published var forward = true   // step direction — drives the slide transition

    func next() {
        guard let s = Step(rawValue: step.rawValue + 1) else { return }
        // Voice just chosen → render the tutorial in that voice, before other cache clips.
        if step == .voice { VoicePreview.stop(); prepareTutorial() }
        forward = true
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { step = s }
    }
    func back() {
        guard let s = Step(rawValue: step.rawValue - 1) else { return }
        if step == .tutorial { stopTutorialAudio() }
        forward = false
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { step = s }
    }

    func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in self.micGranted = granted }
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
    }
}

struct OnboardingView: View {
    @StateObject private var m: OnboardingModel
    var onDone: () -> Void

    init(startAt: OnboardingModel.Step = .welcome, onDone: @escaping () -> Void) {
        _m = StateObject(wrappedValue: OnboardingModel(start: startAt))
        self.onDone = onDone
    }

    var body: some View {
        ZStack {
            VisualEffectBackground().ignoresSafeArea()
            VStack(spacing: 0) {
                progress.padding(.top, 22)
                Spacer(minLength: 0)
                content
                    .frame(maxWidth: 520).padding(.horizontal, 48)
                    .id(m.step)                                   // recreate per step → entrance re-fires
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: m.forward ? 34 : -34)),
                        removal:   .opacity.combined(with: .offset(x: m.forward ? -34 : 34))))
                Spacer(minLength: 0)
                bottomBar.padding(.horizontal, 40).padding(.bottom, 26)
            }
            .clipped()
        }
        .frame(width: 640, height: 560)
        .onAppear { m.loadVoices() }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(0..<m.totalSteps, id: \.self) { i in
                Capsule().fill(i <= m.step.rawValue ? Color.accentColor : Color.white.opacity(0.18))
                    .frame(width: i == m.step.rawValue ? 22 : 8, height: 6)
                    .animation(.easeInOut(duration: 0.25), value: m.step)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch m.step {
        case .welcome:
            hero("waveform", "Willkommen bei Parley",
                 "Deine Sprachschicht für Claude Code und Codex. Am Ende jeder Antwort spricht Parley die Zusammenfassung, hört deine Antwort und speist sie zurück — freihändig, im Charakter eines ruhigen Butlers.")
        case .integrations:
            VStack(spacing: 18) {
                hero("rectangle.2.swap", "Wo soll Parley laufen?",
                     "Erkannte Coding-Clients sind vorausgewählt. Du kannst die Verbindung jederzeit im Setup ändern.")
                VStack(spacing: 10) {
                    integrationChoice(.claudeCode, title: "Claude Code", subtitle: "Stop-Hook und /parley:voice")
                        .entrance(3)
                    integrationChoice(.codex, title: "Codex", subtitle: "Plugin und $parley-voice-Skill")
                        .entrance(4)
                }
                if !m.detectedClaude && !m.detectedCodex {
                    HStack(spacing: 10) {
                        Text("Kein Client gefunden.").font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("Claude Code installieren") { ClientIntegrations.openDownload(for: .claudeCode) }.buttonStyle(.link)
                        Button("Codex installieren") { ClientIntegrations.openDownload(for: .codex) }.buttonStyle(.link)
                    }.font(.system(size: 11)).entrance(5)
                }
            }
        case .keys:
            VStack(spacing: 18) {
                hero("key.fill", "API-Schlüssel", "Beide sind praktisch kostenlos. Öffne die Konsole, erstelle den Schlüssel, füge ihn ein — und prüfe.")
                VStack(alignment: .leading, spacing: 16) {
                    keyField("Google Cloud TTS", "1 Mio Zeichen/Monat gratis", text: $m.googleKey,
                             check: m.googleCheck, open: m.openGoogleConsole, guide: m.openGoogleGuide)
                    keyField("Groq", "kostenloser Developer-Key", text: $m.groqKey,
                             check: m.groqCheck, open: m.openGroqConsole, guide: m.openGroqGuide)
                }.entrance(3)
                Button(checking ? "Prüfe…" : "Schlüssel prüfen") { m.checkKeys() }
                    .buttonStyle(SecondaryButton()).disabled(checking).entrance(4)
                if !m.canContinue && !checking {
                    Label("Bitte zuerst beide Schlüssel prüfen, um fortzufahren.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange).entrance(5)
                }
            }
        case .voice:
            VStack(spacing: 20) {
                hero("globe", "Sprache & Stimme", "In welcher Sprache spreche ich, und mit welcher Stimme?")
                VStack(spacing: 14) {
                    labeledPicker("Sprache", selection: $m.language, options: onboardKeyLangs)
                        .onChange(of: m.language) { _, _ in m.loadVoices() }
                    labeledPicker("Chirp3-HD-Stimme", selection: $m.voiceName, options: m.voices)
                        .onChange(of: m.voiceName) { _, _ in m.previewVoice() }
                    Button {
                        m.previewVoice()
                    } label: {
                        Label(m.previewLoading ? "Erzeuge Vorschau…" : "Stimme anhören",
                              systemImage: "speaker.wave.2.fill")
                    }.buttonStyle(SecondaryButton()).disabled(m.previewLoading)
                    Text("Erste Wiedergabe wird kurz in deiner echten Stimme erzeugt — danach sofort.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.entrance(3)
            }
        case .notify:
            VStack(spacing: 20) {
                hero("bell.badge", "Benachrichtigungen", "Wie soll ich dich informieren, z. B. wenn ein Projekt wartet?")
                VStack(spacing: 10) {
                    choice("In der Pill", "Elegante Einblendung unten mittig", "rectangle.bottomthird.inset.filled", "pill").entrance(3)
                    choice("System-Mitteilung", "Klassische macOS-Benachrichtigung", "app.badge", "system").entrance(4)
                    choice("Keine", "Ganz ohne Benachrichtigungen", "bell.slash", "none").entrance(5)
                }
            }
        case .mic:
            VStack(spacing: 20) {
                hero("mic.fill", "Mikrofon", "Parley braucht dein Mikrofon, um deine Antworten aufzunehmen.")
                Button(m.micGranted ? "Mikrofon erlaubt ✓" : "Mikrofon erlauben") { m.requestMic() }
                    .buttonStyle(PrimaryButton())
                    .disabled(m.micGranted)
                    .entrance(3)
            }
        case .tutorial:
            tutorialCard
        case .done:
            VStack(spacing: 18) {
                hero("checkmark.seal.fill", "Bereit, Sir",
                     "Diese Befehle gehören zu den aktivierten Clients.")
                if m.installClaude {
                    clientCommand(.claudeCode, command: "/parley:voice")
                        .entrance(3)
                }
                if m.installCodex {
                    clientCommand(.codex, command: "$parley-voice")
                        .entrance(4)
                }
                if !m.installClaude && !m.installCodex {
                    Text("Du kannst die Clients später im Setup verbinden.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).entrance(3)
                }
            }
        }
    }

    @ViewBuilder private var tutorialCard: some View {
        let step = m.tutStep
        VStack(spacing: 16) {
            hero(step.symbol, step.title(m.language), step.displayLine(m.language))
            // sub-progress within the tutorial
            HStack(spacing: 5) {
                ForEach(0..<TutorialStep.allCases.count, id: \.self) { i in
                    Circle().fill(i <= m.tutIndex ? Color.accentColor : .white.opacity(0.16))
                        .frame(width: 6, height: 6)
                }
            }.entrance(3)
            if step.expect != .none {
                VStack(spacing: 8) {
                    Button(m.tutTrying ? "Höre zu…" : "Ausprobieren") { m.tryTut() }
                        .buttonStyle(SecondaryButton()).disabled(m.tutTrying)
                    if let ok = m.tutResult {
                        Label(ok ? "Genau so, Sir." : "Hab ich nicht erkannt — kein Problem, weiter geht's.",
                              systemImage: ok ? "checkmark.circle.fill" : "info.circle")
                            .font(.system(size: 12)).foregroundStyle(ok ? .green : .secondary)
                    }
                }.entrance(4)
            }
        }
        .onAppear { m.playTutLine() }
        .onDisappear { m.stopTutorialAudio() }
    }

    private var bottomBar: some View {
        HStack {
            if m.step != .welcome {
                Button("Zurück") { m.back() }.buttonStyle(SecondaryButton())
            }
            Spacer()
            if m.step == .done {
                Button("Los geht's") { m.finish(); onDone() }.buttonStyle(PrimaryButton())
            } else if m.step == .tutorial {
                Button("Überspringen") { m.skipTutorial() }.buttonStyle(SecondaryButton())
                Button(m.tutLast ? "Fertig" : "Weiter") { m.tutForward() }.buttonStyle(PrimaryButton())
            } else {
                Button("Weiter") { m.next() }.buttonStyle(PrimaryButton()).disabled(!m.canContinue)
            }
        }
    }

    // MARK: - building blocks

    private func hero(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold)).foregroundStyle(.tint)
                .frame(width: 60, height: 60)
                .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(.tint.opacity(0.14)))
                .entrance(0)
            Text(title).font(.system(size: 28, weight: .bold)).multilineTextAlignment(.center)
                .entrance(1)
            Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .entrance(2)
        }
    }

    private var checking: Bool { m.googleCheck == .checking || m.groqCheck == .checking }

    private func keyField(_ label: String, _ hint: String, text: Binding<String>,
                          check: OnboardingModel.Check, open: @escaping () -> Void,
                          guide: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 14) {
                Text(label).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: guide) {
                    Label("Anleitung", systemImage: "book.fill").font(.system(size: 11))
                }.buttonStyle(.link)
                Button(action: open) {
                    Label("Konsole öffnen", systemImage: "arrow.up.right.square").font(.system(size: 11))
                }.buttonStyle(.link)
            }
            SecureField("", text: text).textFieldStyle(.roundedBorder).onSubmit { m.checkKeys() }
            HStack(spacing: 5) {
                switch check {
                case .idle: Text(hint).font(.system(size: 11)).foregroundStyle(.tertiary)
                case .checking: ProgressView().controlSize(.small); Text("prüfe…").font(.system(size: 11)).foregroundStyle(.secondary)
                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green); Text("gültig").font(.system(size: 11)).foregroundStyle(.green)
                case .fail(let why): Image(systemName: "xmark.circle.fill").foregroundStyle(.red); Text(why).font(.system(size: 11)).foregroundStyle(.red)
                }
            }
        }
    }

    // Custom dropdown: a fixed-width field (Menu label) so both dropdowns match exactly.
    // A .menu Picker hugs its content, which made short values ("Deutsch") narrower.
    private func labeledPicker(_ label: String, selection: Binding<String>, options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 13, weight: .semibold))
            Menu {
                ForEach(options, id: \.self) { opt in
                    Button { selection.wrappedValue = opt } label: {
                        if opt == selection.wrappedValue { Label(opt, systemImage: "checkmark") } else { Text(opt) }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(selection.wrappedValue).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).frame(width: 260, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.12)))
            }
            .menuStyle(.button).buttonStyle(.plain)
        }
        .frame(width: 260, alignment: .leading)
    }

    private func choice(_ title: String, _ subtitle: String, _ symbol: String, _ value: String) -> some View {
        let on = m.notifyMode == value
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { m.notifyMode = value }
            Notifier.preview(value)   // live example on select
        } label: {
            HStack(spacing: 13) {
                Image(systemName: symbol).font(.system(size: 18))
                    .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(on ? Color.accentColor.opacity(0.12) : Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(on ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func integrationChoice(_ client: ClientIntegrations.Client, title: String,
                                   subtitle: String) -> some View {
        let detected = client == .claudeCode ? m.detectedClaude : m.detectedCodex
        let enabled = client == .claudeCode ? m.installClaude : m.installCodex
        return Button {
            if client == .claudeCode { m.installClaude.toggle() } else { m.installCodex.toggle() }
        } label: {
            HStack(spacing: 13) {
                ClientBrandIcon(client: client).frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                    Text(detected ? subtitle + " · gefunden" : "Nicht gefunden — später verbinden").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(enabled ? Color.accentColor.opacity(0.12) : Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(enabled ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!detected)
        .opacity(detected ? 1 : 0.55)
    }

    private func clientCommand(_ client: ClientIntegrations.Client, command: String) -> some View {
        HStack(spacing: 12) {
            ClientBrandIcon(client: client).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(client.displayName).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text(command).font(.system(size: 17, weight: .bold, design: .monospaced))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.tint.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.tint.opacity(0.28)))
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
            configuration.label.font(.system(size: 14, weight: .semibold))
                .foregroundStyle(enabled ? .white : Color.white.opacity(0.5))
                .padding(.horizontal, 22).padding(.vertical, 9)
                .background(Capsule().fill(enabled
                    ? Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1)
                    : Color.white.opacity(0.10)))   // greyed out when disabled
        }
    }
}
private struct SecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.06)))
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView(); v.material = .sidebar; v.blendingMode = .behindWindow; v.state = .active; return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// Hosts onboarding in a plain window (reliable for a menu-bar / LSUIElement app).
@MainActor
final class OnboardingPresenter {
    static let shared = OnboardingPresenter()
    private var window: NSWindow?

    static var isComplete: Bool { Keychain.get(.onboarded) == "1" }
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
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
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
