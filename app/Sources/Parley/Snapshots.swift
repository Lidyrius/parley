import Foundation

// Snapshots (the phone's "Snapshots", the menu): a named set of sessions — each one's name,
// session id and folder — that Sir opens again in one go. Opening leaves a session that still
// runs alone, resumes one whose transcript is still there (`claude --resume`), else starts a new
// one in its folder under the same name. Kept in snapshots.json; the list rides along in /sessions.
struct Snapshot: Codable, Equatable {
    struct Item: Codable, Equatable {
        var id: String
        var name: String
        var cwd: String
    }
    var id: String
    var name: String
    var at: Date
    var sessions: [Item]
}

enum Snapshots {
    static let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Parley", isDirectory: true).appendingPathComponent("snapshots.json")

    static func load(_ url: URL?) -> [Snapshot] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .millisecondsSince1970
        return (try? dec.decode([Snapshot].self, from: data)) ?? []
    }

    static func save(_ list: [Snapshot], to url: URL?) {
        guard let url else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .millisecondsSince1970
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(list).write(to: url, options: .atomic)
    }

    // As /sessions lists them: newest first, `at` in epoch ms.
    struct Row: Encodable, Equatable {
        let id, name: String
        let at: Int64
        let sessions: [Snapshot.Item]
    }

    static func rows(_ list: [Snapshot]) -> [Row] {
        list.sorted { $0.at > $1.at }
            .map { Row(id: $0.id, name: $0.name, at: Int64(($0.at.timeIntervalSince1970 * 1000).rounded()), sessions: $0.sessions) }
    }

    /// What opening did to one session: "running" (left alone, or its start is on the way),
    /// "resumed", "started" (a new one, same name), "missing" (its folder is gone).
    struct Outcome: Encodable, Equatable {
        let id, name, result: String
    }

    /// The phone's answer to `{"t":"snapshot","op":"open"}`.
    static func frame(_ s: Snapshot, _ outcomes: [Outcome]) -> String {
        struct Wire: Encodable { let t = "snapshot"; let id, name: String; let results: [Outcome] }
        return ControlServer.encode(Wire(id: s.id, name: s.name, results: outcomes))
    }
}

extension ControlServer {
    // Off the queue (the phone, the menu).
    func saveSnapshot(name: String, ids: [String]? = nil) -> Snapshot? { queue.sync { saveSnapshotOnQueue(name: name, ids: ids) } }
    func openSnapshot(_ id: String) -> (Snapshot, [Snapshots.Outcome])? { queue.sync { openSnapshotOnQueue(id) } }
    func deleteSnapshot(_ id: String) -> Bool { queue.sync { deleteSnapshotOnQueue(id) } }
    func snapshotList() -> [Snapshot] { queue.sync { snapshots.sorted { $0.at > $1.at } } }

    // The sessions running now (or just `ids`) under `name`; the same name again replaces it.
    func saveSnapshotOnQueue(name raw: String, ids: [String]?) -> Snapshot? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60).description
        let items = (ids.map { $0.compactMap { id in sessions.info(id).map { (id, $0.label, $0.cwd) } } } ?? sessions.live())
            .filter { !$0.2.isEmpty }
            .map { Snapshot.Item(id: $0.0, name: $0.1, cwd: $0.2) }
        guard !name.isEmpty, !items.isEmpty else { return nil }
        let s = Snapshot(id: UUID().uuidString.lowercased(), name: name, at: now(), sessions: items)
        snapshots.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        snapshots.append(s)
        storeSnapshots()
        Log.write("snapshot: saved \(name) — \(items.map(\.name).joined(separator: ", "))")
        return s
    }

    func openSnapshotOnQueue(_ id: String) -> (Snapshot, [Snapshots.Outcome])? {
        guard let s = snapshots.first(where: { $0.id == id }) else { return nil }
        let outcomes = s.sessions.map { item -> Snapshots.Outcome in
            func done(_ r: String) -> Snapshots.Outcome { Snapshots.Outcome(id: item.id, name: item.name, result: r) }
            if sessions.alive(item.id) != nil { return done("running") }
            guard Zentrale.isDirectory(item.cwd) else { return done("missing") }
            let resume = Transcript.isSessionID(item.id) && Transcript.file(for: item.id, root: transcripts) != nil ? item.id : nil
            let r = dispatchOnQueue(cwd: item.cwd, instruction: "", start: true, resume: resume, name: item.name)
            return done(!r.started ? "running" : resume != nil ? "resumed" : "started")
        }
        Log.write("snapshot: opened \(s.name) — \(outcomes.map { "\($0.name) \($0.result)" }.joined(separator: ", "))")
        return (s, outcomes)
    }

    func deleteSnapshotOnQueue(_ id: String) -> Bool {
        guard let i = snapshots.firstIndex(where: { $0.id == id }) else { return false }
        Log.write("snapshot: deleted \(snapshots.remove(at: i).name)")
        storeSnapshots()
        return true
    }

    func storeSnapshots() {
        Snapshots.save(snapshots, to: snapshotsFile)
        sessions.snapshots = Snapshots.rows(snapshots)
    }

    // GET/POST /snapshots…
    func snapshotRoute(_ method: String, _ path: String, _ body: Data) -> (Int, String) {
        struct Req: Decodable { var id: String?; var name: String?; var ids: [String]? }
        let r = try? JSONDecoder().decode(Req.self, from: body)
        switch (method, path) {
        case ("GET", "/snapshots"):
            return (200, Self.encode(["snapshots": Snapshots.rows(snapshots)]))
        case ("POST", "/snapshots"):
            guard let s = saveSnapshotOnQueue(name: r?.name ?? "", ids: r?.ids) else {
                return (400, #"{"ok":false,"error":"give a name; no running session to keep"}"#)
            }
            struct Wire: Encodable { let ok = true; let snapshot: Snapshots.Row }
            return (200, Self.encode(Wire(snapshot: Snapshots.rows([s])[0])))
        case ("POST", "/snapshots/open"):
            guard let (s, outcomes) = openSnapshotOnQueue(r?.id ?? "") else { return (404, #"{"ok":false,"error":"unknown snapshot"}"#) }
            struct Wire: Encodable { let ok = true; let name: String; let results: [Snapshots.Outcome] }
            return (200, Self.encode(Wire(name: s.name, results: outcomes)))
        case ("POST", "/snapshots/delete"):
            return deleteSnapshotOnQueue(r?.id ?? "") ? (200, #"{"ok":true}"#) : (404, #"{"ok":false,"error":"unknown snapshot"}"#)
        default:
            return (404, #"{"ok":false,"error":"not found"}"#)
        }
    }
}
