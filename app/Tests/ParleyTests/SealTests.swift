import XCTest
@testable import Parley

// End-to-end encryption (docs/IPHONE.md → v5): the shared test vector, and the host refusing
// what a relay could forge or replay.
final class SealTests: XCTestCase {
    private let key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"   // bytes 0…31
    private let sent = Date(timeIntervalSince1970: 1_760_000_000)

    func testOpensTheSharedVector() throws {
        let seal = try XCTUnwrap(RelaySeal(key: key))
        let wire = #"{"t":"say","e":"AAECAwQFBgcICQoLRwLXgg3JAhv2Y+Opi8sLDPr0qxaZH31GGhTUpzFLdNd5ZIzGjalz9BjLXZDH2UJ/vAoW9W/YqTFMX6pJ"}"#
        let (json, at, nonce) = try XCTUnwrap(seal.open(text: wire))
        XCTAssertEqual(json, #"{"t":"say","id":"s1","text":"hallo"}"#)
        XCTAssertEqual(at, sent)
        XCTAssertEqual(nonce, Data(0..<12))
        let bin = try XCTUnwrap(Data(base64Encoded: "AAECAwQFBgcICQoLRwLXgg3JAhuMQ5SP9BVPlzF+XIBK4Zk6Q12WHA=="))
        XCTAssertEqual(seal.open(binary: bin)?.data, Data([1, 2, 3, 4]))
    }

    func testRoundTripKeepsTheTypeOutsideAndRefusesTampering() throws {
        let seal = try XCTUnwrap(RelaySeal(key: key))
        let wire = try XCTUnwrap(seal.text(#"{"t":"sessions","sessions":[]}"#, at: sent))
        let outer = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(wire.utf8)) as? [String: String])
        XCTAssertEqual(outer["t"], "sessions")
        XCTAssertFalse(wire.contains("[]"))
        XCTAssertEqual(seal.open(text: wire)?.json, #"{"t":"sessions","sessions":[]}"#)
        XCTAssertNil(seal.open(text: wire.replacingOccurrences(of: #""t":"sessions""#, with: #""t":"say""#)))   // type swapped
        XCTAssertNil(RelaySeal(key: RelayLink.token(bytes: 32))?.open(text: wire))                               // other key
        XCTAssertNil(seal.open(text: #"{"t":"say","id":"s1","text":"forged"}"#))                                   // in the clear
    }

    func testReplayGuardTakesEachFrameOnceAndOnlyFresh() {
        var guard_ = ReplayGuard()
        let n = Data(repeating: 1, count: 12)
        XCTAssertTrue(guard_.accept(at: sent, nonce: n, now: sent + 1))
        XCTAssertFalse(guard_.accept(at: sent, nonce: n, now: sent + 2))                            // replayed
        XCTAssertFalse(guard_.accept(at: sent, nonce: Data(repeating: 2, count: 12), now: sent + 121))   // stale
    }

    func testPairingLinkCarriesTheKey() {
        let c = RelayConfig(url: "https://r.example.dev", room: "room", secret: "sec", key: "kk")
        XCTAssertTrue(RelayLink.pairing(c).hasSuffix("&k=sec&e=kk"))
    }
}

// The client with a key: everything out sealed (but ping), everything in must open and be fresh.
final class SealedRelayClientTests: XCTestCase {
    private final class Fake: RelaySocket, @unchecked Sendable {
        var sent: [String] = []
        var sentData: [Data] = []
        var onReceive: (@Sendable (Result<RelayInbound, any Error>) -> Void)?
        func send(_ text: String, completion: @escaping @Sendable ((any Error)?) -> Void) { sent.append(text); completion(nil) }
        func send(data: Data, completion: @escaping @Sendable ((any Error)?) -> Void) { sentData.append(data); completion(nil) }
        func receive(_ handler: @escaping @Sendable (Result<RelayInbound, any Error>) -> Void) { onReceive = handler }
        func close() {}
    }
    private final class Box: @unchecked Sendable { var resumed: [String] = []; var audio: [Data] = []; var t = Date(timeIntervalSince1970: 1_760_000_000) }

    func testSealsOutAndOpensOnlyFreshSealedFramesIn() throws {
        let key = RelayLink.token(bytes: 32)
        let seal = try XCTUnwrap(RelaySeal(key: key))
        let queue = DispatchQueue(label: "test.sealed")
        let socket = Fake(), box = Box()
        let client = try XCTUnwrap(RelayClient(config: RelayConfig(url: "https://r.example.dev", room: "room", secret: "s", key: key),
                                               sessions: { #"{"sessions":[]}"# }, resume: { box.resumed.append($0) },
                                               now: { box.t }, connect: { _ in socket }, log: { _ in }, queue: queue))
        client.onAudio = { box.audio.append($0) }
        client.start()
        queue.sync {}; queue.sync {}
        XCTAssertEqual(seal.open(text: try XCTUnwrap(socket.sent.first))?.json.hasPrefix(#"{"t":"sessions""#), true)
        client.sendAudio(Data([9, 9]))
        queue.sync {}
        XCTAssertEqual(seal.open(binary: try XCTUnwrap(socket.sentData.first))?.data, Data([9, 9]))

        let resume = try XCTUnwrap(seal.text(#"{"t":"resume","id":"s1"}"#, at: box.t))
        for text in [#"{"t":"resume","id":"clear"}"#, resume, resume,                       // clear text, then a replay
                     try XCTUnwrap(seal.text(#"{"t":"resume","id":"old"}"#, at: box.t - 300))] {
            socket.onReceive?(.success(.text(text)))
            queue.sync {}; queue.sync {}
        }
        XCTAssertEqual(box.resumed, ["s1"])
        socket.onReceive?(.success(.binary(Data(repeating: 7, count: 640))))                 // clear audio
        socket.onReceive?(.success(.binary(try XCTUnwrap(seal.binary(Data([1]), at: box.t)))))
        queue.sync {}; queue.sync {}
        XCTAssertEqual(box.audio, [Data([1])])
        client.stop()
        queue.sync {}
    }
}
