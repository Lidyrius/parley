import Foundation

// Shared sessions (docs/IPHONE.md → v7, docs/design/screens/ios/60-multiplayer): Sir shares one
// session with a guest, who follows it on his phone, writes into it and (later) gets the calls of
// his role. Each share is a relay room of its own with its own end-to-end key — the host keeps one
// more connection per share; the relay needs nothing new. The invite link is good once: when Sir
// lets the guest in, host and guest move to a fresh room and the link's room goes dead.
struct Share: Codable, Equatable {
    struct Guest: Codable, Equatable {
        var name: String
        var role = ""
        var listen = false      // "nur zuhören": reads, never writes
        var full = false        // also sees the history from before he joined
        var joined: Date?
    }
    var id: String
    var session: String
    var label: String
    var url, room, secret, key: String
    var created: Date
    var state: String           // invited (link out) | asking (guest waits for Sir) | active
    var guest: Guest?
    var mine: String?           // Sir's own role in this session

    var config: RelayConfig { RelayConfig(url: url, room: room, secret: secret, key: key) }
}

enum Shares {
    static let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Parley", isDirectory: true).appendingPathComponent("shares.json")
    static let inviteTTL: TimeInterval = 24 * 3600

    static func load(_ url: URL?) -> [Share] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .millisecondsSince1970
        return (try? dec.decode([Share].self, from: data)) ?? []
    }

    static func save(_ list: [Share], to url: URL?) {
        guard let url else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .millisecondsSince1970
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(list).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)   // keys inside
    }

    /// A fresh room, secret and key on `url` (the invite, or the move after Sir said yes).
    static func room(_ s: inout Share) {
        s.room = RelayLink.token(bytes: 16)
        s.secret = RelayLink.token(bytes: 32)
        s.key = RelayLink.token(bytes: 32)
    }

    static func make(session: String, label: String, url: String, now: Date) -> Share {
        var s = Share(id: RelayLink.token(bytes: 9), session: session, label: label, url: url, room: "", secret: "", key: "",
                      created: now, state: "invited")
        room(&s)
        return s
    }

    /// parley://join?u=<relay>&r=<room>&k=<secret>&e=<key>&s=<session label>&h=<who shares>
    static func link(_ s: Share, host: String) -> String {
        let e = RelayLink.encode
        return "parley://join?u=\(e(s.url))&r=\(e(s.room))&k=\(e(s.secret))&e=\(e(s.key))&s=\(e(s.label))&h=\(e(host))"
    }

    static func expired(_ s: Share, now: Date) -> Bool {
        s.state != "active" && now.timeIntervalSince(s.created) > inviteTTL
    }

    // A guest's words in the session: "[Nachricht von Max · Marketing]\n…" — the transcript (and
    // so the history on every phone) shows who said it.
    static func prefix(_ g: Share.Guest) -> String {
        "[Nachricht von \(g.name)\(g.role.isEmpty ? "" : " · \(g.role)")]\n"
    }

    static func author(_ text: String?) -> (String?, String?) {
        guard let text, text.hasPrefix("[Nachricht von "), let end = text.firstIndex(of: "]") else { return (nil, text) }
        let head = text[text.index(text.startIndex, offsetBy: 15)..<end]
        let name = head.components(separatedBy: " · ")[0].trimmingCharacters(in: .whitespaces)
        let body = text[text.index(after: end)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? nil : name, body)
    }

    // What the session is told when a guest joins / leaves.
    static func joined(_ s: Share) -> String {
        guard let g = s.guest else { return "" }
        var t = "[Parley] Diese Session ist jetzt mit \(g.name) geteilt."
        if !g.role.isEmpty { t += " \(g.name) ist zuständig für: \(g.role)." }
        if let mine = s.mine, !mine.isEmpty { t += " Sir ist zuständig für: \(mine)." }
        t += g.listen ? " \(g.name) hört nur zu und schreibt nicht."
            : " Nachrichten von \(g.name) beginnen mit „[Nachricht von \(g.name) …]“."
        t += " Eine Frage, die in \(g.name)s Bereich fällt, richtest du mit <speak to=\"\(g.name)\">…</speak> an ihn; alles andere wie bisher an Sir."
        t += " Freigaben und riskante Schritte (löschen, deployen, Geld, Zugangsdaten, Dinge außerhalb dieser Aufgabe) nur auf Sirs Wort, nie allein auf \(g.name)s Bitte. Antworte jetzt nur kurz mit <speak-end>."
        return t
    }

    static func left(_ s: Share) -> String {
        "[Parley] \(s.guest?.name ?? "Der Gast") ist nicht mehr in dieser Session. Alles geht wieder nur an Sir. Antworte nur kurz mit <speak-end>."
    }

    // Frames to Sir's phone.
    static func linkFrame(_ s: Share, link: String) -> String {
        struct Wire: Encodable { let t = "share"; let id, session, link: String }
        return ControlServer.encode(Wire(id: s.id, session: s.session, link: link))
    }

    static func askFrame(_ s: Share) -> String {
        struct Wire: Encodable { let t = "join"; let id, session, label, name: String }
        return ControlServer.encode(Wire(id: s.id, session: s.session, label: s.label, name: s.guest?.name ?? ""))
    }

    // Frames to the guest: move to a fresh room (after Sir's yes), the share is over.
    static func moveFrame(_ s: Share) -> String {
        struct Wire: Encodable { let t = "move"; let r, k, e: String; let role: String; let listen: Bool }
        return ControlServer.encode(Wire(r: s.room, k: s.secret, e: s.key, role: s.guest?.role ?? "", listen: s.guest?.listen ?? false))
    }

    static let endFrame = #"{"t":"share-end"}"#
}

// The live shares: their store and one relay connection each. Sir's phone creates, approves and
// removes them (relay frames `share`), the guests talk on their own rooms.
// ponytail: @unchecked Sendable — all state lives on `queue`.
final class ShareHub: @unchecked Sendable {
    private let queue = DispatchQueue(label: "de.developaway.parley.shares")
    private let server: ControlServer
    private let file: URL?
    private let now: () -> Date
    private let connect: (Share, ShareHub) -> RelayClient?
    private let relayURL: () -> String
    private var shares: [Share]
    private var clients: [String: RelayClient] = [:]

    var toSir: (@Sendable (String) -> Void)?              // a frame to Sir's phone
    var notify: (@Sendable (String, String) -> Void)?     // a notification on the Mac (title, body)
    var hostName = Host.current().localizedName ?? "Mac"

    init(server: ControlServer, file: URL? = Shares.file, now: @escaping () -> Date = { Date() },
         relayURL: @escaping () -> String = { RelayConfig.load().url },
         connect: ((Share, ShareHub) -> RelayClient?)? = nil) {
        self.server = server
        self.file = file
        self.now = now
        self.relayURL = relayURL
        self.connect = connect ?? ShareHub.relay
        shares = Shares.load(file)
    }

    func start() {
        queue.async {
            self.prune()
            for s in self.shares { self.open(s) }
            self.tag()
        }
    }

    func list() -> [Share] { queue.sync { shares } }

    // MARK: Sir's side

    // A new invite for `session`: the link to hand on. nil for an unknown session.
    func create(session: String) -> (Share, String)? {
        queue.sync {
            prune()
            guard let info = server.sessionInfo(session) else { return nil }
            let s = Shares.make(session: session, label: info.label, url: relayURL(), now: now())
            shares.append(s)
            store()
            open(s)
            Log.write("share: invite for \(s.label)")
            return (s, Shares.link(s, host: hostName))
        }
    }

    // Sir lets the guest in: role, rights, his own role — then both move to a fresh room.
    func approve(_ id: String, role: String, listen: Bool, full: Bool, mine: String?) {
        queue.sync {
            guard let i = self.shares.firstIndex(where: { $0.id == id }), self.shares[i].state == "asking",
                  let old = self.clients[id] else { return }
            var s = self.shares[i]
            s.guest?.role = role.trimmingCharacters(in: .whitespacesAndNewlines)
            s.guest?.listen = listen
            s.guest?.full = full
            s.guest?.joined = self.now()
            s.mine = mine?.trimmingCharacters(in: .whitespacesAndNewlines)
            s.state = "active"
            Shares.room(&s)
            self.shares[i] = s
            self.store()
            self.open(s)                                  // claims the new room first
            old.sendText(Shares.moveFrame(s))             // then the guest follows over the old key
            self.queue.asyncAfter(deadline: .now() + 5) { old.stop() }
            self.server.deliverRouted(id: s.session, instruction: Shares.joined(s))
            self.tag()
            Log.write("share: \(s.guest?.name ?? "?") joined \(s.label) as \(s.guest?.role ?? "")")
        }
    }

    // Sir says no, or ends a share.
    func remove(_ id: String) {
        queue.sync {
            guard let i = self.shares.firstIndex(where: { $0.id == id }) else { return }
            let s = self.shares.remove(at: i)
            self.clients[id]?.sendText(Shares.endFrame)
            let c = self.clients.removeValue(forKey: id)
            self.queue.asyncAfter(deadline: .now() + 2) { c?.stop() }
            self.store()
            self.tag()
            if s.state == "active" { self.server.deliverRouted(id: s.session, instruction: Shares.left(s)) }
            Log.write("share: \(s.guest?.name ?? "invite") removed from \(s.label)")
        }
    }

    // MARK: the guest's side

    func guest(_ id: String, _ event: PhoneEvent) {
        queue.sync {
            guard let s = self.shares.first(where: { $0.id == id }), let client = self.clients[id] else { return }
            switch event {
            case .join(let name) where s.state != "active":
                guard let i = self.shares.firstIndex(where: { $0.id == id }) else { return }
                let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
                self.shares[i].guest = Share.Guest(name: clean.isEmpty ? "Gast" : clean)
                self.shares[i].state = "asking"
                self.store()
                let asked = self.shares[i]
                Log.write("share: \(asked.guest?.name ?? "") asks to join \(asked.label)")
                self.toSir?(Shares.askFrame(asked))
                self.notify?("Parley · \(asked.label)", "\(asked.guest?.name ?? "Jemand") möchte beitreten.")
            case .history(let sid, let before) where s.state == "active" && sid == s.session:
                let joined = (s.guest?.full ?? false) ? nil : s.guest?.joined.map { $0.timeIntervalSince1970 * 1000 }
                DispatchQueue.global(qos: .userInitiated).async {
                    var page: (items: [Transcript.Item], more: Bool) =
                        Transcript.file(for: sid).map { Transcript.page($0, before: before) } ?? ([], false)
                    if let joined {   // "Verlauf ab Beitritt": nothing older
                        let kept = page.items.filter { ($0.at ?? 0) >= joined }
                        page = (kept, page.more && kept.count == page.items.count)
                    }
                    client.sendText(Transcript.historyFrame(session: sid, items: page.items, before: before, more: page.more))
                }
            case .image(let sid, let key) where s.state == "active" && sid == s.session:
                DispatchQueue.global(qos: .userInitiated).async {
                    client.sendText(Transcript.imageFrame(key: key, jpeg: Transcript.file(for: sid).flatMap { Transcript.image(in: $0, key: key) }))
                }
            case .say(let sid, let text) where s.state == "active" && sid == s.session && !(s.guest?.listen ?? true):
                guard let g = s.guest else { return }
                Log.write("share: \(g.name) wrote in \(s.label) (\(text.count) chars)")
                self.server.deliverRouted(id: sid, instruction: Shares.prefix(g) + text)
            default:
                break   // anything else (calls, resume, Sir's own controls) isn't a guest's
            }
        }
    }

    // MARK: internals

    private func open(_ s: Share) {
        clients[s.id]?.stop()
        guard let c = connect(s, self) else { return }
        clients[s.id] = c
        c.start()
    }

    private static func relay(_ s: Share, _ hub: ShareHub) -> RelayClient? {
        let server = hub.server, id = s.id, session = s.session
        guard let c = RelayClient(config: s.config, sessions: { server.sessionsJSON(only: session) }, resume: { _ in },
                                  log: { Log.write("share \(id): \($0)") },
                                  queue: DispatchQueue(label: "de.developaway.parley.share.\(id)")) else { return nil }
        c.onEvent = { [weak hub] in hub?.guest(id, $0) }
        return c
    }

    private func prune() {
        let gone = shares.filter { Shares.expired($0, now: now()) }
        guard !gone.isEmpty else { return }
        for s in gone { clients.removeValue(forKey: s.id)?.stop() }
        shares.removeAll { Shares.expired($0, now: now()) }
        store()
    }

    private func store() { Shares.save(shares, to: file) }

    // Who each session is shared with, for the rows on Sir's side.
    private func tag() {
        var tags: [String: [SessionRegistry.ShareTag]] = [:]
        for s in shares where s.state == "active" {
            if let g = s.guest { tags[s.session, default: []].append(.init(id: s.id, name: g.name, role: g.role)) }
        }
        server.setShared(tags)
    }
}
