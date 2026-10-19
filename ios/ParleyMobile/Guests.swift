import Foundation

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
}

extension AppModel {
    // MARK: the guest's side

    func startGuests() {
        guests = PairingStore.loadGuests()
        for g in guests { connect(g) }
    }

    /// "Beitreten": keep the share, dial its room, say who I am.
    func join(_ link: JoinLink, as name: String) {
        let g = GuestShare(pairing: link.pairing, label: link.label, host: link.host,
                           name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        guests.removeAll { $0.pairing.room == g.pairing.room }
        guests.append(g)
        PairingStore.saveGuests(guests)
        pendingJoin = nil
        connect(g)
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
            if !guests[i].active { guestRelays[id]?.send(Outgoing.join(name: guests[i].name)) }
        case .frame(.shareMove(let m)):
            // Let in: the fresh room — the invite's room is dead from here on.
            guard let moved = try? Pairing.parse(Self.pairLink(guests[i].pairing.relay, m)) else { return }
            guests[i].pairing = moved
            guests[i].role = m.role ?? ""
            guests[i].listen = m.listen ?? false
            guests[i].active = true
            PairingStore.saveGuests(guests)
            guestRelays[id]?.use(moved)
            guestRelays[id]?.reconnect()
        case .frame(.shareEnd):
            guestNotice = "\(guests[i].host.isEmpty ? "Die Freigabe" : guests[i].host + " hat die Freigabe") für „\(guests[i].label)“ beendet."
            leave(id)
        case .frame(.history), .frame(.image):
            handle(event)   // the same history store as the own sessions (ids don't collide)
        default:
            break           // calls, rings and the owner's controls aren't a guest's
        }
    }

    private static func pairLink(_ relay: URL, _ m: ShareMove) -> String {
        var c = URLComponents()
        c.scheme = "parley"
        c.host = "pair"
        c.queryItems = [.init(name: "u", value: relay.absoluteString), .init(name: "r", value: m.r),
                        .init(name: "k", value: m.k), .init(name: "e", value: m.e)]
        return c.string ?? ""
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
        relay.send(Outgoing.shareApprove(id: r.id, role: role, listen: listen, full: full, mine: mine))
    }

    /// Say no to a guest who asks, or remove one who is in.
    func removeShare(_ id: String) {
        joinRequests.removeAll { $0.id == id }
        relay.send(Outgoing.shareRemove(id: id))
    }
}
