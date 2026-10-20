import CryptoKit
import Foundation
import UIKit
import UserNotifications

/// v7 (docs/IPHONE.md, docs/design/screens/ios/60-multiplayer): someone else's session this phone
/// joined. Its own room and key — a second relay connection beside (or without) the own Mac's.
struct GuestShare: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var pairing: Pairing
    var label: String               // the session's name
    var host: String                // who shares it
    var name: String                // how this phone's owner introduced himself
    var role = ""
    var listen = false              // "nur zuhören"
    var active = false              // let in (false: waits for the owner's yes)
    var share = ""                  // the share's id on the owner's Mac (once let in)
    /// This phone's key for this share (P-256, raw, base64): the move to the fresh room is sealed to it.
    var secret = P256.KeyAgreement.PrivateKey().rawRepresentation.base64EncodedString()

    var key: P256.KeyAgreement.PrivateKey? { Data(base64Encoded: secret).flatMap { try? .init(rawRepresentation: $0) } }
    var pub: String { key.map { Self.base64url($0.publicKey.x963Representation) } ?? "" }
    /// The four digits the owner sees in the request — the same on both sides (Shares.code on the Mac).
    var code: String { Self.code(pub) }

    static func code(_ pub: String) -> String {
        let d = SHA256.hash(data: Data(pub.utf8))
        return String(format: "%04u", d.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 10_000)
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The fresh room from a `move`: opened with this phone's key — nil if it wasn't sealed to it.
    func open(_ m: ShareMove) -> (room: String, secret: String, key: String)? {
        func data(_ s: String) -> Data? {
            var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            return Data(base64Encoded: b)
        }
        guard let mine = key, let raw = data(m.pub), let theirs = try? P256.KeyAgreement.PublicKey(x963Representation: raw),
              let shared = try? mine.sharedSecretFromKeyAgreement(with: theirs), let sealed = data(m.box),
              let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        let k = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(m.share.utf8),
                                               sharedInfo: Data("parley-share-move".utf8), outputByteCount: 32)
        struct Room: Decodable { let r, k, e: String }
        guard let plain = try? AES.GCM.open(box, using: k), let room = try? JSONDecoder().decode(Room.self, from: plain) else { return nil }
        return (room.r, room.k, room.e)
    }
}

extension AppModel {
    // MARK: the guest's side

    func startGuests() {
        guests = PairingStore.loadGuests()
        for g in guests { connect(g) }
    }

    /// This phone, the same on every join: the owner's phone knows a guest again by it.
    static var guestWho: String {
        if let id = UserDefaults.standard.string(forKey: "guestWho") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "guestWho")
        return id
    }

    /// "Beitreten": keep the share, dial its room, say who I am. The share's id (its code screen follows it).
    @discardableResult func join(_ link: JoinLink, as name: String) -> String {
        let g = GuestShare(pairing: link.pairing, label: link.label, host: link.host,
                           name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        guests.removeAll { $0.pairing.room == g.pairing.room }
        guests.append(g)
        PairingStore.saveGuests(guests)
        if !demo { connect(g) }
        return g.id
    }

    /// Leave a share (or give up waiting): the owner's Mac ends it when told; the room just goes quiet.
    func leave(_ id: String) {
        guestRelays.removeValue(forKey: id)?.forget()
        guests.removeAll { $0.id == id }
        PairingStore.saveGuests(guests)
    }

    /// The relay that carries session `id`: a share's, else the own Mac's.
    func relay(for id: String) -> Relay {
        for g in guests {
            if let r = guestRelays[g.id], r.snapshot?.sessions.contains(where: { $0.id == id }) == true { return r }
        }
        return relay
    }

    /// The relay of the share the owner's Mac calls `share` (a guest's VoIP push names it).
    func guestRelay(share: String) -> Relay? {
        guests.first { $0.share == share }.flatMap { guestRelays[$0.id] }
    }

    /// The share a session belongs to, if it is someone else's.
    func guestShare(of id: String) -> GuestShare? {
        guests.first { g in guestRelays[g.id]?.snapshot?.sessions.contains { $0.id == id } == true }
    }

    private func connect(_ g: GuestShare) {
        let r = guestRelays[g.id] ?? Relay()
        guestRelays[g.id] = r
        r.onEvent = { [weak self] in self?.guestEvent(g.id, $0) }
        r.use(g.pairing)
        r.reconnect()
    }

    private func guestEvent(_ id: String, _ event: RelayEvent) {
        guard let i = guests.firstIndex(where: { $0.id == id }) else { return }
        switch event {
        case .opened:
            guard let r = guestRelays[id] else { return }
            if guests[i].active { sendPushTokens(on: r) }   // so his questions ring / reach him as a push
            else { r.send(Outgoing.join(name: guests[i].name, device: UIDevice.current.name, pub: guests[i].pub, who: Self.guestWho)) }
            if call.line === r {
                if call.phase.isActive { r.send(Outgoing.call(started: true)) }
                call.relayChanged()
            }
        case .closed, .frame(.peer):
            if let r = guestRelays[id], call.line === r { call.relayChanged() }
        // Part 3: a call on his own line — the owner's Mac rings him for a question.
        case .audio(let frame):
            if let r = guestRelays[id], call.line === r { call.play(frame) }
        case .frame(.audio(let state, let label)):
            if let r = guestRelays[id], call.line === r { call.hostAudioChanged(state, label: label) }
        case .frame(.caption(let c)):
            if let r = guestRelays[id], call.line === r { call.captionReceived(c) }
        case .frame(.slides(let s)):
            if let r = guestRelays[id], call.line === r { call.slidesReceived(s) }
        case .frame(.ring(let label)):
            // In the foreground (in the background the VoIP push rings instead).
            if let r = guestRelays[id], isForeground, call.phase == .none {
                call.use(line: r)
                call.reportIncoming(label: label)
            }
        case .frame(.shareMove(let m)):
            // Let in: the fresh room, sealed to this phone's key — the invite's room is dead from here on.
            guard !guests[i].active, let room = guests[i].open(m),
                  let moved = try? Pairing.parse(Self.pairLink(guests[i].pairing.relay, room)) else { return }
            guests[i].pairing = moved
            guests[i].share = m.share
            guests[i].role = m.role ?? ""
            guests[i].listen = m.listen ?? false
            guests[i].active = true
            PairingStore.saveGuests(guests)
            guestRelays[id]?.use(moved)
            guestRelays[id]?.reconnect()
            Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        case .frame(.shareEnd):
            guestNotice = "\(guests[i].host.isEmpty ? "Die Freigabe" : guests[i].host + " hat die Freigabe") für „\(guests[i].label)“ beendet."
            leave(id)
        case .frame(.notice(let text)):
            guestNotice = text
        case .frame(.ask(let a)):
            guestAsks.removeAll { $0.id == a.id }
            guestAsks.append(a)
        case .frame(.askEnd(let qid)):
            guestAsks.removeAll { $0.id == qid }
        case .frame(.history), .frame(.image):
            handle(event)   // the same history store as the own sessions (ids don't collide)
        default:
            break           // calls, rings and the owner's controls aren't a guest's
        }
    }

    private static func pairLink(_ relay: URL, _ room: (room: String, secret: String, key: String)) -> String {
        var c = URLComponents()
        c.scheme = "parley"
        c.host = "pair"
        c.queryItems = [.init(name: "u", value: relay.absoluteString), .init(name: "r", value: room.room),
                        .init(name: "k", value: room.secret), .init(name: "e", value: room.key)]
        return c.string ?? ""
    }

    /// The guest answers (text, a predicted answer, dictation) or gives the question to the owner.
    func answer(_ a: GuestAsk, text: String, pass: Bool = false) {
        guestAsks.removeAll { $0.id == a.id }
        relay(for: a.session).send(Outgoing.answer(id: a.id, text: text, pass: pass))
    }

    // MARK: the owner's side

    /// "Teilen": ask the Mac for a one-time link (it arrives as `shareLinks[session]`).
    func share(_ session: String) {
        shareLinks[session] = nil
        if demo {   // a link to look at, nothing behind it
            shareLinks[session] = "parley://join?u=https%3A%2F%2Frelay.example&r=demo-room&k=demo&e=demo&s=Website&h=Sydney"
            return
        }
        relay.send(Outgoing.shareCreate(session: session))
    }

    func approve(_ r: JoinRequest, role: String, listen: Bool, full: Bool, mine: String) {
        joinRequests.removeAll { $0.id == r.id }
        PastRoles.remember(role, for: r)
        relay.send(Outgoing.shareApprove(id: r.id, role: role, listen: listen, full: full, mine: mine))
    }

    /// Say no to a guest who asks, or remove one who is in.
    func removeShare(_ id: String) {
        joinRequests.removeAll { $0.id == id }
        relay.send(Outgoing.shareRemove(id: id))
    }
}

/// The roles Sir gave a guest before (on this phone), newest first: offered when he asks again.
enum PastRoles {
    static func key(_ r: JoinRequest) -> String {
        if let who = r.who, !who.isEmpty { return who }
        return "name:" + r.name.lowercased()
    }

    static func roles(for r: JoinRequest) -> [String] {
        (UserDefaults.standard.dictionary(forKey: "pastRoles") as? [String: [String]])?[key(r)] ?? []
    }

    static func remember(_ role: String, for r: JoinRequest) {
        let role = role.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !role.isEmpty else { return }
        var all = UserDefaults.standard.dictionary(forKey: "pastRoles") as? [String: [String]] ?? [:]
        all[key(r)] = Array(([role] + (all[key(r)] ?? []).filter { $0 != role }).prefix(6))
        UserDefaults.standard.set(all, forKey: "pastRoles")
    }

    /// The first four digits in a row in `text` ("Mein Parley-Code für „Shirts“: 4821" → "4821").
    static func code(in text: String) -> String? {
        text.firstMatch(of: /\d{4}/).map { String($0.output) }
    }
}
