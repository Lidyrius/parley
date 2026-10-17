import Foundation

// The Zentrale (docs/IPHONE.md, stage 3): a permanent Claude Code session in its own folder,
// Parley voice on, that takes general requests (find / create projects, start sessions). The
// host creates its folder from the repo's `zentrale/` template, starts sessions in Terminal and
// keeps instructions for a folder pending until a session there shows up.

struct ZentraleSettings: Equatable {
    static let defaultZentrale = "~/workspace/privat/parley-zentrale"
    static let defaultProjects = "~/workspace/privat"

    var zentraleDir: String   // absolute, normalized
    var projectsDir: String

    static func load() -> ZentraleSettings {
        func dir(_ key: Keychain.Key, _ fallback: String) -> String {
            let v = Keychain.get(key) ?? ""
            return Zentrale.normalize(v.isEmpty ? fallback : v)
        }
        return ZentraleSettings(zentraleDir: dir(.zentraleDir, defaultZentrale), projectsDir: dir(.projectsDir, defaultProjects))
    }
}

enum Zentrale {
    static let label = "Zentrale"
    /// Spoken when a wake request lands in the Zentrale.
    static let takeOver = [
        "Ich kümmere mich darum, Sir.",
        "Ich nehme mich der Sache an, Sir.",
        "Alles klar, Sir. Ich habe gleich Infos für Sie.",
    ]

    /// "~" expanded, "." / ".." / duplicate and trailing slashes removed — the one form every
    /// cwd is compared in.
    static func normalize(_ path: String) -> String {
        let p = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        return (p as NSString).standardizingPath
    }

    static func isDirectory(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    /// The template in the Parley checkout (`sourceDir`, default ~/.parley/src): <src>/zentrale.
    static func templateDir() -> URL? {
        let src = Keychain.get(.sourceDir).flatMap { $0.isEmpty ? nil : $0 } ?? "~/.parley/src"
        let dir = URL(fileURLWithPath: normalize(src)).appendingPathComponent("zentrale", isDirectory: true)
        return isDirectory(dir.path) ? dir : nil
    }

    /// Creates the Zentrale's folder when it is missing — a copy of the template, or (no template)
    /// just `.parley.json` {"name":"Zentrale"} — and keeps `projectsDir` in its `.parley.json`
    /// current, which is where the Zentrale reads it. true = the folder was created now.
    @discardableResult
    static func ensure(_ s: ZentraleSettings, template: URL?) throws -> Bool {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: s.zentraleDir, isDirectory: true)
        var created = false
        if !isDirectory(dir.path) {
            try fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let template {
                try fm.copyItem(at: template, to: dir)
            } else {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            created = true
        }
        let file = dir.appendingPathComponent(".parley.json")
        var json = (try? Data(contentsOf: file)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        let before = json as NSDictionary
        if (json["name"] as? String ?? "").isEmpty { json["name"] = label }
        json["projectsDir"] = s.projectsDir
        if !created, before.isEqual(to: json) { return created }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try (data + Data("\n".utf8)).write(to: file, options: .atomic)
        return created
    }
}

// Starts a visible, interactive Claude Code CLI session in Terminal.app (in the background, no
// `activate`): `cd '<dir>' && claude '/parley:voice'`. The command line carries only the folder
// (shell-quoted) and the fixed first prompt — never an instruction; those stay pending by cwd.
// The command reaches AppleScript as argv, so nothing is spliced into script source either.
enum SessionStarter {
    static let firstPrompt = "/parley:voice"

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    static func command(folder: String) -> String { "cd \(shellQuote(folder)) && claude \(shellQuote(firstPrompt))" }

    static func osascriptArguments(folder: String) -> [String] {
        ["-e", "on run argv", "-e", #"tell application "Terminal" to do script (item 1 of argv)"#, "-e", "end run",
         command(folder: folder)]
    }

    static func start(folder: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = osascriptArguments(folder: folder)
        p.standardOutput = Pipe()
        let err = Pipe()
        p.standardError = err
        p.terminationHandler = { proc in
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Log.write("session start in \(folder): osascript exit \(proc.terminationStatus)\(msg.isEmpty ? "" : " — \(msg)")")
        }
        do { try p.run() } catch { Log.write("session start in \(folder) failed: \(error.localizedDescription)") }
    }
}

// Instructions waiting for a session in a folder (POST /dispatch, a routed wake to a Zentrale
// that is not running): handed over when a session there shows up, dropped after 10 min.
struct PendingInstructions {
    static let ttl: TimeInterval = 600

    private var items: [String: [(text: String, at: Date)]] = [:]

    mutating func add(_ text: String, cwd: String, at: Date) {
        items[cwd, default: []].append((text, at))
    }

    func has(cwd: String, now: Date) -> Bool {
        items[cwd]?.contains { now.timeIntervalSince($0.at) < Self.ttl } ?? false
    }

    /// Everything still fresh for `cwd`, oldest first, joined — and gone from the store.
    mutating func take(cwd: String, now: Date) -> String? {
        guard let list = items.removeValue(forKey: cwd) else { return nil }
        let fresh = list.filter { now.timeIntervalSince($0.at) < Self.ttl }.map(\.text)
        return fresh.isEmpty ? nil : fresh.joined(separator: "\n\n")
    }

    /// Drops expired instructions; returns the folders that lost any (for the log).
    @discardableResult
    mutating func prune(now: Date) -> [String] {
        var dropped: [String] = []
        for (cwd, list) in items {
            let fresh = list.filter { now.timeIntervalSince($0.at) < Self.ttl }
            if fresh.count != list.count { dropped.append(cwd) }
            items[cwd] = fresh.isEmpty ? nil : fresh
        }
        return dropped.sorted()
    }
}
