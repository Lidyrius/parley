import SwiftUI
import AVFoundation
import AppKit

// First-run onboarding: microphone permission + device, spoken language, and voice.
// Liquid Glass styling per DESIGN_BRIEF. Values persist to the same store Settings uses.

private let onboardingCompleteKey = "vloude.onboardingComplete"
private let onboardingLanguages = ["Deutsch", "English", "Français", "Español", "Italiano", "Nederlands"]

struct OnboardingView: View {
    let onDone: () -> Void

    enum Step: Int, CaseIterable { case welcome, keys, language, voice, microphone, done }
    @State private var step: Step = .welcome

    // persisted fields
    @State private var elevenKey = ""
    @State private var groqKey = ""
    @State private var language = "Deutsch"
    @State private var voiceID = ""
    @State private var micUID = ""

    // voice step
    @State private var voices: [ElevenLabs.Voice] = []
    @State private var loadingVoices = false
    @State private var voiceError: String?
    @State private var previewPlayer: AVPlayer?

    // mic step
    @State private var micStatus = micAuthString()
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView { content.padding(.horizontal, 30).padding(.vertical, 24) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: 580, height: 640)
        .background(background)
        .onAppear(perform: load)
    }

    // MARK: header

    private var header: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.tint)
                .frame(height: 40)
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .frame(width: s == step ? 22 : 7, height: 7)
                        .animation(.snappy, value: step)
                }
            }
            .padding(.top, 2)
        }
        .padding(.top, 30)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
    }

    // MARK: content per step

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:    welcomeStep
        case .keys:       keysStep
        case .language:   languageStep
        case .voice:      voiceStep
        case .microphone: micStep
        case .done:       doneStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            row("waveform", "Spricht Zusammenfassungen", "Wenn ein Claude-Code-Turn endet, spreche ich das Ergebnis — mit Charakter.")
            row("mic.fill", "Hört deine Antwort", "Du antwortest per Sprache; ich transkribiere und speise sie zurück in die Sitzung.")
            row("terminal.fill", "In jedem Terminal", "Warp, iTerm, tmux — egal. Kein Umbau deines Setups nötig.")
        }
    }

    private var keysStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            field("ElevenLabs API-Key", systemImage: "waveform.circle") {
                SecureField("xi-api-key", text: $elevenKey)
            }
            field("Groq API-Key", systemImage: "text.bubble") {
                SecureField("Bearer key", text: $groqKey)
            }
            Text("Wird lokal in einer geschützten Datei gespeichert — nie geteilt.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var languageStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("In welcher Sprache soll ich sprechen?").font(.callout)
            ForEach(onboardingLanguages, id: \.self) { lang in
                selectRow(title: lang, selected: language == lang) { language = lang }
            }
        }
    }

    private var voiceStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if loadingVoices {
                HStack { ProgressView().controlSize(.small); Text("Lade Stimmen…").foregroundStyle(.secondary) }
            } else if let err = voiceError {
                Text(err).font(.callout).foregroundStyle(.red)
                Button("Erneut laden") { Task { await loadVoices() } }
            } else if voices.isEmpty {
                Text("Keine Stimmen gefunden. Prüfe den ElevenLabs-Key im vorigen Schritt.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(voices) { v in
                    HStack(spacing: 10) {
                        selectRow(title: v.name, subtitle: v.category, selected: voiceID == v.voice_id) {
                            voiceID = v.voice_id
                        }
                        if v.preview_url != nil {
                            Button { preview(v) } label: { Image(systemName: "play.circle.fill") }
                                .buttonStyle(.plain).font(.title3).foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
        .task { if voices.isEmpty { await loadVoices() } }
    }

    private var micStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: micStatus == "authorized" ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(micStatus == "authorized" ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mikrofon-Zugriff").font(.callout.weight(.medium))
                    Text(micStatusText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if micStatus != "authorized" {
                    Button("Erlauben") { requestMic() }.buttonStyle(.borderedProminent)
                }
            }
            .padding(12)
            .glassEffect(in: .rect(cornerRadius: 12))

            Text("Welches Mikrofon?").font(.callout)
            if devices.isEmpty {
                Text("Keine Eingabegeräte gefunden.").font(.caption).foregroundStyle(.secondary)
            } else {
                selectRow(title: "Systemstandard", selected: micUID.isEmpty) { micUID = "" }
                ForEach(devices) { d in
                    selectRow(title: d.name, selected: micUID == d.uid) {
                        micUID = d.uid
                        AudioDevices.setDefaultInput(uid: d.uid)   // make it the system default input
                    }
                }
            }

            Divider().opacity(0.3)
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.secondary)
                Text("Für „Medien pausieren beim Sprechen“ brauche ich Bedienungshilfen.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Öffnen") { openAccessibility() }.controlSize(.small)
            }
        }
        .onAppear { devices = AudioDevices.inputDevices(); micStatus = Self.micAuthString() }
    }

    private var doneStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 46)).foregroundStyle(.green)
            Text("Alles bereit.").font(.title3.weight(.semibold))
            Text("Starte eine Claude-Code-Sitzung und tippe /vloude:voice. Ich melde mich, sobald ein Turn fertig ist.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            if step != .welcome && step != .done {
                Button("Zurück") { back() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer()
            Button(primaryLabel) { next() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 18)
    }

    // MARK: reusable rows

    private func row(_ symbol: String, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(desc).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private func field<Content: View>(_ label: String, systemImage: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: systemImage).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content().textFieldStyle(.roundedBorder)
        }
    }

    private func selectRow(title: String, subtitle: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(.primary)
                    if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 8).padding(.horizontal, 12)
            .background(selected ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }

    private var background: some View {
        ZStack {
            Rectangle().fill(.background)
            LinearGradient(colors: [.accentColor.opacity(0.10), .clear],
                           startPoint: .top, endPoint: .center).ignoresSafeArea()
        }
    }

    // MARK: step metadata

    private var icon: String {
        switch step {
        case .welcome: "sparkles"; case .keys: "key.fill"; case .language: "globe"
        case .voice: "waveform"; case .microphone: "mic.fill"; case .done: "checkmark.seal.fill"
        }
    }
    private var title: String {
        switch step {
        case .welcome: "Willkommen bei Vloude"; case .keys: "API-Schlüssel"; case .language: "Sprache"
        case .voice: "Stimme wählen"; case .microphone: "Mikrofon"; case .done: "Fertig"
        }
    }
    private var subtitle: String {
        switch step {
        case .welcome: "Dein Sprach-Layer über Claude Code. In wenigen Schritten eingerichtet."
        case .keys: "Für Sprachausgabe (ElevenLabs) und Transkription (Groq)."
        case .language: "Ich spreche jeden Turn in dieser Sprache."
        case .voice: "So klinge ich. Tippe auf ▶︎ zum Anhören."
        case .microphone: "Zugriff erlauben und dein Eingabegerät wählen."
        case .done: "Vloude läuft in der Menüleiste."
        }
    }
    private var primaryLabel: String {
        switch step { case .done: "Los geht's"; case .microphone: "Weiter"; default: "Weiter" }
    }

    private var micStatusText: String {
        switch micStatus {
        case "authorized": "Erlaubt."
        case "denied", "restricted": "Verweigert — in Systemeinstellungen → Datenschutz → Mikrofon erlauben."
        default: "Noch nicht erteilt."
        }
    }

    // MARK: actions

    private func next() {
        save()
        if step == .done { onDone(); return }
        if let n = Step(rawValue: step.rawValue + 1) { step = n }
    }
    private func back() {
        if let p = Step(rawValue: step.rawValue - 1) { step = p }
    }

    private func load() {
        elevenKey = Keychain.get(.elevenLabsAPIKey) ?? ""
        groqKey = Keychain.get(.groqAPIKey) ?? ""
        language = Keychain.get(.language) ?? "Deutsch"
        voiceID = Keychain.get(.voiceID) ?? ""
        micUID = Keychain.get(.micDeviceUID) ?? ""
    }

    private func save() {
        Keychain.set(elevenKey, for: .elevenLabsAPIKey)
        Keychain.set(groqKey, for: .groqAPIKey)
        Keychain.set(language, for: .language)
        Keychain.set(voiceID, for: .voiceID)
        Keychain.set(micUID, for: .micDeviceUID)
    }

    private func loadVoices() async {
        guard !elevenKey.isEmpty else { voiceError = "Kein ElevenLabs-Key gesetzt."; return }
        loadingVoices = true; voiceError = nil
        defer { loadingVoices = false }
        do {
            let (data, resp) = try await URLSession.shared.data(for: ElevenLabs.voicesRequest(apiKey: elevenKey))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                voiceError = "Stimmen konnten nicht geladen werden (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1))."
                return
            }
            var list = ElevenLabs.decodeVoices(data)
            // Jarvis (cloned) first if present.
            list.sort { ($0.voice_id == ElevenLabs.jarvisVoiceID ? 0 : 1) < ($1.voice_id == ElevenLabs.jarvisVoiceID ? 0 : 1) }
            voices = list
            if voiceID.isEmpty || !list.contains(where: { $0.voice_id == voiceID }) {
                voiceID = list.first(where: { $0.voice_id == ElevenLabs.jarvisVoiceID })?.voice_id
                    ?? list.first(where: { $0.voice_id == ElevenLabs.fallbackVoiceID })?.voice_id
                    ?? list.first?.voice_id ?? ""
            }
        } catch {
            voiceError = "Netzwerkfehler: \(error.localizedDescription)"
        }
    }

    private func preview(_ v: ElevenLabs.Voice) {
        guard let s = v.preview_url, let url = URL(string: s) else { return }
        let p = AVPlayer(url: url)
        previewPlayer = p
        p.play()
    }

    private func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async {
                micStatus = Self.micAuthString()
                devices = AudioDevices.inputDevices()
            }
        }
    }

    private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func micAuthString() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: "authorized"; case .denied: "denied"
        case .restricted: "restricted"; case .notDetermined: "notDetermined"
        @unknown default: "unknown"
        }
    }
}

// Hosts the onboarding in a plain NSWindow — reliable for a menu-bar (LSUIElement) app.
@MainActor
final class OnboardingPresenter {
    static let shared = OnboardingPresenter()
    private var window: NSWindow?

    static var isComplete: Bool { UserDefaults.standard.bool(forKey: onboardingCompleteKey) }

    func showIfNeeded() {
        if !Self.isComplete { show() }
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 640),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.center()
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: OnboardingView(onDone: { [weak self] in
                UserDefaults.standard.set(true, forKey: onboardingCompleteKey)
                self?.window?.close()
            }))
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
