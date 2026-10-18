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
// Shell hooks on `cd` that ask before going on (Gas Town: "Add '<dir>' to Gas Town? [y/N/never]")
// would leave the session hanging on a question nobody sees: their opt-out goes first — for Gas
// Town that is "no" without asking.
enum SessionStarter {
    static let firstPrompt = "/parley:voice"

    static let quietHooks = "export GASTOWN_DISABLE_OFFER_ADD=1; "

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    // `resume`: a past session (checked by Transcript.isSessionID) continued with its history.
    static func command(folder: String, resume: String? = nil) -> String {
        let r = resume.map { " --resume \(shellQuote($0))" } ?? ""
        return "\(quietHooks)cd \(shellQuote(folder)) && claude\(r) \(shellQuote(firstPrompt))"
    }

    static func osascriptArguments(folder: String, resume: String? = nil) -> [String] {
        ["-e", "on run argv", "-e", #"tell application "Terminal" to do script (item 1 of argv)"#, "-e", "end run",
         command(folder: folder, resume: resume)]
    }

    static func start(folder: String, resume: String? = nil) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = osascriptArguments(folder: folder, resume: resume)
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

// POST /close: ends a Claude Code session — SIGTERM to its process group (claude with its hooks
// and MCP servers; the transcript is already on disk, so /past + /dispatch resume continue it).
// A terminal job: then its Terminal window closes once only the shell is left. A Claude desktop
// session: its own group under the app's `disclaimer` helper — the app and its other sessions
// stay; the app resumes that session itself when Sir writes in it again.
enum SessionCloser {
    struct Proc: Equatable { let pid: Int32; let tty: String; let args: String }

    /// Session `id`'s claude process: the one ~/.claude/sessions/<pid>.json names (`claimed`),
    /// else one with the id in its arguments (`--resume <id>`), else the only unclaimed terminal
    /// one working in `cwd` (a fresh `claude '/parley:voice'` names no id anywhere).
    static func pick(id: String, cwd: String, procs: [Proc], claimed: [Int32: String], cwds: [Int32: String]) -> Proc? {
        if let p = procs.first(where: { claimed[$0.pid] == id }) { return p }
        if let p = procs.first(where: { $0.args.contains(id) }) { return p }
        let here = procs.filter { $0.tty != "??" && claimed[$0.pid] == nil && !cwd.isEmpty && cwds[$0.pid] == cwd }
        return here.count == 1 ? here[0] : nil
    }

    /// How a session's process ends: a terminal job (its tty), or a Claude desktop session — its
    /// own process group led by the app's `disclaimer` helper (`--pgroup`), never the app's.
    enum Ending: Equatable { case terminal(String), desktop(group: Int32), refuse(String) }

    static func ending(_ p: Proc, group: Int32, leader: String?) -> Ending {
        if p.tty != "??" { return .terminal(p.tty) }
        if group > 1, group != p.pid, leader?.contains("/Contents/Helpers/disclaimer") == true { return .desktop(group: group) }
        return .refuse("neither a terminal nor a Claude desktop session — not closable from here")
    }

    /// nil = it is closing; else why not.
    static func close(id: String, cwd: String) -> String? {
        let procs = running()
        let tty = procs.filter { $0.tty != "??" }.map(\.pid)
        guard let p = pick(id: id, cwd: cwd, procs: procs, claimed: claimed(), cwds: cwds(tty)) else {
            return "no running claude process found for that session"
        }
        let group = getpgid(p.pid)
        let leader = group > 1 ? run("/bin/ps", ["-o", "args=", "-p", String(group)]).trimmingCharacters(in: .whitespacesAndNewlines) : nil
        switch ending(p, group: group, leader: leader) {
        case .refuse(let why):
            return why
        case .desktop(let g):
            killpg(g, SIGTERM)
            Log.write("close: SIGTERM to the desktop session's group \(g) (claude \(p.pid))")
            DispatchQueue.global().async {
                for _ in 0..<50 where kill(p.pid, 0) == 0 { usleep(100_000) }
                if kill(p.pid, 0) == 0 { killpg(g, SIGKILL) }
            }
            return nil
        case .terminal:
            break
        }
        // A shell job is its own process group: claude, its hooks and MCP servers end together.
        if getpgid(p.pid) == p.pid { killpg(p.pid, SIGTERM) } else { kill(p.pid, SIGTERM) }
        Log.write("close: SIGTERM to claude \(p.pid) on \(p.tty)")
        DispatchQueue.global().async {
            // Terminal asks before closing a window with anything but the shell in it, so first
            // claude, then what it leaves behind (MCP servers) must be gone.
            let tty = { onlyShell(run("/bin/ps", ["-t", p.tty, "-o", "ucomm="])) }
            for _ in 0..<50 where !tty() { usleep(100_000) }
            if !tty() {
                if getpgid(p.pid) == p.pid || kill(p.pid, 0) != 0 { killpg(p.pid, SIGKILL) } else { kill(p.pid, SIGKILL) }
                for _ in 0..<20 where !tty() { usleep(100_000) }
            }
            guard tty() else { return Log.write("close: \(p.tty) still busy — its window stays") }
            closeTerminal(tty: "/dev/" + p.tty)
        }
        return nil
    }

    // Every claude process, by argv[0]: `claude …`, a path to it (the desktop's has spaces), or
    // node running the npm cli.js. Not by process name — the native binary is named after its
    // version (2.1.302), and Claude Code's own grep (ugrep) runs as `claude` with any pattern.
    static func running() -> [Proc] { parse(run("/bin/ps", ["-axo", "pid=,tty=,args="])) }

    static func parse(_ ps: String) -> [Proc] {
        let argv0 = #"^(\S*/)?claude( |$)|^/.*/MacOS/claude( |$)|^(\S*/)?node \S*claude-code/cli\.js"#
        return ps.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 2)
            guard f.count == 3, let pid = Int32(f[0]) else { return nil }
            let args = f[2].trimmingCharacters(in: .whitespaces)
            guard args.range(of: argv0, options: .regularExpression) != nil else { return nil }
            return Proc(pid: pid, tty: String(f[1]), args: args)
        }
    }

    // ~/.claude/sessions/<pid>.json: Claude Code's own pid → session id (not every session has one).
    static func claimed() -> [Int32: String] {
        struct File: Decodable { let pid: Int32; let sessionId: String }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let all = files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(File.self, from: $0) } }
        return Dictionary(all.map { ($0.pid, $0.sessionId) }, uniquingKeysWith: { a, _ in a })
    }

    static func cwds(_ pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        var out: [Int32: String] = [:], pid: Int32 = 0
        for line in run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fpn", "-p", pids.map(String.init).joined(separator: ",")]).split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) ?? 0 }
            if line.hasPrefix("n") { out[pid] = Zentrale.normalize(String(line.dropFirst())) }
        }
        return out
    }

    // `ps -t <tty> -o ucomm=`: nothing but login and a shell left.
    static func onlyShell(_ ps: String) -> Bool {
        ps.split(separator: "\n").allSatisfy { ["login", "zsh", "-zsh", "bash", "-bash", "sh", "fish"].contains($0.trimmingCharacters(in: .whitespaces)) }
    }

    // The window of that tty, when it is its only tab (a window of several keeps its others).
    // Not Terminal (iTerm, tmux…): the shell simply stays.
    static func closeTerminal(tty: String) {
        let script = ["on run argv", #"if application "Terminal" is not running then return"#, #"tell application "Terminal""#,
                      "repeat with w in windows", "repeat with t in tabs of w", "if tty of t is (item 1 of argv) then",
                      "if (count of tabs of w) is 1 then", "with timeout of 10 seconds", "close w", "end timeout", "end if", "return", "end if", "end repeat", "end repeat",
                      "end tell", "end run"]
        _ = run("/usr/bin/osascript", script.flatMap { ["-e", $0] } + [tty])
    }

    private static func run(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

// Instructions waiting for a session in a folder (POST /dispatch, a routed wake to a Zentrale
// that is not running): handed over when a session there shows up, dropped after 10 min.
struct PendingInstructions {
    static let ttl: TimeInterval = 600

    // `forNew`: only a session that showed up after the dispatch takes it (a named dispatch
    // started a second session beside one already running in the folder).
    private struct Item { var text: String; var at: Date; var forNew: Bool }
    private var items: [String: [Item]] = [:]
    // The name such a dispatch gave its new session, until that session shows up.
    private var names: [String: [(name: String, at: Date)]] = [:]

    mutating func add(_ text: String, cwd: String, at: Date, forNew: Bool = false) {
        items[cwd, default: []].append(Item(text: text, at: at, forNew: forNew))
    }

    mutating func addName(_ name: String, cwd: String, at: Date) {
        names[cwd, default: []].append((name, at))
    }

    func has(cwd: String, now: Date) -> Bool {
        items[cwd]?.contains { now.timeIntervalSince($0.at) < Self.ttl } ?? false
    }

    /// What a session in `cwd` first seen at `firstSeen` may take, still fresh, oldest first,
    /// joined — and gone from the store. An instruction for a new session only goes to one that
    /// appeared after it was dispatched.
    mutating func take(cwd: String, now: Date, firstSeen: Date = .distantPast) -> String? {
        guard let list = items[cwd] else { return nil }
        let fresh = list.filter { now.timeIntervalSince($0.at) < Self.ttl }
        let mine = fresh.filter { !$0.forNew || firstSeen > $0.at }
        let rest = fresh.filter { $0.forNew && firstSeen <= $0.at }
        items[cwd] = rest.isEmpty ? nil : rest
        return mine.isEmpty ? nil : mine.map(\.text).joined(separator: "\n\n")
    }

    /// The name waiting for a new session in `cwd` (one that appeared after the dispatch).
    mutating func takeName(cwd: String, now: Date, firstSeen: Date) -> String? {
        guard var list = names[cwd] else { return nil }
        list.removeAll { now.timeIntervalSince($0.at) >= Self.ttl }
        guard let i = list.firstIndex(where: { firstSeen > $0.at }) else {
            names[cwd] = list.isEmpty ? nil : list
            return nil
        }
        let name = list.remove(at: i).name
        names[cwd] = list.isEmpty ? nil : list
        return name
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
        for (cwd, list) in names {
            let fresh = list.filter { now.timeIntervalSince($0.at) < Self.ttl }
            names[cwd] = fresh.isEmpty ? nil : fresh
        }
        return dropped.sorted()
    }
}
