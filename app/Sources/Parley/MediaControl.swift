import Foundation

// Media pause/resume via AppleScript (Apple Events) to scriptable media apps. Unlike
// MediaRemote (now-playing state is entitlement-gated for third-party apps on macOS
// 15.4+/26) and CoreAudio (device/process "running" stays true for paused media), a
// media app's own `player state` reliably reports playing vs paused. So we can detect
// what is ACTUALLY playing, pause exactly those, and resume exactly those afterwards —
// never starting media the user had already stopped.
//
// Needs Automation permission ("Parley möchte <App> steuern") — granted once per app on
// first use. If denied, osascript errors → the app is treated as not playing → no control.
//
// Covers scriptable music/media apps. Browser <video> (YouTube etc.) is not scriptable
// this way and is out of scope. ponytail: extend `apps` if another scriptable player matters.
final class MediaControl: @unchecked Sendable {
    static let shared = MediaControl()
    private init() {}

    // Apps that expose the standard `player state` / `play` / `pause` vocabulary.
    private let apps = ["Spotify", "Music"]

    /// Media apps currently PLAYING (running + player state "playing").
    func playingApps() -> [String] {
        apps.filter { app in
            osa("if application \"\(app)\" is running then tell application \"\(app)\" to return (player state as text)") == "playing"
        }
    }

    func pause(_ names: [String]) { for a in names { _ = osa("tell application \"\(a)\" to pause") } }
    func play(_ names: [String])  { for a in names { _ = osa("tell application \"\(a)\" to play") } }

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
