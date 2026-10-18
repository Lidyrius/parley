import SwiftUI

// API keys go to the Keychain; voice id too. Fields load current values on appear
// and write on change. Nothing is hard-coded or logged.
struct SettingsView: View {
    @State private var elevenKey = ""
    @State private var groqKey = ""
    @State private var voiceID = ""
    @State private var language = "Deutsch"
    @State private var speakingRate = 1.0
    @State private var notifyMode = "pill"
    @State private var saved = false

    // Spoken-turn languages. Add more freely — the value is passed verbatim to Claude
    // ("speak in <language>"), so any language name Claude understands works.
    private let languages = ["Deutsch", "English", "Français", "Español", "Italiano", "Nederlands"]

    var body: some View {
        Form {
            Section("App-Symbol") {
                AppIconPicker(controller: AppController.shared)
            }
            Section("Sprache / Language") {
                Picker("Gesprochene Sprache", selection: $language) {
                    ForEach(languages, id: \.self) { Text($0).tag($0) }
                }
            }
            Section("Sprechtempo") {
                HStack {
                    Slider(value: $speakingRate, in: 0.5...2.0, step: 0.25)
                    Text(String(format: "%.2g×", speakingRate)).monospacedDigit().frame(width: 44)
                }
            }
            Section("Benachrichtigungen") {
                Picker("Anzeige", selection: $notifyMode) {
                    Text("In der Pill").tag("pill")
                    Text("System-Mitteilung").tag("system")
                    Text("Keine").tag("none")
                }
                .onChange(of: notifyMode) { _, m in Notifier.preview(m) }
            }
            Section("ElevenLabs (TTS)") {
                SecureField("API key (xi-api-key)", text: $elevenKey)
                TextField("Voice ID", text: $voiceID)
            }
            Section("Groq (STT)") {
                SecureField("API key", text: $groqKey)
            }
            HStack {
                Spacer()
                if saved { Text("Gespeichert").foregroundStyle(.green).font(.caption) }
                Button("Speichern") { save() }
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear(perform: load)
    }

    private func load() {
        elevenKey = Keychain.get(.elevenLabsAPIKey) ?? ""
        groqKey = Keychain.get(.groqAPIKey) ?? ""
        voiceID = Keychain.get(.voiceID) ?? ""
        language = Keychain.get(.language) ?? "Deutsch"
        speakingRate = Double(Keychain.get(.speakingRate) ?? "") ?? 1.0
        notifyMode = AppConfig.load().notifyMode
    }

    private func save() {
        Keychain.set(elevenKey, for: .elevenLabsAPIKey)
        Keychain.set(groqKey, for: .groqAPIKey)
        Keychain.set(voiceID, for: .voiceID)
        Keychain.set(language, for: .language)
        Keychain.set(String(speakingRate), for: .speakingRate)
        Keychain.set(notifyMode, for: .notifyMode)
        saved = true
    }
}

/// The four icons side by side; a click switches at once (no "Speichern" needed).
private struct AppIconPicker: View {
    @ObservedObject var controller: AppController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 18) {
            ForEach(AppIconChoice.allCases) { choice in
                let on = controller.appIcon == choice
                Button { controller.appIcon = choice } label: {
                    VStack(spacing: 6) {
                        Group {
                            if let image = choice.image(dark: scheme == .dark) {
                                Image(nsImage: image).resizable().scaledToFit()
                            } else {
                                RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                            }
                        }
                        .frame(width: 56, height: 56)
                        .padding(3)
                        .overlay {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .strokeBorder(on ? Color.accentColor : .clear, lineWidth: 2.5)
                        }
                        Text(choice.name)
                            .font(.caption)
                            .foregroundStyle(on ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("App-Symbol \(choice.name)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

