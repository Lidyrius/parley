import Foundation
import AppKit

// Client integration state is kept in the existing flat credentials file for
// backwards compatibility. The installer writes detection flags; onboarding writes
// the user's enabled choices, then asks the checkout scripts to apply them.
enum ClientIntegrations {
    enum Client: Equatable { case claudeCode, codex }

    /// Refresh detection when onboarding is opened. The installer persists a snapshot,
    /// but a GUI app may have been launched after a client was installed or with a shorter
    /// PATH than the user's shell.
    static func refreshDetection() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fixedPaths = [
            "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.volta/bin",
            "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"
        ]
        let shellPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        var paths = fixedPaths
        for path in shellPaths where !paths.contains(path) { paths.append(path) }

        func available(_ name: String) -> Bool {
            paths.contains { FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: $0).appendingPathComponent(name).path) }
        }

        Keychain.set(available("claude") ? "1" : "0", for: .detectedClaudeCode)
        Keychain.set(available("codex") ? "1" : "0", for: .detectedCodex)
    }

    static func detected(_ client: Client) -> Bool {
        Keychain.get(key(for: client, detected: true)) == "1"
    }

    static func enabled(_ client: Client) -> Bool {
        if let saved = Keychain.get(key(for: client, detected: false)) { return saved == "1" }
        return detected(client)
    }

    static func save(claudeCode: Bool, codex: Bool) {
        Keychain.set(claudeCode ? "1" : "0", for: .claudeCodeEnabled)
        Keychain.set(codex ? "1" : "0", for: .codexEnabled)
    }

    static func sync() {
        let source = Keychain.get(.sourceDir).flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".parley/src")
                .path
        let script = URL(fileURLWithPath: source).appendingPathComponent("scripts/sync-integrations.sh")
        guard FileManager.default.isReadableFile(atPath: script.path) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
    }

    static func openDownload(for client: Client) {
        let raw: String
        switch client {
        case .claudeCode: raw = "https://docs.anthropic.com/en/docs/claude-code/overview"
        case .codex: raw = "https://developers.openai.com/codex/cli"
        }
        if let url = URL(string: raw) { NSWorkspace.shared.open(url) }
    }

    private static func key(for client: Client, detected: Bool) -> Keychain.Key {
        switch (client, detected) {
        case (.claudeCode, true): return .detectedClaudeCode
        case (.codex, true): return .detectedCodex
        case (.claudeCode, false): return .claudeCodeEnabled
        case (.codex, false): return .codexEnabled
        }
    }
}
