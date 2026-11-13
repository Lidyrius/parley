import Foundation

// Remote Control (Claude Code's /remote-control: the session is reachable from the Claude app and
// claude.ai/code) for every session Parley starts or that registers with it. Parley's own starts
// carry `--remote-control`; a session that registers without it gets `/remote-control` typed into
// its Terminal tab once, while it is idle. `remoteControl` "0" in credentials.json: neither.
// Claude Code's own `remoteControlAtStartup` setting does the same for every session — not ours to set.
enum RemoteControl {
    static let flag = "--remote-control"
    static var on: Bool { Keychain.get(.remoteControl) != "0" }

    // ~/.claude/sessions/<pid>.json — `bridgeSessionId` is there iff Remote Control is connected.
    struct State: Decodable, Equatable {
        let pid: Int32
        let sessionId: String
        var status: String?          // idle | busy | waiting | shell
        var bridgeSessionId: String?
        var connected: Bool { !(bridgeSessionId ?? "").isEmpty }
    }

    static let sessionsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")

    static func state(of id: String, dir: URL = sessionsDir) -> State? {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .lazy.compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } }
            .first { $0.sessionId == id }
    }

    enum Step: Equatable { case later, done, type(pid: Int32) }

    // A session seen again (presence / turn / wake) that has not had its one try: type now only
    // when Claude Code says idle and Parley holds nothing for it (`parley`: its registry state —
    // "parked" = finished, nobody's voice dialog runs, no turn waits at the gate).
    static func decide(_ s: State?, parley: String?) -> Step {
        guard let s else { return .later }
        if s.connected { return .done }
        guard s.status == "idle", parley == "parked" else { return .later }
        return .type(pid: s.pid)
    }

    // The dialog `/remote-control` opens, its first option chosen: "❯ 1. Enable Remote Control".
    static func enableSelected(_ screen: String) -> Bool {
        StartWatch.tail(screen, lines: 15).split(separator: "\n")
            .contains { $0.contains("❯") && $0.contains("Enable Remote Control") }
    }

    // The tty of a process ("/dev/ttys012"), nil without one.
    static func tty(pid: Int32) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "tty=", "-p", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let t = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        p.waitUntilExit()
        return t.isEmpty || t.hasPrefix("?") ? nil : "/dev/" + t
    }

    // The one try, off the server queue (blocking). Only a Terminal.app tab can be typed into;
    // iTerm, Warp, VS Code, the desktop app → logged and left alone.
    static func catchUp(id: String, label: String, pid: Int32) {
        guard let tty = tty(pid: pid), TerminalTabs.screen(tty: tty) != nil else {
            return Log.write("remote control: \(label) runs outside Terminal.app — not turned on (start it with \(flag))")
        }
        guard TerminalTabs.type("/remote-control", tty: tty) else { return Log.write("remote control: \(label) — could not type into \(tty)") }
        Thread.sleep(forTimeInterval: 1.5)
        if state(of: id)?.connected == true {   // no dialog: Claude Code connected at once
            return Log.write("remote control: \(label) — /remote-control typed, connected")
        }
        let screen = TerminalTabs.screen(tty: tty) ?? ""
        if enableSelected(screen) {
            _ = TerminalTabs.type("", tty: tty)   // Enter: "1. Enable Remote Control"
            Log.write("remote control: \(label) — /remote-control typed, enabling")
        } else {
            _ = TerminalTabs.type("\u{1b}", tty: tty)
            Log.write("remote control: \(label) — no \"Enable Remote Control\" on screen, Escape:\n\(StartWatch.tail(screen, lines: 4))")
        }
        Thread.sleep(forTimeInterval: 15)
        let on = state(of: id)?.connected == true
        Log.write("remote control: \(label) — \(on ? "connected" : "not connected after 15 s — given up")")
    }
}
