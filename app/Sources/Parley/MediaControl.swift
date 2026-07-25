import Foundation

// Universal media pause/resume with zero user setup.
//
// Detection has two layers:
//  1. The SYSTEM Now-Playing session — exactly what the hardware play/pause key controls
//     (browser video/YouTube, QuickTime, VLC, Spotify, …). Reading its state is
//     entitlement-gated for third-party apps on macOS 15.4+/26, so we go through the
//     vendored mediaremote-adapter (BSD-3, github.com/ungive/mediaremote-adapter):
//     /usr/bin/perl carries Apple's com.apple.perl5 entitlement and loads the adapter
//     framework, which prints the real Now-Playing JSON (incl. `playing`) and can send
//     play/pause. Calls like Google Meet never register a Now-Playing session, so they are
//     never touched — only genuinely pausable media is.
//  2. Scriptable players (Spotify, Apple Music) via AppleScript `player state` — precise
//     per-app state even when they don't hold the system session. Needs the one-time
//     Automation prompt; if denied they're simply skipped.
//
// pausePlaying() pauses exactly what is ACTUALLY playing and returns tokens; resume()
// resumes exactly those. Media the user had already paused is never started.
final class MediaControl: @unchecked Sendable {
    static let shared = MediaControl()
    private init() {}

    private let scriptableApps = ["Spotify", "Music"]
    // Now-Playing bundle ids of the scriptable apps (avoid double-pausing via both layers).
    private let scriptableBundles: Set<String> = ["com.spotify.client", "com.apple.Music"]

    struct NowPlaying { let playing: Bool; let bundleID: String }

    /// Pause everything currently playing; return tokens describing what was paused.
    func pausePlaying() -> [String] {
        var paused: [String] = []
        let np = nowPlaying()   // snapshot BEFORE pausing anything
        for app in scriptableApps where playerState(app) == "playing" {
            _ = osa("tell application \"\(app)\" to pause")
            paused.append("app:\(app)")
        }
        if let np, np.playing, !scriptableBundles.contains(np.bundleID) {
            mrSend(1)           // kMRPause — explicit, never the toggle
            paused.append("mr")
        }
        return paused
    }

    /// Resume exactly what pausePlaying() paused.
    func resume(_ tokens: [String]) {
        for tok in tokens {
            if tok.hasPrefix("app:") {
                _ = osa("tell application \"\(tok.dropFirst(4))\" to play")
            } else if tok == "mr" {
                mrSend(0)       // kMRPlay
            }
        }
    }

    // MARK: - system Now-Playing (via mediaremote-adapter)

    private var adapterScript: String? {
        Bundle.main.resourceURL?.appendingPathComponent("mediaremote-adapter/mediaremote-adapter.pl").path
    }
    private var adapterFramework: String? {
        Bundle.main.resourceURL?.appendingPathComponent("mediaremote-adapter/MediaRemoteAdapter.framework").path
    }

    /// State of the system Now-Playing session, or nil when there is none / adapter missing.
    func nowPlaying() -> NowPlaying? {
        guard let script = adapterScript, let fw = adapterFramework,
              FileManager.default.fileExists(atPath: script) else { return nil }
        let out = run("/usr/bin/perl", [script, fw, "get"])
        guard let data = out.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }   // "null" (no session) or parse failure
        return NowPlaying(playing: obj["playing"] as? Bool ?? false,
                          bundleID: obj["bundleIdentifier"] as? String ?? "")
    }

    private func mrSend(_ command: Int) {
        guard let script = adapterScript, let fw = adapterFramework else { return }
        _ = run("/usr/bin/perl", [script, fw, "send", String(command)])
    }

    // MARK: - scriptable players (AppleScript)

    private func playerState(_ app: String) -> String {
        osa("if application \"\(app)\" is running then tell application \"\(app)\" to return (player state as text)")
    }

    @discardableResult
    private func osa(_ script: String) -> String {
        run("/usr/bin/osascript", ["-e", script])
    }

    // MARK: - process helper

    @discardableResult
    // Bounded process run. A hung osascript/perl (e.g. a pending Automation prompt) must
    // NEVER block a turn — if it exceeds `timeout`, kill it and return "". Media control is
    // best-effort; speech always proceeds.
    private func run(_ path: String, _ args: [String], timeout: TimeInterval = 3.0) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        // Drain stdout on a background thread — the adapter's now-playing JSON includes a
        // large base64 artwork blob (>64 KB); reading only after exit deadlocks perl on a
        // full pipe. Bound the whole thing with a timeout and kill on overrun.
        let handle = out.fileHandleForReading
        let box = OutBox()
        let group = DispatchGroup(); group.enter()
        DispatchQueue.global().async { box.data = handle.readDataToEndOfFile(); group.leave() }
        if group.wait(timeout: .now() + timeout) != .success {
            p.terminate(); usleep(100_000)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            Log.write("media: process timed out, killed (\(path))")
            return ""
        }
        p.waitUntilExit()
        return String(data: box.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private final class OutBox: @unchecked Sendable { var data = Data() }
