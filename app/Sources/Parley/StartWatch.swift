import Foundation

// Start check: after Parley opens a Terminal tab for a new session (POST /dispatch), it looks at
// that tab every few seconds until the session shows up. A shell question whose default is No —
// "Add '<dir>' to Gas Town? [y/N/never]" — gets "n" at once (Sir's rule for Parley's starts).
// Anything else that still holds the start after 90 s goes to the Zentrale with the screen; it
// answers a harmless question through POST /starting/answer, or tells Sir. GET /starting lists
// the starts that are still on the way.
struct StartWatch {
    struct Entry {
        var cwd: String
        var tty: String?          // the Terminal tab ("/dev/ttys012"); nil = unknown, report only
        var since: Date
        var screen = ""           // its last lines, as last read
        var answered: Set<String> = []
        var reported = false
    }

    static let every: TimeInterval = 4
    static let reportAfter: TimeInterval = 90
    static let giveUp: TimeInterval = 600

    private(set) var entries: [Entry] = []

    mutating func begin(cwd: String, tty: String?, at: Date) {
        entries.removeAll { $0.cwd == cwd }
        entries.append(Entry(cwd: cwd, tty: tty, since: at))
    }

    mutating func end(_ cwd: String) { entries.removeAll { $0.cwd == cwd } }

    mutating func update(_ cwd: String, _ change: (inout Entry) -> Void) {
        if let i = entries.firstIndex(where: { $0.cwd == cwd }) { change(&entries[i]) }
    }

    func entry(_ cwd: String) -> Entry? { entries.first { $0.cwd == cwd } }

    // The screen's last non-empty lines.
    static func tail(_ screen: String, lines n: Int = 8) -> String {
        screen.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.suffix(n).joined(separator: "\n")
    }

    // The question waiting on the last line if its default is No — "[y/N]", "(y/N)",
    // "[y/N/never]" — so answering "n" is what the tool itself suggests; else nil.
    static func defaultNo(_ screen: String) -> String? {
        guard let last = tail(screen, lines: 1).split(separator: "\n").last.map(String.init),
              last.range(of: #"[\[(]y/N(/[A-Za-z]+)*[\])]\s*:?$"#, options: .regularExpression) != nil else { return nil }
        return last
    }

    // Claude Code's own "Is this a project you created or one you trust?" with "No, exit" chosen.
    // Sir's rule: a folder Parley starts a session in is trusted — so the answer is ↓ + Enter.
    static func trustDialog(_ screen: String) -> Bool {
        screen.contains("Yes, I trust this folder") && screen.contains("❯ No, exit")
    }
    static let trustKeys = "\u{1b}[B"   // arrow down; typing it adds the Enter

    // What the Zentrale gets when a start still hangs.
    static func note(cwd: String, screen: String, seconds: Int) -> String {
        let shown = screen.isEmpty ? "(nichts lesbar)" : screen
        return """
            [Parley · Start-Check] Die neue Session in \(cwd) ist nach \(seconds) s noch nicht da. Im Terminal steht zuletzt:
            ```
            \(shown)
            ```
            Ist das eine harmlose Rückfrage (z. B. ein Hinweis, ein Update-Angebot, ja/nein mit offensichtlicher Antwort), \
            beantworte sie selbst: POST /starting/answer mit {"cwd": "\(cwd)", "text": "<Antwort>"} (Text + Enter). \
            Ist es etwas anderes — Login, Fehler, eine echte Entscheidung —, sag es Sir kurz.
            """
    }
}

// The Terminal tabs Parley opened, through AppleScript (osascript, argv only — nothing spliced
// into script source). Blocking; called off the server queue.
enum TerminalTabs {
    private static let find = """
        on run argv
          tell application "Terminal"
            repeat with w in windows
              repeat with t in tabs of w
                if tty of t is (item 1 of argv) then
                  if (count of argv) > 1 then
                    do script (item 2 of argv) in t
                    return "ok"
                  end if
                  return history of t
                end if
              end repeat
            end repeat
          end tell
          error "no tab"
        end run
        """

    // The tab's text (`history`: its scrollback — `contents of t` would be AppleScript's own
    // `contents`, the tab reference); nil when the tab is gone.
    static func screen(tty: String) -> String? { run([tty]) }

    // Types `text` and Enter into the tab (into whatever runs there).
    static func type(_ text: String, tty: String) -> Bool { run([tty, text]) == "ok" }

    private static func run(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", find] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}

// Sir's rule for Parley's starts: the folder is trusted. Claude Code keeps that answer per folder
// in ~/.claude.json (projects[<dir>].hasTrustDialogAccepted) — set it before the start, so the
// dialog (default: "No, exit") never comes up. Read right before the write and replaced
// atomically: running sessions rewrite the file too.
enum ClaudeTrust {
    static let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")

    // true = the flag was set now (false: already trusted, or no readable config — then the
    // start check answers the dialog).
    @discardableResult
    static func accept(_ dir: String, file: URL = file) -> Bool {
        guard let data = try? Data(contentsOf: file),
              var config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        var projects = config["projects"] as? [String: Any] ?? [:]
        var entry = projects[dir] as? [String: Any] ?? [:]
        guard entry["hasTrustDialogAccepted"] as? Bool != true else { return false }
        entry["hasTrustDialogAccepted"] = true
        projects[dir] = entry
        config["projects"] = projects
        guard let out = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return false }
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".claude.json.parley-\(UUID().uuidString)")
        do {
            try out.write(to: tmp)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            Log.write("trust: could not mark \(dir) as trusted (\(error.localizedDescription))")
            return false
        }
        Log.write("trust: \(dir) marked as trusted for Claude Code (Sir's rule for Parley's starts)")
        return true
    }
}
