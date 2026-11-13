import Foundation
import Testing
@testable import ParleyMobile

/// Several hosts (docs/IPHONE.md → Several hosts): the list, its Keychain item and the link's name.
struct HostTests {
    let secret = "s3cr3t-_s3cr3t-_s3cr3t-_s3cr3t-_s3cr3t-_abc"

    func link(room: String = "AbCdEfGhIjKlMnOpQrStUv", more: String = "") -> String {
        "parley://pair?u=https%3A%2F%2Frelay.example.com&r=\(room)&k=\(secret)\(more)"
    }

    func pairing(_ room: String) throws -> Pairing { try Pairing.parse(link(room: room)) }

    // MARK: the link's name (`h`)

    @Test func theLinkNamesItsHost() throws {
        #expect(Pairing.hostName(in: link(more: "&h=Server")) == "Server")
        #expect(Pairing.hostName(in: link(more: "&h=Sydneys%20MacBook%20Pro")) == "Sydneys MacBook Pro")
        #expect(Pairing.hostName(in: link(more: "&h=B%C3%BCro-PC")) == "Büro-PC")
        #expect(Pairing.hostName(in: "parley://pair?h=Server&u=https%3A%2F%2Frelay.example.com&r=AbCdEfGhIjKlMnOpQrStUv&k=\(secret)") == "Server")
        // The relay's page URL carries the link — and so the name — in its fragment.
        let inner = link(more: "&h=Server").addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(Pairing.hostName(in: "https://relay.example.com/pair#" + inner) == "Server")
    }

    @Test func aLinkWithoutANameHasNone() {
        #expect(Pairing.hostName(in: link()) == nil)                 // an older host
        #expect(Pairing.hostName(in: link(more: "&h=")) == nil)
        #expect(Pairing.hostName(in: link(more: "&h=%20%20")) == nil)
        #expect(Pairing.hostName(in: "hello world") == nil)
        #expect(Pairing.hostName(in: "parley://join?h=Sydney") == nil)   // an invite's `h` is who shares
    }

    @Test func aLongNameIsCutAndThePairingStaysTheSame() throws {
        let long = String(repeating: "x", count: 90)
        #expect(Pairing.hostName(in: link(more: "&h=" + long))?.count == 40)
        #expect(try Pairing.parse(link(more: "&h=Server")) == Pairing.parse(link()))   // `h` is no part of the pairing
    }

    // MARK: the list

    @Test func theFirstHostIsMacAndFurtherOnesAreNumbered() throws {
        var list = HostList()
        #expect(list.active == nil)
        let mac = list.add(try pairing("room-aaaaaaaaaaaaaaaa"), name: nil)
        #expect(mac.name == "Mac" && list.active == mac)
        let second = list.add(try pairing("room-bbbbbbbbbbbbbbbb"), name: nil)
        #expect(second.name == "Host 2")
        let named = list.add(try pairing("room-cccccccccccccccc"), name: "  Server ")
        #expect(named.name == "Server")
        #expect(list.hosts.map(\.name) == ["Mac", "Host 2", "Server"])
        #expect(list.active == named)                                 // the one just added
        #expect(Set(list.hosts.map(\.id)).count == 3)
        // "Host 2" is taken: the next unnamed one doesn't get it again.
        list.remove(mac.id)
        #expect(list.add(try pairing("room-dddddddddddddddd"), name: nil).name == "Host 3")
    }

    @Test func aHostPairedAgainKeepsItsPlaceIdAndName() throws {
        var list = HostList()
        let mac = list.add(try pairing("room-aaaaaaaaaaaaaaaa"), name: "MacBook")
        let server = list.add(try pairing("room-bbbbbbbbbbbbbbbb"), name: "Server")
        // The same room with a key now (paired before v5), under another name in the link.
        let key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        let again = list.add(try Pairing.parse(link(room: "room-aaaaaaaaaaaaaaaa", more: "&e=" + key)), name: "Sydneys MacBook")
        #expect(again.id == mac.id && again.name == "MacBook" && again.pairing.key == key)
        #expect(list.hosts.map(\.id) == [mac.id, server.id])
        #expect(list.active?.id == mac.id)
    }

    @Test func activatesRenamesAndRemoves() throws {
        var list = HostList()
        let mac = list.add(try pairing("room-aaaaaaaaaaaaaaaa"), name: "MacBook")
        let server = list.add(try pairing("room-bbbbbbbbbbbbbbbb"), name: "Server")
        list.activate(mac.id)
        #expect(list.active?.id == mac.id)
        list.activate("no-such-host")
        #expect(list.active?.id == mac.id)

        list.rename(server.id, to: "  Rechenzentrum  ")
        #expect(list.hosts.map(\.name) == ["MacBook", "Rechenzentrum"])
        list.rename(server.id, to: "   ")                              // an empty name changes nothing
        #expect(list.hosts[1].name == "Rechenzentrum")
        #expect(list.hosts[1].id == server.id && list.hosts[1].pairing == server.pairing)

        list.remove(server.id)                                         // not the active one: it stays
        #expect(list.hosts.map(\.id) == [mac.id] && list.active?.id == mac.id)
    }

    @Test func removingTheActiveHostFallsBackToTheFirstOfTheOthers() throws {
        var list = HostList()
        let a = list.add(try pairing("room-aaaaaaaaaaaaaaaa"), name: "A")
        let b = list.add(try pairing("room-bbbbbbbbbbbbbbbb"), name: "B")
        let c = list.add(try pairing("room-cccccccccccccccc"), name: "C")
        #expect(list.active?.id == c.id)
        list.remove(c.id)
        #expect(list.active?.id == a.id)
        list.activate(b.id)
        list.remove(b.id)
        #expect(list.active?.id == a.id)
        list.remove(a.id)                                              // the last one: the pairing screen
        #expect(list.active == nil && list.hosts.isEmpty)
    }

    @Test func anActiveIdThatIsGoneMeansTheFirstHost() throws {
        let a = HostPairing(name: "A", pairing: try pairing("room-aaaaaaaaaaaaaaaa"))
        let b = HostPairing(name: "B", pairing: try pairing("room-bbbbbbbbbbbbbbbb"))
        let stored = try JSONSerialization.data(withJSONObject: [
            "activeID": "gone",
            "hosts": try [a, b].map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) },
        ])
        let list = try JSONDecoder().decode(HostList.self, from: stored)
        #expect(list.hosts == [a, b] && list.active == a)
    }

    // MARK: the Keychain

    @Test func theSinglePairingBecomesTheFirstHost() throws {
        let hosts = "test-hosts-\(UUID().uuidString)", legacy = "test-relay-\(UUID().uuidString)"
        defer { PairingStore.remove(account: hosts); PairingStore.remove(account: legacy) }
        let old = try pairing("room-aaaaaaaaaaaaaaaa")
        try PairingStore.save(old, account: legacy)

        let list = PairingStore.loadHosts(account: hosts, legacy: legacy)
        #expect(list.hosts.map(\.name) == ["Mac"])
        #expect(list.active?.pairing == old)
        // It moved: the list is kept, the single item is gone — and the next launch finds the same host.
        #expect(PairingStore.load(account: legacy) == nil)
        #expect(PairingStore.loadHosts(account: hosts, legacy: legacy) == list)
    }

    @Test func nothingPairedIsAnEmptyList() {
        let hosts = "test-hosts-\(UUID().uuidString)", legacy = "test-relay-\(UUID().uuidString)"
        #expect(PairingStore.loadHosts(account: hosts, legacy: legacy) == HostList())
        #expect(PairingStore.loadHosts(account: hosts, legacy: legacy).active == nil)
    }

    @Test func theListWinsOverALeftoverSinglePairing() throws {
        let hosts = "test-hosts-\(UUID().uuidString)", legacy = "test-relay-\(UUID().uuidString)"
        defer { PairingStore.remove(account: hosts); PairingStore.remove(account: legacy) }
        var list = HostList()
        list.add(try pairing("room-aaaaaaaaaaaaaaaa"), name: "MacBook")
        try PairingStore.saveHosts(list, account: hosts)
        try PairingStore.save(try pairing("room-bbbbbbbbbbbbbbbb"), account: legacy)
        #expect(PairingStore.loadHosts(account: hosts, legacy: legacy) == list)
        #expect(PairingStore.load(account: legacy) != nil)             // not touched
    }

    @Test func theListRoundTripsAndTheLastHostRemovedLeavesNothing() throws {
        let hosts = "test-hosts-\(UUID().uuidString)", legacy = "test-relay-\(UUID().uuidString)"
        defer { PairingStore.remove(account: hosts) }
        var list = HostList()
        let mac = list.add(try pairing("room-aaaaaaaaaaaaaaaa"), name: "MacBook")
        let server = list.add(try pairing("room-bbbbbbbbbbbbbbbb"), name: "Server")
        list.activate(mac.id)
        try PairingStore.saveHosts(list, account: hosts)
        #expect(PairingStore.loadHosts(account: hosts, legacy: legacy) == list)

        list.remove(mac.id)                                            // saved over the item, not beside it
        try PairingStore.saveHosts(list, account: hosts)
        let loaded = PairingStore.loadHosts(account: hosts, legacy: legacy)
        #expect(loaded.hosts.map(\.id) == [server.id] && loaded.active?.id == server.id)

        list.remove(server.id)
        try PairingStore.saveHosts(list, account: hosts)
        #expect(PairingStore.loadHosts(account: hosts, legacy: legacy) == HostList())   // unpaired, as before
    }

    @Test func theStatusNamesTheHost() {
        #expect(ConnectionStatus.connected.label(host: "Server") == "Server verbunden")
        #expect(ConnectionStatus.unknownRoom.label(host: "Server") == "Server offline")
        #expect(ConnectionStatus.unreachable.label(host: "Server") == "Keine Verbindung")
        #expect(ConnectionStatus.hostOffline.word == "Offline")
    }
}
