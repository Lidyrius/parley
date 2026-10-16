import XCTest
@testable import Parley

// The iPhone relay (docs/IPHONE.md): pairing link, frames, change detection, and the client
// against a fake socket — no network.
final class RelayLinkTests: XCTestCase {
    private let config = RelayConfig(url: "https://parley-relay.x.workers.dev", room: "AbC-_1", secret: "s3cr3t-_")

    func testPairingLinkPercentEncodesTheRelayURL() {
        XCTAssertEqual(RelayLink.pairing(config),
                       "parley://pair?u=https%3A%2F%2Fparley-relay.x.workers.dev&r=AbC-_1&k=s3cr3t-_")
    }

    func testPairPageCarriesTheEncodedLinkInTheFragment() throws {
        let page = try XCTUnwrap(RelayLink.pairPage(config))
        XCTAssertEqual(page.absoluteString, "https://parley-relay.x.workers.dev/pair#parley%3A%2F%2Fpair%3Fu%3Dhttps%253A%252F%252Fparley-relay.x.workers.dev%26r%3DAbC-_1%26k%3Ds3cr3t-_")
        XCTAssertNil(page.query)   // the secret rides only in the fragment
        // The page decodes the fragment once → the pairing link → its query items.
        let link = try XCTUnwrap(page.fragment?.removingPercentEncoding)
        XCTAssertEqual(link, RelayLink.pairing(config))
        let items = try XCTUnwrap(URLComponents(string: link)?.queryItems)
        XCTAssertEqual(items.map(\.name), ["u", "r", "k"])
        XCTAssertEqual(items.map(\.value), ["https://parley-relay.x.workers.dev", "AbC-_1", "s3cr3t-_"])
    }

    func testEncodeKeepsOnlyUnreserved() {
        XCTAssertEqual(RelayLink.encode("aZ09-._~ /?#&=+%:"), "aZ09-._~%20%2F%3F%23%26%3D%2B%25%3A")
    }

    func testNormalize() {
        XCTAssertEqual(RelayLink.normalize("  https://r.example.dev//\n"), "https://r.example.dev")
        XCTAssertEqual(RelayLink.normalize("r.example.dev"), "https://r.example.dev")
        XCTAssertEqual(RelayLink.normalize(""), "")
    }

    func testSocketURLDerivesTheWsScheme() {
        XCTAssertEqual(RelayLink.socket(config)?.absoluteString,
                       "wss://parley-relay.x.workers.dev/v1/room/AbC-_1?role=host")
        let dev = RelayConfig(url: "http://localhost:8787", room: "r", secret: "k")
        XCTAssertEqual(RelayLink.socket(dev)?.absoluteString, "ws://localhost:8787/v1/room/r?role=host")
        XCTAssertNil(RelayLink.socket(RelayConfig(url: "ftp://x", room: "r", secret: "k")))
        XCTAssertFalse(RelayConfig(url: "ftp://x", room: "r", secret: "k").isComplete)
        XCTAssertFalse(RelayConfig(url: "https://x", room: "", secret: "k").isComplete)
        XCTAssertTrue(config.isComplete)
    }

    func testTokensAreBase64urlWithoutPadding() {
        XCTAssertEqual(RelayLink.base64url(Data([0xfb, 0xff])), "-_8")
        let room = RelayLink.token(bytes: 16), secret = RelayLink.token(bytes: 32)
        XCTAssertEqual(room.count, 22)
        XCTAssertEqual(secret.count, 43)
        let alphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue((room + secret).unicodeScalars.allSatisfy(alphabet.contains))
        XCTAssertNotEqual(RelayLink.token(bytes: 32), secret)
    }
}

final class RelayFrameTests: XCTestCase {
    private func object(_ json: String?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(json).utf8)) as? [String: Any])
    }

    func testSessionsFrameIsTheOverviewPlusTypeAndClock() throws {
        let reg = SessionRegistry(now: { Date(timeIntervalSince1970: 1_760_000_000) }, phase: { "idle" }, daily: DailyStats())
        reg.presence(id: "a", label: "Demo", project: "demo", state: "idle")
        let at = Date(timeIntervalSince1970: 1_760_000_123.456)
        let frame = try object(RelayFrame.sessions(reg.json(), at: at))
        XCTAssertEqual(Set(frame.keys), ["t", "at", "sessions", "today"])
        XCTAssertEqual(frame["t"] as? String, "sessions")
        XCTAssertEqual((frame["at"] as? NSNumber)?.int64Value, 1_760_000_123_456)
        let rows = try XCTUnwrap(frame["sessions"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["label"] as? String, "Demo")
        XCTAssertEqual(rows.first?["resumable"] as? Bool, true)
        XCTAssertNotNil(frame["today"] as? [String: Any])
    }

    func testSessionsFrameEdgeCases() throws {
        let at = Date(timeIntervalSince1970: 1)
        XCTAssertEqual(RelayFrame.sessions("{}", at: at), #"{"t":"sessions","at":1000}"#)
        XCTAssertNil(RelayFrame.sessions("[]", at: at))
        XCTAssertNil(RelayFrame.sessions("", at: at))
    }

    func testDispatchHandsOnlyResumeOn() {
        var resumed: [String] = []
        for text in [#"{"t":"resume","id":"s1"}"#, #"{"t":"hello","device":"iPhone"}"#, #"{"t":"later","id":"s2"}"#,
                     "pong", #"{"t":"resume"}"#, #"{"t":"resume","id":""}"#, #"{"id":"s3"}"#, #"{"t":"resume","id":"s4","x":1}"#] {
            RelayFrame.dispatch(text) { resumed.append($0) }
        }
        XCTAssertEqual(resumed, ["s1", "s4"])
    }

    // The frame lands on POST /resume's own path: the voice dialog through the turn queue.
    func testResumeFrameRunsThePostResumeDialog() throws {
        let server = ControlServer(sessions: SessionRegistry(phase: { "idle" }, daily: DailyStats()))
        let presence = #"{"session_id":"a","label":"Demo","project":"demo","cwd":"/x/demo","state":"idle"}"#
        XCTAssertEqual(server.handle(HTTPRequest(method: "POST", path: "/presence", body: Data(presence.utf8))).0, 200)
        var dialogs: [TurnPayload] = []
        server.replyProvider = { turn, _ in dialogs.append(turn) }

        RelayFrame.dispatch(#"{"t":"resume","id":"nope"}"#, resume: server.resumeFromRelay)
        RelayFrame.dispatch(#"{"t":"resume","id":"a"}"#, resume: server.resumeFromRelay)
        _ = server.resumableList()   // barrier: server queue drained
        XCTAssertEqual(dialogs.map(\.event), [ControlServer.resumeEvent])
        XCTAssertEqual(dialogs.first?.session_id, "a")
        XCTAssertTrue(server.sessionsJSON().contains(#""state":"speaking""#))   // holds the voice now
    }
}

final class RelaySyncTests: XCTestCase {
    func testSendsOnChangeAndEveryTenSeconds() {
        var sync = RelaySync()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(sync.due("a", at: t0))                           // first
        XCTAssertFalse(sync.due("a", at: t0 + 2))
        XCTAssertFalse(sync.due("a", at: t0 + 8))                      // unchanged within 10 s
        XCTAssertTrue(sync.due("b", at: t0 + 9))                       // changed
        XCTAssertFalse(sync.due("b", at: t0 + 11))
        XCTAssertTrue(sync.due("b", at: t0 + 19))                      // heartbeat (2 s ticks: 9 → 19)
        sync.reset()
        XCTAssertTrue(sync.due("b", at: t0 + 20))                      // reconnected → at once
    }

    func testBackoffDoublesToThirtySeconds() {
        var b: TimeInterval = 1, seen: [TimeInterval] = []
        for _ in 0..<7 { seen.append(b); b = RelayClient.nextBackoff(b) }
        XCTAssertEqual(seen, [1, 2, 4, 8, 16, 30, 30])
    }
}

final class RelayClientTests: XCTestCase {
    private final class Fake: RelaySocket, @unchecked Sendable {
        let request: URLRequest
        var sent: [String] = []
        var closed = false
        var onReceive: (@Sendable (Result<String?, any Error>) -> Void)?
        init(_ r: URLRequest) { request = r }
        func send(_ text: String, completion: @escaping @Sendable ((any Error)?) -> Void) { sent.append(text); completion(nil) }
        func receive(_ handler: @escaping @Sendable (Result<String?, any Error>) -> Void) { onReceive = handler }
        func close() { closed = true }
    }

    private final class World: @unchecked Sendable {
        var t = Date(timeIntervalSince1970: 1_760_000_000)
        var json = #"{"sessions":[],"today":{}}"#
        var sockets: [Fake] = []
        var resumed: [String] = []
        var states: [Bool] = []
    }

    private let queue = DispatchQueue(label: "test.relay")
    private var world = World()
    private var client: RelayClient!

    override func setUp() {
        world = World()
        let w = world
        let config = RelayConfig(url: "https://relay.example.dev/", room: "room1", secret: "sekret")
        client = RelayClient(config: config, sessions: { w.json }, resume: { w.resumed.append($0) },
                             now: { w.t }, connect: { let s = Fake($0); w.sockets.append(s); return s },
                             log: { _ in }, queue: queue)
        client.onState = { w.states.append($0) }
        client.start()
        drain()
    }

    override func tearDown() { client.stop(); drain() }

    private func drain() { queue.sync {}; queue.sync {} }   // the hop after a socket callback, too
    private func tick(after s: TimeInterval) { world.t += s; queue.sync { client.tick() }; drain() }
    private var socket: Fake { world.sockets.last! }

    func testConnectsAsHostWithTheSecretAndSendsTheOverview() throws {
        XCTAssertEqual(world.sockets.count, 1)
        XCTAssertEqual(socket.request.url?.absoluteString, "wss://relay.example.dev/v1/room/room1?role=host")
        XCTAssertEqual(socket.request.value(forHTTPHeaderField: "Authorization"), "Bearer sekret")
        XCTAssertEqual(socket.sent, [#"{"t":"sessions","at":1760000000000,"sessions":[],"today":{}}"#])
        XCTAssertEqual(world.states, [true])
    }

    func testResendsOnlyOnChangeOrHeartbeatAndPings() {
        tick(after: 2)
        XCTAssertEqual(socket.sent.count, 1)                            // unchanged
        world.json = #"{"sessions":[{"id":"a"}],"today":{}}"#
        tick(after: 2)
        XCTAssertEqual(socket.sent.count, 2)                            // changed
        XCTAssertTrue(socket.sent[1].hasPrefix(#"{"t":"sessions","at":1760000004000,"sessions":[{"id":"a"}]"#))
        tick(after: 2); tick(after: 2); tick(after: 2); tick(after: 2)
        XCTAssertEqual(socket.sent.count, 2)                            // 8 s unchanged
        tick(after: 2)
        XCTAssertEqual(socket.sent.count, 3)                            // 10 s → heartbeat
        for _ in 0..<7 { tick(after: 2) }                               // 25 s since connect
        XCTAssertTrue(socket.sent.contains("ping"))
    }

    func testIncomingResumeIsHandedOnOthersIgnored() {
        for text in [#"{"t":"hello","device":"iPhone"}"#, "pong", #"{"t":"resume","id":"s1"}"#, #"{"t":"x"}"#] {
            socket.onReceive?(.success(text))
            drain()
        }
        socket.onReceive?(.success(nil))                                 // binary: ignored
        drain()
        XCTAssertEqual(world.resumed, ["s1"])
        XCTAssertFalse(socket.closed)
    }

    func testFailureDropsTheSocketAndReportsUnreachable() {
        socket.onReceive?(.failure(URLError(.networkConnectionLost)))
        drain()
        XCTAssertTrue(socket.closed)
        XCTAssertEqual(world.states, [true, false])
        tick(after: 2)
        XCTAssertEqual(socket.sent.count, 1)                            // nothing sent while down
    }

    func testSilentRelayCountsAsDead() {
        tick(after: 61)                                                 // no pong for 61 s
        XCTAssertTrue(socket.closed)
        XCTAssertEqual(world.states, [true, false])
    }
}
