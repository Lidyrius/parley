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
    enum Step: Int, CaseIterable { case welcome, keys, voice, notify, mic, done }
    @Published var step: Step = .welcome
    @Published var googleKey = Keychain.get(.googleAPIKey) ?? ""
    @Published var groqKey = Keychain.get(.groqAPIKey) ?? ""
    @Published var language = Keychain.get(.language) ?? "Deutsch"
    @Published var voiceName = "Alnilam"        // Chirp3 HD star name
    @Published var notifyMode = AppConfig.load().notifyMode
    @Published var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published var voices: [String] = ["Alnilam", "Aoede", "Charon", "Kore", "Puck", "Fenrir"]

    var totalSteps: Int { Step.allCases.count }
    var canContinue: Bool {
        switch step {
        case .keys: return !googleKey.isEmpty && !groqKey.isEmpty
        default: return true
        }
    }

    func next() {
        if let s = Step(rawValue: step.rawValue + 1) { withAnimation(.easeInOut(duration: 0.25)) { step = s } }
    }
    func back() {
        if let s = Step(rawValue: step.rawValue - 1) { withAnimation(.easeInOut(duration: 0.25)) { step = s } }
    }

    func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in self.micGranted = granted }
        }
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
        Keychain.set("1", for: .onboarded)
    }
}

struct OnboardingView: View {
    @StateObject private var m = OnboardingModel()
    var onDone: () -> Void

    var body: some View {
        ZStack {
            VisualEffectBackground().ignoresSafeArea()
            VStack(spacing: 0) {
                progress.padding(.top, 22)
                Spacer(minLength: 0)
                content.frame(maxWidth: 520).padding(.horizontal, 48)
                Spacer(minLength: 0)
                bottomBar.padding(.horizontal, 40).padding(.bottom, 26)
            }
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
                 "Deine Sprachschicht für Claude Code. Am Ende jeder Antwort spricht Parley die Zusammenfassung, hört deine Antwort und speist sie zurück — freihändig, im Charakter eines ruhigen Butlers.")
        case .keys:
            VStack(spacing: 20) {
                hero("key.fill", "API-Schlüssel", "Beide sind praktisch kostenlos.")
                VStack(alignment: .leading, spacing: 14) {
                    field("Google Cloud TTS", "console.cloud.google.com → Cloud Text-to-Speech aktivieren → API-Key. 1 Mio Zeichen/Monat gratis.",
                          text: $m.googleKey, onCommit: m.loadVoices)
                    field("Groq", "console.groq.com → API Keys → Create. Kostenloser Developer-Key.", text: $m.groqKey)
                }
            }
        case .voice:
            VStack(spacing: 20) {
                hero("globe", "Sprache & Stimme", "In welcher Sprache spreche ich, und mit welcher Stimme?")
                VStack(spacing: 14) {
                    labeledPicker("Sprache", selection: $m.language, options: onboardKeyLangs)
                        .onChange(of: m.language) { _, _ in m.loadVoices() }
                    labeledPicker("Chirp3-HD-Stimme", selection: $m.voiceName, options: m.voices)
                }
            }
        case .notify:
            VStack(spacing: 20) {
                hero("bell.badge", "Benachrichtigungen", "Wie soll ich dich informieren, z. B. wenn ein Projekt wartet?")
                VStack(spacing: 10) {
                    choice("In der Pill", "Elegante Einblendung unten mittig", "rectangle.bottomthird.inset.filled", "pill")
                    choice("System-Mitteilung", "Klassische macOS-Benachrichtigung", "app.badge", "system")
                    choice("Keine", "Ganz ohne Benachrichtigungen", "bell.slash", "none")
                }
            }
        case .mic:
            VStack(spacing: 20) {
                hero("mic.fill", "Mikrofon", "Parley braucht dein Mikrofon, um deine Antworten aufzunehmen.")
                Button(m.micGranted ? "Mikrofon erlaubt ✓" : "Mikrofon erlauben") { m.requestMic() }
                    .buttonStyle(PrimaryButton())
                    .disabled(m.micGranted)
            }
        case .done:
            hero("checkmark.seal.fill", "Fertig!",
                 "Starte eine neue Claude-Code-Sitzung und tippe /parley:voice. Ich melde mich.")
        }
    }

    private var bottomBar: some View {
        HStack {
            if m.step != .welcome {
                Button("Zurück") { m.back() }.buttonStyle(SecondaryButton())
            }
            Spacer()
            if m.step == .done {
                Button("Los geht's") { m.finish(); onDone() }.buttonStyle(PrimaryButton())
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
            Text(title).font(.system(size: 28, weight: .bold)).multilineTextAlignment(.center)
            Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(_ label: String, _ hint: String, text: Binding<String>, onCommit: @escaping () -> Void = {}) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 13, weight: .semibold))
            SecureField("", text: text).textFieldStyle(.roundedBorder).onSubmit(onCommit)
            Text(hint).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    private func labeledPicker(_ label: String, selection: Binding<String>, options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 13, weight: .semibold))
            Picker("", selection: selection) { ForEach(options, id: \.self) { Text($0).tag($0) } }
                .labelsHidden().pickerStyle(.menu)
                .frame(width: 260)               // equal width for both dropdowns
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
}

private struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 22).padding(.vertical, 9)
            .background(Capsule().fill(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1)))
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

    func showIfNeeded() { if !Self.isComplete { show() } }

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Parley"
        w.isReleasedWhenClosed = false
        w.center()
        w.contentView = NSHostingView(rootView: OnboardingView(onDone: { [weak self] in
            self?.window?.close(); self?.window = nil
        }))
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
