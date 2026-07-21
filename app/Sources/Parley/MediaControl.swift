import Foundation

// Media pause/resume via AppleScript (Apple Events) to scriptable media apps. A media
// app's own `player state` is the only reliable "is it playing" signal — MediaRemote
// now-playing is entitlement-gated for third-party apps on macOS 15.4+/26, and CoreAudio
// "running" stays true for paused media.
//
// We detect what is ACTUALLY playing, pause exactly that, and resume exactly that — never
// touching media the user had already paused. pausePlaying() returns tokens that resume()
// consumes. Needs Automation permission (NSAppleEventsUsageDescription), granted once per
// target app.
//
// Scope: scriptable players (Spotify, Apple Music). Browser <video> is intentionally not
// covered — it would need per-browser "Allow JavaScript from Apple Events" enabled.
// ponytail: add to `scriptableApps` any player exposing the standard player state vocab.
final class MediaControl: @unchecked Sendable {
    static let shared = MediaControl()
    private init() {}

    private let scriptableApps = ["Spotify", "Music"]

    /// Pause everything currently playing; return tokens describing what was paused.
    func pausePlaying() -> [String] {
        var paused: [String] = []
        for app in scriptableApps where playerState(app) == "playing" {
            _ = osa("tell application \"\(app)\" to pause")
            paused.append("app:\(app)")
        }
        return paused
    }

    /// Resume exactly what pausePlaying() paused.
    func resume(_ tokens: [String]) {
        for tok in tokens where tok.hasPrefix("app:") {
            _ = osa("tell application \"\(tok.dropFirst(4))\" to play")
        }
    }

    private func playerState(_ app: String) -> String {
        osa("if application \"\(app)\" is running then tell application \"\(app)\" to return (player state as text)")
    }

    @discardableResult
    private func osa(_ script: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
