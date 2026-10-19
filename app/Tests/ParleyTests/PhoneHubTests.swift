import XCTest
@testable import Parley

// Protocol v2 text frames and the host's phone state: call / wake / push / away.
// A call whose `call end` got lost: no mic audio for 6 s → over here too.
final class PhoneCallGoneTests: XCTestCase {
    func testACallWithoutAudioIsOver() {
        final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_760_000_000) }
        let clock = Clock()
        let hub = PhoneHub(store: .memory(), log: { _ in }, now: { clock.t })
        hub.handle(.call(true))
        XCTAssertTrue(hub.callActive)
        for _ in 0..<5 { clock.t += 2; hub.audioIn(Data(count: 640)); hub.checkAlive() }   // streaming (also muted: zeros)
        XCTAssertTrue(hub.callActive)
        clock.t += 5; hub.checkAlive()
        XCTAssertTrue(hub.callActive)                                                       // a short gap is fine
        clock.t += 2; hub.checkAlive()
        XCTAssertFalse(hub.callActive)                                                      // 7 s of nothing: gone
    }
}

final class PhoneFrameTests: XCTestCase {
    func testParsesTheV2FramesAndIgnoresTheRest() {
        XCTAssertEqual(RelayFrame.parse(#"{"t":"call","state":"start"}"#), .call(true))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"call","state":"start","down":24000}"#), .call(true, down: 24000))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"call","state":"start","down":44100}"#), .call(true, down: 16000))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"call","state":"end"}"#), .call(false))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"wake"}"#), .wake)
        XCTAssertEqual(RelayFrame.parse(#"{"t":"push","token":"A1b2","env":"production"}"#), .push(token: "a1b2", env: "production"))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"push","token":"a1"}"#), .push(token: "a1", env: "production"))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"push","token":"a1","env":"development"}"#), .push(token: "a1", env: "development"))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"away","on":true}"#), .away(true))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"away","on":false}"#), .away(false))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"resume","id":"s1"}"#), .resume("s1"))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"silent","on":true}"#), .silent(true))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"round","seconds":180}"#), .round(seconds: 180))
        XCTAssertNil(RelayFrame.parse(#"{"t":"round"}"#))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"push","token":"AB","env":"production","kind":"alert"}"#), .alert(token: "ab", env: "production"))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"history","id":"s1"}"#), .history(id: "s1", before: nil))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"history","id":"s1","before":"u#0"}"#), .history(id: "s1", before: "u#0"))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"image","id":"s1","key":"u#0"}"#), .image(id: "s1", key: "u#0"))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"say","id":"s1","text":"  Mach weiter. "}"#), .say(id: "s1", text: "Mach weiter."))
        for junk in [#"{"t":"call","state":"ringing"}"#, #"{"t":"call"}"#, #"{"t":"push","token":"not hex!"}"#,
                     #"{"t":"push","token":""}"#, #"{"t":"away","on":"yes"}"#, #"{"t":"palette"}"#,
                     #"{"t":"audio","state":"idle"}"#, "pong", "[]", #"{"state":"start"}"#,
                     #"{"t":"say","id":"s1","text":"  "}"#, #"{"t":"history"}"#, #"{"t":"image","id":"s1"}"#] {
            XCTAssertNil(RelayFrame.parse(junk), junk)
        }
    }

    func testHostFrames() throws {
        XCTAssertEqual(RelayFrame.audio(.speaking), #"{"t":"audio","state":"speaking"}"#)
        XCTAssertEqual(RelayFrame.audio(.idle), #"{"t":"audio","state":"idle"}"#)
        let audio = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(RelayFrame.audio(.speaking, label: "Tipp\"frei").utf8)) as? [String: String])
        XCTAssertEqual(audio, ["t": "audio", "state": "speaking", "label": "Tipp\"frei"])
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

    func testSpeakerRidesOnAudioFramesAndAChangeIsSentAtOnce() throws {
        hub.setSpeaker("Zentrale")                         // no call: kept, not sent
        XCTAssertEqual(wire.text, [])
        hub.handle(.call(true))
        hub.setSpeaker("Zentrale")                         // unchanged → nothing
        hub.setSpeaker("workspace")
        hub.setAudioState(.speaking)
        let frames = try wire.text.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String]) }
        XCTAssertEqual(frames, [["t": "audio", "state": "idle", "label": "Zentrale"],
                                ["t": "audio", "state": "idle", "label": "workspace"],
                                ["t": "audio", "state": "speaking", "label": "workspace"]])
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

    func testADeclinedRingAndItsLaterAreTakenOnce() {
        hub.handle(.call(false))                       // `call end` with no call: declined
        XCTAssertTrue(hub.takeDeclined())
        XCTAssertFalse(hub.takeDeclined())
        hub.handle(.later(300))
        XCTAssertEqual(hub.takeLater(), .some(300))
        XCTAssertNil(hub.takeLater())
        hub.handle(.call(true))
        hub.handle(.call(false))                       // a real call's end is no decline
        XCTAssertFalse(hub.takeDeclined())
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

    // Einstellungen → Fragerunde: kept, clamped to 0…600 s, 90 s until the phone says otherwise.
    func testFragerundeFromThePhone() {
        XCTAssertEqual(hub.roundSeconds, 90)
        hub.handle(.round(seconds: 180))
        XCTAssertEqual(hub.roundSeconds, 180)
        hub.handle(.round(seconds: 0))
        XCTAssertEqual(hub.roundSeconds, 0)
        hub.handle(.round(seconds: 9999))
        XCTAssertEqual(hub.roundSeconds, 600)
    }

    func testStummAlertTokenAndChatEvents() {
        let seen = Wire()
        hub.onChat = { e in seen.lock.withLock { seen.text.append("\(e)") } }
        XCTAssertFalse(hub.silent)
        XCTAssertNil(hub.alertTarget)
        hub.handle(.silent(true))
        XCTAssertTrue(hub.silent)
        XCTAssertEqual(wire.changes, 1)
        hub.handle(.alert(token: "beef", env: "production"))
        XCTAssertEqual(hub.alertTarget?.token, "beef")
        hub.handle(.history(id: "s1", before: nil))
        hub.handle(.say(id: "s1", text: "Weiter"))
        XCTAssertEqual(seen.text.count, 2)
        hub.reply("x")                                     // answers go out without a call
        XCTAssertEqual(wire.text, ["x"])
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

    // The Mac locked (with the setting on) counts as Unterwegs; the phone's own choice stays its own.
    func testALockedMacCountsAsAway() {
        let hub = PhoneHub(store: .memory(), log: { _ in })
        XCTAssertFalse(hub.away)
        hub.setLockedAway(true)
        XCTAssertTrue(hub.away)
        XCTAssertFalse(hub.chosenAway)
        hub.handle(.away(true))                 // chosen on the phone while locked: kept
        hub.setLockedAway(false)
        XCTAssertTrue(hub.away)
        hub.handle(.away(false))
        XCTAssertFalse(hub.away)
    }

    // Barge-in: only during a call; taken once; the last 2 s of mic are kept for the listener.
    func testBargeAndThePreroll() {
        let hub = PhoneHub(store: .memory(), log: { _ in })
        hub.handle(.barge)
        XCTAssertFalse(hub.barged)                 // no call → nothing to stop
        hub.handle(.call(true))
        for i in 0..<(PhoneHub.prerollFrames + 5) { hub.audioIn(Data([UInt8(i % 250)])) }
        XCTAssertEqual(hub.recentMic().count, PhoneHub.prerollFrames)
        XCTAssertEqual(hub.recentMic().first, Data([5]))
        hub.handle(.barge)
        XCTAssertTrue(hub.barged)
        XCTAssertTrue(hub.takeBarge())
        XCTAssertFalse(hub.takeBarge())
        XCTAssertEqual(RelayFrame.parse(#"{"t":"barge"}"#), .barge)
    }
}
