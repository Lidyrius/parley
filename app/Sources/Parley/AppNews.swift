import Foundation

// Protocol v13 (docs/IPHONE.md): the phone says its build in `hello`; the newest TestFlight build
// and what each build brought come from ios/whats-new.json on main. Sir hears once per build, at
// the start of a call, what is new in his app — or that a newer one is waiting. 1:1 with Windows.
// ponytail: @unchecked Sendable — every field is behind `lock`.
final class AppNews: @unchecked Sendable {
    static let url = URL(string: "https://raw.githubusercontent.com/Lidyrius/parley/main/ios/whats-new.json")!
    static let stateFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Parley", isDirectory: true).appendingPathComponent("news.json")
    static let shared = AppNews()

    struct Build: Equatable { let number: Int; let text: String }

    private let lock = NSLock()
    private var phone: Int?
    private var latest = 0
    private var builds: [Build] = []
    private var fetched = Date.distantPast

    /// whats-new.json → (latest, builds newest first). Pure.
    static func parse(_ data: Data) -> (latest: Int, builds: [Build])? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let builds = ((obj["builds"] as? [[String: Any]]) ?? []).compactMap { b -> Build? in
            guard let n = b["build"] as? Int, let t = b["text"] as? String, !t.isEmpty else { return nil }
            return Build(number: n, text: t)
        }.sorted { $0.number > $1.number }
        return ((obj["latest"] as? Int) ?? builds.first?.number ?? 0, builds)
    }

    /// hello: remember the build, refresh the notes (at most every 6 h).
    func onHello(build: Int?) {
        guard let build else { return }
        lock.lock(); phone = build
        let stale = Date().timeIntervalSince(fetched) > 6 * 3600
        if stale { fetched = Date() }
        lock.unlock()
        guard stale else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: Self.url), let parsed = Self.parse(data) else {
                Log.write("news: not fetched"); return
            }
            lock.withLock { latest = parsed.latest; builds = parsed.builds }
        }
    }

    struct Wire: Encodable, Equatable {
        struct Item: Encodable, Equatable { let build: Int; let text: String }
        let latest: Int; let news: [Item]
    }

    /// For /sessions: {latest, news} while the phone is behind, else nil (omitted).
    func wire() -> Wire? {
        lock.withLock {
            guard let phone, latest > phone else { return nil }
            return Wire(latest: latest, news: builds.filter { $0.number > phone }.prefix(5).map { .init(build: $0.number, text: $0.text) })
        }
    }

    /// The line before the first update of a call, or nil — plus what is remembered after. Pure.
    static func next(phone: Int, latest: Int, builds: [Build], told: Int?, offered: Int) -> (line: String?, told: Int, offered: Int) {
        let since = told ?? phone - 1   // never told: what this build brought, once
        if phone > since {
            let news = builds.filter { $0.number > since && $0.number <= phone }.prefix(3).map(\.text)
            if news.isEmpty { return (nil, phone, offered) }
            return ("Kurz vorweg, Sir: Ihre App ist aktualisiert. Neu: \(news.joined(separator: " "))", phone, max(offered, phone))
        }
        if latest > phone, latest > offered {
            let news = builds.filter { $0.number > phone && $0.number <= latest }.prefix(3).map(\.text)
            let tail = news.isEmpty ? "" : " Neu darin: " + news.joined(separator: " ")
            return ("Kurz vorweg, Sir: In TestFlight wartet eine neue Version Ihrer App.\(tail)", phone, latest)
        }
        return (nil, since, offered)
    }

    /// Call start: the line to speak once (and remember it was said), or nil.
    func takeLine(language: String) -> String? {
        guard language == "Deutsch" else { return nil }   // ponytail: notes are German only
        let snap: (Int, Int, [Build])? = lock.withLock {
            guard let phone, !builds.isEmpty else { return nil }
            return (phone, latest, builds)
        }
        guard let (phone, latest, builds) = snap else { return nil }
        let state = (try? Data(contentsOf: Self.stateFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let told = state["told"] as? Int, offered = state["offered"] as? Int ?? 0
        let r = Self.next(phone: phone, latest: latest, builds: builds, told: told, offered: offered)
        if r.told != told || r.offered != offered,
           let data = try? JSONSerialization.data(withJSONObject: ["told": r.told, "offered": r.offered]) {
            try? FileManager.default.createDirectory(at: Self.stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.stateFile)
        }
        if r.line != nil { Log.write("news: telling Sir (phone \(phone), latest \(latest))") }
        return r.line
    }
}
