import Foundation
import Security

// Tiny Keychain wrapper for the two API keys + selected voice id. Generic password
// items keyed by account name under one service. No key is ever hard-coded.
enum Keychain {
    static let service = "de.developaway.vloude"

    enum Key: String, CaseIterable {
        case elevenLabsAPIKey
        case groqAPIKey
        case voiceID
    }

    static func set(_ value: String, for key: Key) {
        let account = key.rawValue
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// Runtime config resolved from Keychain, falling back to env vars (handy for the
// smoke test / headless runs).
struct AppConfig {
    var elevenLabsKey: String
    var groqKey: String
    var voiceID: String

    static func load() -> AppConfig {
        func val(_ k: Keychain.Key, _ env: String) -> String {
            Keychain.get(k) ?? ProcessInfo.processInfo.environment[env] ?? ""
        }
        return AppConfig(
            elevenLabsKey: val(.elevenLabsAPIKey, "ELEVENLABS_API_KEY"),
            groqKey: val(.groqAPIKey, "GROQ_API_KEY"),
            voiceID: val(.voiceID, "ELEVENLABS_VOICE_ID"))
    }

    var ttsReady: Bool { !elevenLabsKey.isEmpty && !voiceID.isEmpty }
    var sttReady: Bool { !groqKey.isEmpty }
}
