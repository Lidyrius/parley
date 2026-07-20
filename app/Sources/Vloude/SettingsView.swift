import SwiftUI

// API keys go to the Keychain; voice id too. Fields load current values on appear
// and write on change. Nothing is hard-coded or logged.
struct SettingsView: View {
    @State private var elevenKey = ""
    @State private var groqKey = ""
    @State private var voiceID = ""
    @State private var language = "Deutsch"
    @State private var saved = false

    // Spoken-turn languages. Add more freely — the value is passed verbatim to Claude
    // ("speak in <language>"), so any language name Claude understands works.
    private let languages = ["Deutsch", "English", "Français", "Español", "Italiano", "Nederlands"]

    var body: some View {
        Form {
            Section("Sprache / Language") {
                Picker("Gesprochene Sprache", selection: $language) {
                    ForEach(languages, id: \.self) { Text($0).tag($0) }
                }
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
    }

    private func save() {
        Keychain.set(elevenKey, for: .elevenLabsAPIKey)
        Keychain.set(groqKey, for: .groqAPIKey)
        Keychain.set(voiceID, for: .voiceID)
        Keychain.set(language, for: .language)
        saved = true
    }
}
