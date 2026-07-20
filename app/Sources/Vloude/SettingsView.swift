import SwiftUI

// API keys go to the Keychain; voice id too. Fields load current values on appear
// and write on change. Nothing is hard-coded or logged.
struct SettingsView: View {
    @State private var elevenKey = ""
    @State private var groqKey = ""
    @State private var voiceID = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section("ElevenLabs (TTS)") {
                SecureField("API key (xi-api-key)", text: $elevenKey)
                TextField("Voice ID", text: $voiceID)
            }
            Section("Groq (STT)") {
                SecureField("API key", text: $groqKey)
            }
            HStack {
                Spacer()
                if saved { Text("Saved").foregroundStyle(.green).font(.caption) }
                Button("Save to Keychain") { save() }
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
    }

    private func save() {
        Keychain.set(elevenKey, for: .elevenLabsAPIKey)
        Keychain.set(groqKey, for: .groqAPIKey)
        Keychain.set(voiceID, for: .voiceID)
        saved = true
    }
}
