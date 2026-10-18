import Foundation
import Testing
@testable import ParleyMobile

struct PairingTests {
    let room = "AbCdEfGhIjKlMnOpQrStUv"                         // 22 chars (16 bytes)
    let secret = "s3cr3t-_s3cr3t-_s3cr3t-_s3cr3t-_s3cr3t-_abc" // 43 chars (32 bytes)

    func link(u: String = "https%3A%2F%2Frelay.example.com", r: String? = nil, k: String? = nil) -> String {
        "parley://pair?u=\(u)&r=\(r ?? room)&k=\(k ?? secret)"
    }

    @Test func parsesTheHostsLink() throws {
        let p = try Pairing.parse(link())
        #expect(p.relay == URL(string: "https://relay.example.com"))
        #expect(p.room == room)
        #expect(p.secret == secret)
        #expect(p.socketURL.absoluteString == "wss://relay.example.com/v1/room/\(room)?role=phone")
    }

    @Test func takesTheEndToEndKey() throws {
        let key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        #expect(try Pairing.parse(link() + "&e=" + key).key == key)
        #expect(try Pairing.parse(link()).key == nil)                       // an older host: in the clear
        #expect(throws: PairingError.badSecret) { try Pairing.parse(link() + "&e=short") }
    }

    @Test func opensTheSharedVectorAndSpotsAnOutdatedPairing() throws {
        let seal = try #require(RelaySeal(key: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"))
        let wire = #"{"t":"say","e":"AAECAwQFBgcICQoLRwLXgg3JAhv2Y+Opi8sLDPr0qxaZH31GGhTUpzFLdNd5ZIzGjalz9BjLXZDH2UJ/vAoW9W/YqTFMX6pJ"}"#
        #expect(seal.open(text: wire)?.json == #"{"t":"say","id":"s1","text":"hallo"}"#)
        #expect(Relay.isSealed(wire))
        #expect(!Relay.isSealed(#"{"t":"peer","host":true}"#))
    }

    @Test func keepsPortAndBasePath() throws {
        let p = try Pairing.parse(link(u: "https%3A%2F%2Frelay.example.com%3A8443%2Fparley%2F"))
        #expect(p.socketURL.absoluteString == "wss://relay.example.com:8443/parley/v1/room/\(room)?role=phone")
    }

    @Test func toleratesWhitespaceAndUnencodedRelay() throws {
        let p = try Pairing.parse("  \n" + link(u: "https://relay.example.com") + "\n")
        #expect(p.relay.host() == "relay.example.com")
    }

    @Test func acceptsTheRelaysPairPageURL() throws {
        let inner = link().addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let p = try Pairing.parse("https://relay.example.com/pair#" + inner)
        #expect(p.room == room)
        #expect(p.relay == URL(string: "https://relay.example.com"))
    }

    @Test(arguments: [
        "https://relay.example.com",
        "parley://other?u=https%3A%2F%2Frelay.example.com",
        "hello world",
        "",
    ])
    func rejectsNonPairingLinks(_ text: String) {
        #expect(throws: PairingError.notALink) { try Pairing.parse(text) }
    }

    @Test(arguments: [
        "http%3A%2F%2Frelay.example.com",   // cleartext to a real host
        "ftp%3A%2F%2Frelay.example.com",
        "https%3A%2F%2F",                    // no host
        "relay.example.com",                 // no scheme
        "https%3A%2F%2Frelay.example.com%3Fx%3D1",
    ])
    func rejectsBadRelays(_ u: String) {
        #expect(throws: PairingError.badRelay) { try Pairing.parse(link(u: u)) }
    }

    @Test func rejectsMissingRelay() {
        #expect(throws: PairingError.badRelay) { try Pairing.parse("parley://pair?r=\(room)&k=\(secret)") }
    }

    #if DEBUG
    @Test func debugBuildsAcceptALocalRelay() throws {
        let p = try Pairing.parse(link(u: "http%3A%2F%2Flocalhost%3A8788"))
        #expect(p.socketURL.absoluteString == "ws://localhost:8788/v1/room/\(room)?role=phone")
    }
    #endif

    @Test(arguments: ["short", String(repeating: "a", count: 65), "AbCdEfGhIjKlMnOp+rSt", "AbCdEfGhIjKlMnOp=", "ÄbCdEfGhIjKlMnOpQr"])
    func rejectsBadRooms(_ r: String) {
        let encoded = r.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(throws: PairingError.badRoom) { try Pairing.parse(link(r: encoded)) }
    }

    @Test func roomLengthBounds() throws {
        _ = try Pairing.parse(link(r: String(repeating: "a", count: 16)))
        _ = try Pairing.parse(link(r: String(repeating: "a", count: 64)))
        #expect(throws: PairingError.badRoom) { try Pairing.parse(link(r: String(repeating: "a", count: 15))) }
    }

    @Test(arguments: ["", "tooShort", "has/slash/has/slash/x", "pad=pad=pad=pad=pad="])
    func rejectsBadSecrets(_ k: String) {
        let encoded = k.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(throws: PairingError.badSecret) { try Pairing.parse(link(k: encoded)) }
    }

    @Test func rejectsMissingSecret() {
        #expect(throws: PairingError.badSecret) {
            try Pairing.parse("parley://pair?u=https%3A%2F%2Frelay.example.com&r=\(room)")
        }
    }

    @Test func errorsReadInGerman() {
        #expect(PairingError.badRoom.errorDescription == "Die Raum-ID im Link ist ungültig.")
    }

    @Test func keychainRoundTrip() throws {
        let account = "test-\(UUID().uuidString)"
        defer { PairingStore.remove(account: account) }
        let p = try Pairing.parse(link())
        #expect(PairingStore.load(account: account) == nil)
        try PairingStore.save(p, account: account)
        #expect(PairingStore.load(account: account) == p)
        try PairingStore.save(p, account: account)  // overwrite, not a duplicate-item error
        PairingStore.remove(account: account)
        #expect(PairingStore.load(account: account) == nil)
    }
}
