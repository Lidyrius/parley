import CryptoKit
import Foundation

// Protocol v10 (docs/IPHONE.md): Hinweise — something needs Sir outside any session (typically a
// lost login in a browser on a server). The host reads a plain text file every 30 s (the
// Wachhund's tick), lists its lines as `alerts` in /sessions, pushes a line it hasn't seen
// before, and runs `alertsCheck` when the phone asks. The desktops (`vnc`) to fix it are in
// Desktops.swift. 1:1 with Hints on Windows/Linux.

// One desktop of the host's `vnc` config.
struct HostDesktop: Equatable, Sendable {
    let url: String        // ws://…/websockify or tcp://host:port
    let password: String   // VNC password, handed to the phone on open
}

// credentials.json: `alertsFile`, `alertsCheck` (strings), `vnc` ({name: {url, password}}). All off by default.
struct HintsConfig: Equatable, Sendable {
    var alertsFile = ""
    var alertsCheck = ""
    var vnc: [String: HostDesktop] = [:]

    static func load() -> HintsConfig { from(Keychain.raw) }

    static func from(_ value: (String) -> Any?) -> HintsConfig {
        var c = HintsConfig()
        c.alertsFile = (value("alertsFile") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        c.alertsCheck = (value("alertsCheck") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        for (name, entry) in value("vnc") as? [String: Any] ?? [:] {
            guard !name.isEmpty, let e = entry as? [String: Any], let url = e["url"] as? String, !url.isEmpty else { continue }
            c.vnc[name] = HostDesktop(url: url, password: e["password"] as? String ?? "")
        }
        return c
    }

    var desktops: [String] { vnc.keys.sorted() }
}

enum Hints {
    struct Line: Equatable, Sendable {
        let id, text: String
        let desktop: String?
    }

    // As /sessions lists them; `desktop` omitted when the line names none.
    struct Alert: Encodable, Equatable, Sendable {
        let id, text: String
        let since: Int64
        let desktop: String?
    }

    /// The first 16 hex chars of sha256(line).
    static func id(_ line: String) -> String {
        SHA256.hash(data: Data(line.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// One alert per non-empty line (trimmed): `[<desktop>] <text>` or just `<text>`. The same
    /// line twice is one alert.
    static func parse(_ content: String) -> [Line] {
        var seen = Set<String>()
        var out: [Line] = []
        for raw in content.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let id = id(line)
            guard seen.insert(id).inserted else { continue }
            var text = line
            var desktop: String?
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                // = ^\[([^\]\s]+)\]\s*(.*)$ on Windows: a name without blanks, then the text.
                let name = String(line[line.index(after: line.startIndex)..<close])
                let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !name.contains(where: \.isWhitespace), !rest.isEmpty { desktop = name; text = rest }
            }
            out.append(Line(id: id, text: text, desktop: desktop))
        }
        return out
    }

    /// The alerts now. `seen` keeps when each line was first seen (epoch ms); a line that is gone
    /// is forgotten, so it pushes again when it comes back. `new` = the lines to push.
    static func update(_ seen: inout [String: Int64], _ lines: [Line], now: Int64) -> (alerts: [Alert], new: [Line]) {
        var next: [String: Int64] = [:]
        var new: [Line] = []
        let alerts = lines.map { l -> Alert in
            let since = seen[l.id] ?? now
            if seen[l.id] == nil { new.append(l) }
            next[l.id] = since
            return Alert(id: l.id, text: l.text, since: since, desktop: l.desktop)
        }
        seen = next
        return (alerts, new)
    }
}

// The app's side: read on the tick, push what is new, run the check. On the main actor.
@MainActor
final class HintsWatch {
    static let checkLimit: TimeInterval = 10 * 60   // a check that hangs is ended after this

    private var seen: [String: Int64] = [:]
    private var checking: Process?
    // → /sessions (alerts, alertsChecking, desktops)
    private let publish: (_ alerts: [Hints.Alert], _ checking: Bool, _ desktops: [String]) -> Void
    private let push: (_ text: String) -> Void      // one alert push
    private let refreshed: () -> Void               // a fresh `sessions` frame now

    init(publish: @escaping (_ alerts: [Hints.Alert], _ checking: Bool, _ desktops: [String]) -> Void,
         push: @escaping (_ text: String) -> Void, refreshed: @escaping () -> Void) {
        self.publish = publish
        self.push = push
        self.refreshed = refreshed
    }

    // Every 30 s (and at launch, and after a check).
    func tick() {
        let c = HintsConfig.load()
        var alerts: [Hints.Alert] = []
        if c.alertsFile.isEmpty {
            seen = [:]
        } else {
            let path = (c.alertsFile as NSString).expandingTildeInPath
            var content = ""
            if FileManager.default.fileExists(atPath: path) {
                guard let c = try? String(contentsOfFile: path, encoding: .utf8) else { return }   // being rewritten: next tick
                content = c
            }
            let (now, new) = Hints.update(&seen, Hints.parse(content), now: Int64((Date().timeIntervalSince1970 * 1000).rounded()))
            alerts = now
            for l in new {
                Log.write("hint: \(l.desktop.map { "[\($0)] " } ?? "")\(l.text)")
                push(l.text)
            }
        }
        publish(alerts, checking != nil, c.desktops)
    }

    // The phone's "check again": `alertsCheck` via /bin/sh, one at a time, in the background.
    func check() {
        guard checking == nil else { return }
        let cmd = HintsConfig.load().alertsCheck
        guard !cmd.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in self?.checked(status) }
        }
        do { try p.run() } catch {
            Log.write("hint: check failed to start (\(error.localizedDescription))")
            return
        }
        Log.write("hint: check started")
        checking = p
        tick()
        refreshed()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.checkLimit))
            guard let self, self.checking === p, p.isRunning else { return }
            Log.write("hint: check still runs after \(Int(Self.checkLimit / 60)) min — ended")
            p.terminate()
        }
    }

    private func checked(_ status: Int32) {
        Log.write("hint: check ended (\(status))")
        checking = nil
        tick()
        refreshed()
    }
}
