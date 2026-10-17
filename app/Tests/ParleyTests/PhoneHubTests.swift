import XCTest
@testable import Parley

// Protocol v2 text frames and the host's phone state: call / wake / push / away.
final class PhoneFrameTests: XCTestCase {
    func testParsesTheV2FramesAndIgnoresTheRest() {
        XCTAssertEqual(RelayFrame.parse(#"{"t":"call","state":"start"}"#), .call(true))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"call","state":"end"}"#), .call(false))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"wake"}"#), .wake)
        XCTAssertEqual(RelayFrame.parse(#"{"t":"push","token":"A1b2","env":"production"}"#), .push(token: "a1b2", env: "production"))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"push","token":"a1"}"#), .push(token: "a1", env: "production"))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"push","token":"a1","env":"development"}"#), .push(token: "a1", env: "development"))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"away","on":true}"#), .away(true))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"away","on":false}"#), .away(false))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"resume","id":"s1"}"#), .resume("s1"))
        for junk in [#"{"t":"call","state":"ringing"}"#, #"{"t":"call"}"#, #"{"t":"push","token":"not hex!"}"#,
                     #"{"t":"push","token":""}"#, #"{"t":"away","on":"yes"}"#, #"{"t":"hello","device":"x"}"#,
                     #"{"t":"audio","state":"idle"}"#, "pong", "[]", #"{"state":"start"}"#] {
            XCTAssertNil(RelayFrame.parse(junk), junk)
        }
    }

    func testHostFrames() throws {
        XCTAssertEqual(RelayFrame.audio(.speaking), #"{"t":"audio","state":"speaking"}"#)
        XCTAssertEqual(RelayFrame.audio(.idle), #"{"t":"audio","state":"idle"}"#)
        let ring = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(RelayFrame.ring(label: #"Tipp "frei""#).utf8)) as? [String: String])
        XCTAssertEqual(ring, ["t": "ring", "label": #"Tipp "frei""#])
    }
}

final class PhoneHubTests: XCTestCase {
    private final class Wire: @unchecked Sendable {
        let lock = NSLock()
        var text: [String] = []
        var audio: [Data] = []
        var changes = 0
        var wakes = 0
    }

    private var wire = Wire()
    private var hub: PhoneHub!

    override func setUp() {
        wire = Wire()
        let w = wire
        hub = PhoneHub(store: .memory(), log: { _ in })
        hub.attach(text: { t in w.lock.withLock { w.text.append(t) } }, audio: { d in w.lock.withLock { w.audio.append(d) } })
        hub.onChange = { w.lock.withLock { w.changes += 1 } }
        hub.onWake = { w.lock.withLock { w.wakes += 1 } }
    }

    func testCallStartSendsTheCurrentStateAndEndKillsTheGeneration() {
        hub.setAudioState(.speaking)                       // no call: tracked, not sent
        XCTAssertEqual(wire.text, [])
        hub.handle(.call(true))
        XCTAssertTrue(hub.callActive)
        let gen = hub.callGeneration
        XCTAssertTrue(hub.isLive(gen))
        XCTAssertEqual(wire.text, [#"{"t":"audio","state":"speaking"}"#])
        hub.handle(.call(true))                            // repeated start keeps the call
        XCTAssertTrue(hub.isLive(gen))
        hub.setAudioState(.speaking)                       // unchanged → not resent
        hub.setAudioState(.listening)
        hub.setAudioState(.idle)
        XCTAssertEqual(wire.text.count, 3)
        hub.sendAudio(Data([1, 2]))
        XCTAssertEqual(wire.audio, [Data([1, 2])])
        hub.handle(.call(false))
        XCTAssertFalse(hub.isLive(gen))
        XCTAssertFalse(hub.callActive)
        hub.sendAudio(Data([3]))                           // no call → dropped
        XCTAssertEqual(wire.audio.count, 1)
        XCTAssertEqual(wire.changes, 2)
    }

    func testWakeOnlyDuringACallAndMicFramesOnlyToTheSink() {
        hub.handle(.wake)
        XCTAssertEqual(wire.wakes, 0)
        final class Got: @unchecked Sendable { var frames: [Data] = [] }
        let got = Got()
        hub.setAudioSink { got.frames.append($0) }
        hub.audioIn(Data([9]))                             // no call yet
        hub.handle(.call(true))
        hub.handle(.wake)
        hub.audioIn(Data([7]))
        XCTAssertEqual(wire.wakes, 1)
        XCTAssertEqual(got.frames, [Data([7])])
    }

    func testPushTokenAndAwayAreStored() {
        XCTAssertNil(hub.pushTarget)
        XCTAssertFalse(hub.away)
        hub.handle(.push(token: "abcd", env: "development"))
        XCTAssertEqual(hub.pushTarget?.token, "abcd")
        XCTAssertEqual(hub.pushTarget?.env, "development")
        hub.handle(.away(true))
        XCTAssertTrue(hub.away)
        hub.handle(.away(true))                            // unchanged → no change event
        XCTAssertEqual(wire.changes, 1)
        hub.handle(.away(false))
        XCTAssertFalse(hub.away)
    }

    func testRelayGoneEndsTheCall() async {
        hub.handle(.call(true))
        hub.detach()
        XCTAssertFalse(hub.callActive)
        hub.ring(label: "x")                               // detached: nothing goes out
        XCTAssertEqual(wire.text.count, 1)
    }

    func testWaitForCallReturnsWhenTheCallConnects() async {
        let hub = self.hub!
        Task { try? await Task.sleep(nanoseconds: 50_000_000); hub.handle(.call(true)) }
        let answered = await hub.waitForCall(timeout: 2, poll: 0.01)
        XCTAssertTrue(answered)
        hub.handle(.call(false))
        let unanswered = await hub.waitForCall(timeout: 0.05, poll: 0.01)
        XCTAssertFalse(unanswered)
    }
}

// Routing a wake utterance: the LLM's pick (stubbed), the label substring fallback, the Zentrale.
final class WakeRouterTests: XCTestCase {
    private let labels = ["Tippfrei", "Parley", "Zentrale"]

    private func llm(_ content: String) -> Data {
        let body: [String: Any] = ["choices": [["message": ["content": content]]]]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    func testParsesTheLLMPick() {
        XCTAssertEqual(WakeRouter.parse(llm(#"{"target":"Tippfrei"}"#), labels: labels), "Tippfrei")
        XCTAssertEqual(WakeRouter.parse(llm(#"{"target":"tippfrei"}"#), labels: labels), "Tippfrei")
        XCTAssertEqual(WakeRouter.parse(llm(#"{"target":"Zentrale"}"#), labels: labels), "Zentrale")
        XCTAssertEqual(WakeRouter.parse(llm(#"{"target":"Projekt Parley"}"#), labels: labels), "Parley")
        XCTAssertNil(WakeRouter.parse(llm(#"{"target":"Unbekannt"}"#), labels: labels))
        XCTAssertNil(WakeRouter.parse(llm(#"{"target":""}"#), labels: labels))
        XCTAssertNil(WakeRouter.parse(llm("Tippfrei"), labels: labels))
        XCTAssertNil(WakeRouter.parse(Data("garbage".utf8), labels: labels))
    }

    func testSubstringFallback() {
        XCTAssertEqual(WakeRouter.substring("Sag Tipp-Frei, es soll die Tests laufen lassen", labels: labels), "Tippfrei")
        XCTAssertEqual(WakeRouter.substring("Bei PARLEY bitte das Log prüfen", labels: labels), "Parley")
        XCTAssertEqual(WakeRouter.substring("Parley Mobile soll bauen", labels: ["Parley", "Parley Mobile"]), "Parley Mobile")
        XCTAssertNil(WakeRouter.substring("AB soll bauen", labels: ["AB"]))     // too short to trust
        XCTAssertNil(WakeRouter.substring("Wie wird das Wetter?", labels: labels))
    }

    func testRouteUsesTheLLMThenFallsBackThenTheZentrale() async {
        let sessions = [RouteTarget(id: "s1", label: "Tippfrei"), RouteTarget(id: "s2", label: "Parley")]
        let pick = llm(#"{"target":"Parley"}"#)
        var target = await WakeRouter.route("mach weiter mit der App", sessions: sessions, apiKey: "k") { _ in pick }
        XCTAssertEqual(target, RouteTarget(id: "s2", label: "Parley"))

        target = await WakeRouter.route("Tippfrei soll pushen", sessions: sessions, apiKey: "k") { _ in nil }   // LLM down
        XCTAssertEqual(target, RouteTarget(id: "s1", label: "Tippfrei"))

        final class Calls: @unchecked Sendable { var n = 0 }
        let calls = Calls()
        target = await WakeRouter.route("Leg ein neues Projekt an", sessions: sessions, apiKey: "") { _ in calls.n += 1; return nil }
        XCTAssertEqual(target, .zentrale)
        XCTAssertEqual(calls.n, 0)                                                                       // no key, no call

        let zentrale = llm(#"{"target":"Zentrale"}"#)
        target = await WakeRouter.route("Tippfrei? Nein, was Neues", sessions: sessions, apiKey: "k") { _ in zentrale }
        XCTAssertEqual(target, .zentrale)
    }

    func testRequestNamesTheSessionsAndTheZentrale() throws {
        let req = WakeRouter.request(text: "hallo", labels: labels, apiKey: "key")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(req.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertTrue(messages[0]["content"]!.contains("Tippfrei, Parley."))
        XCTAssertTrue(messages[0]["content"]!.contains("\"Zentrale\""))
        XCTAssertEqual(messages[1]["content"], "hallo")
    }
}
