import Foundation

// Media pause/resume via AppleScript (Apple Events). A media app's own state is the only
// reliable "is it playing" signal — MediaRemote now-playing is entitlement-gated for
// third-party apps on macOS 15.4+/26, and CoreAudio "running" stays true for paused media.
//
// Two kinds of source:
//  • Scriptable players (Spotify, Apple Music): `player state` → playing/paused/stopped.
//  • Browser <video> (Chrome): JS `!video.paused` per tab. Requires Chrome's
//    "View → Developer → Allow JavaScript from Apple Events" (off by default) — if it's
//    off the JS throws, we catch it, and browser video simply isn't controlled.
//
// We detect what is ACTUALLY playing, pause exactly that, and resume exactly that — never
// touching media the user had already paused. pausePlaying() returns opaque tokens that
// resume() consumes. Needs Automation permission (NSAppleEventsUsageDescription), granted
// once per target app.
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
        for (w, t) in chromePlayingTabs() {
            _ = chromeJS(w, t, "var v=document.querySelector('video'); if(v) v.pause();")
            paused.append("chrome:\(w),\(t)")
        }
        return paused
    }

    /// Resume exactly what pausePlaying() paused.
    func resume(_ tokens: [String]) {
        for tok in tokens {
            if tok.hasPrefix("app:") {
                _ = osa("tell application \"\(tok.dropFirst(4))\" to play")
            } else if tok.hasPrefix("chrome:") {
                let p = tok.dropFirst(7).split(separator: ",")
                if p.count == 2, let w = Int(p[0]), let t = Int(p[1]) {
                    _ = chromeJS(w, t, "var v=document.querySelector('video'); if(v) v.play();")
                }
            }
        }
    }

    // MARK: - scriptable players

    private func playerState(_ app: String) -> String {
        osa("if application \"\(app)\" is running then tell application \"\(app)\" to return (player state as text)")
    }

    // MARK: - Chrome tabs

    /// (window, tab) 1-based indices of Chrome tabs with a playing <video>. Empty if Chrome
    /// isn't running or JS-from-Apple-Events is disabled.
    private func chromePlayingTabs() -> [(Int, Int)] {
        let script = """
        if application "Google Chrome" is running then
          tell application "Google Chrome"
            set out to ""
            repeat with w from 1 to (count windows)
              repeat with t from 1 to (count tabs of window w)
                try
                  set p to execute (tab t of window w) javascript "(function(){var v=document.querySelector('video');return v&&!v.paused&&!v.ended&&v.currentTime>0?'1':'0';})()"
                  if p is "1" then set out to out & w & "," & t & linefeed
                end try
              end repeat
            end repeat
            return out
          end tell
        end if
        """
        return osa(script).split(separator: "\n").compactMap { line in
            let p = line.split(separator: ","); guard p.count == 2, let w = Int(p[0]), let t = Int(p[1]) else { return nil }
            return (w, t)
        }
    }

    @discardableResult
    private func chromeJS(_ w: Int, _ t: Int, _ js: String) -> String {
        osa("tell application \"Google Chrome\" to execute (tab \(t) of window \(w)) javascript \"\(js.replacingOccurrences(of: "\"", with: "\\\""))\"")
    }

    // MARK: - osascript

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
