import Foundation

// Credential store for the two API keys + selected voice id.
// ponytail: a 0600 file in Application Support, not the Keychain. The real Keychain
// ties each item's ACL to the app's code signature; with ad-hoc re-signing on every
// rebuild the signature changes, so macOS treats each build as a new app and nags for
// the login-keychain password. For a personal single-user tool that friction isn't
// worth it. Upgrade path: sign the app with a stable Developer-ID cert, then switch
// set/get back to SecItem* for real Keychain protection. Type name kept as `Keychain`
// so callers (SettingsView, AppConfig) don't change.
enum Keychain {
    enum Key: String, CaseIterable {
        case elevenLabsAPIKey
        case groqAPIKey
        case voiceID
        case language      // spoken-turn language, e.g. "Deutsch" / "English". Default Deutsch.
        case micDeviceUID  // selected input device UID; empty = system default
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parley", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return base.appendingPathComponent("credentials.json")
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    private static func save(_ dict: [String: String]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func set(_ value: String, for key: Key) {
        var dict = load()
        if value.isEmpty { dict.removeValue(forKey: key.rawValue) }
        else { dict[key.rawValue] = value }
        save(dict)
    }

    static func get(_ key: Key) -> String? {
        load()[key.rawValue]
    }
}

// Runtime config resolved from Keychain, falling back to env vars (handy for the
// smoke test / headless runs).
struct AppConfig {
    var elevenLabsKey: String
    var groqKey: String
    var voiceID: String
    var language: String

    static func load() -> AppConfig {
        func val(_ k: Keychain.Key, _ env: String) -> String {
            Keychain.get(k) ?? ProcessInfo.processInfo.environment[env] ?? ""
        }
        let lang = Keychain.get(.language) ?? ProcessInfo.processInfo.environment["PARLEY_LANGUAGE"] ?? ""
        return AppConfig(
            elevenLabsKey: val(.elevenLabsAPIKey, "ELEVENLABS_API_KEY"),
            groqKey: val(.groqAPIKey, "GROQ_API_KEY"),
            voiceID: val(.voiceID, "ELEVENLABS_VOICE_ID"),
            language: lang.isEmpty ? "Deutsch" : lang)
    }

    var ttsReady: Bool { !elevenLabsKey.isEmpty && !voiceID.isEmpty }
    var sttReady: Bool { !groqKey.isEmpty }
}
