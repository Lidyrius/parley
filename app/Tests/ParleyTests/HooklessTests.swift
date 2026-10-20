import XCTest
@testable import Parley

// docs/HOOKLESS.md: the mod posts its turn with async and returns; what comes of it reaches the
// session as a delivery on its /presence (acked, resent, once per id), a wait ends on the host's
// timer, Sir's typing cancels the turn, the mod's session.end clears it, GET /mod tells the hook.
final class HooklessTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_760_000_000) }
    private final class Held: @unchecked Sendable {
        var done: [String: (TurnReply) -> Void] = [:]
        var timers: [(TimeInterval, () -> Void)] = []
    }
    private var clock = Clock()
    private var reg: SessionRegistry!
    private var server: ControlServer!
    private var held = Held()

    override func setUp() {
        clock = Clock()
        held = Held()
        let c = clock, h = held
        reg = SessionRegistry(now: { c.t }, phase: { "speaking" }, daily: DailyStats(now: { c.t }))
        server = ControlServer(sessions: reg, now: { c.t })
        server.closer = { _, _ in XCTFail("the mod's /close must not end the process"); return nil }
        server.zentraleDir = { "/z/parley-zentrale" }
        server.replyProvider = { turn, done in h.done[ControlServer.sessionKey(turn)] = done }
        server.waitTimer = { s, fire in h.timers.append((s, fire)) }
    }

    @discardableResult
    private func post(_ path: String, _ json: String) -> (Int, String) {
        server.handle(HTTPRequest(method: "POST", path: path, body: Data(json.utf8)))
    }

    private func object(_ s: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
    }

    private func turn(_ id: String, _ n: Int) -> (Int, String) {
        post("/turn", #"{"event":"turn","session_id":"\#(id)","cwd":"/x/\#(id)","project":"\#(id)","tmux_pane":"","speak":"Frage?","async":true,"turn_id":"\#(id):\#(n)"}"#)
    }

    // The mod's heartbeat: async, its open turn, its last ack.
    private func presence(_ id: String, awaiting: String? = nil, ack: String? = nil, async: Bool = true) throws -> [String: Any] {
        var extra = async ? #","async":1"# : ""
        if let awaiting { extra += #","awaiting":"\#(awaiting)""# }
        if let ack { extra += #","ack":"\#(ack)""# }
        return try object(post("/presence", #"{"session_id":"\#(id)","cwd":"/x/\#(id)","state":"idle"\#(extra)}"#).1)
    }

    private func answer(_ id: String, _ reply: TurnReply) { held.done[id]?(reply); barrier() }
    private func barrier() { _ = server.resumableList() }

    func testAnAsyncTurnIsQueuedAndItsTranscriptDeliveredUntilAcked() throws {
        try presence("a")
        XCTAssertEqual(try object(turn("a", 1).1)["queued"] as? Bool, true)
        XCTAssertNil(try presence("a", awaiting: "a:1")["unknown_turn"])   // queued: known
        answer("a", TurnReply(transcript: "Ja, bau es.", park: false))

        let first = try presence("a", awaiting: "a:1")
        XCTAssertEqual(first["instruction"] as? String, "Ja, bau es.")
        let id = try XCTUnwrap(first["delivery_id"] as? String)
        XCTAssertEqual(first["unknown_turn"] as? Bool, true)               // answered: the mod stops waiting
        XCTAssertEqual(reg.info("a")?.state, "working")

        XCTAssertNil(try presence("a")["instruction"])                      // no ack yet, but not before 10 s
        clock.t += SessionRegistry.resendAfter
        let again = try presence("a")
        XCTAssertEqual(again["delivery_id"] as? String, id)                 // the same id: the mod dedups
        XCTAssertEqual(again["instruction"] as? String, "Ja, bau es.")
        clock.t += SessionRegistry.resendAfter
        XCTAssertNil(try presence("a", ack: id)["instruction"])             // acked: gone
        clock.t += SessionRegistry.resendAfter
        XCTAssertNil(try presence("a", ack: id)["instruction"])
    }

    func testAnOlderModGetsADeliveryOnceWithoutAnId() throws {
        try presence("a", async: false)
        server.resume(id: "a", instruction: "Weiter"); barrier()
        XCTAssertEqual(post("/presence", #"{"session_id":"a","cwd":"/x/a","state":"idle"}"#).1, #"{"instruction":"Weiter"}"#)
        clock.t += SessionRegistry.resendAfter
        XCTAssertEqual(post("/presence", #"{"session_id":"a","cwd":"/x/a","state":"idle"}"#).1, "{}")
    }

    func testParkAndSilenceDeliverNothingAndFortsetzenReachesTheMod() throws {
        try presence("a")
        turn("a", 1)
        answer("a", TurnReply(transcript: "", park: true))
        let p = try presence("a", awaiting: "a:1")
        XCTAssertNil(p["instruction"])
        XCTAssertEqual(p["unknown_turn"] as? Bool, true)
        XCTAssertEqual(reg.info("a")?.state, "parked")
        XCTAssertFalse(reg.parkedHookAlive("a"))                            // no hook polls /wake
        XCTAssertTrue(reg.canResume("a"))
        server.resume(id: "a", instruction: "Mach weiter"); barrier()
        XCTAssertEqual(try presence("a")["instruction"] as? String, "Mach weiter")

        turn("a", 2)
        answer("a", TurnReply(transcript: "", park: false))                 // <speak-end> / silence
        XCTAssertNil(try presence("a")["instruction"])
    }

    func testAWaitEndsOnTheHostsTimerOrEarlyWithFortsetzen() throws {
        try presence("w")
        turn("w", 1)
        answer("w", TurnReply(transcript: "", park: false, waitSeconds: 120, resume: "Die Wartezeit ist vorbei."))
        XCTAssertEqual(held.timers.map(\.0), [120])
        XCTAssertEqual(reg.info("w")?.state, "waiting")
        XCTAssertNil(try presence("w", awaiting: "w:1")["unknown_turn"])    // still known during the wait
        clock.t += 121
        server.queue.sync { held.timers[0].1() }
        let done = try presence("w", awaiting: "w:1")
        XCTAssertEqual(done["instruction"] as? String, "Die Wartezeit ist vorbei.")
        XCTAssertEqual(done["unknown_turn"] as? Bool, true)

        try presence("v")
        turn("v", 1)
        answer("v", TurnReply(transcript: "", park: false, waitSeconds: 300, resume: "Weiter nach der Pause."))
        XCTAssertTrue(reg.canResume("v"))
        server.resume(id: "v", instruction: ControlServer.resumeInstruction); barrier()
        let early = try XCTUnwrap(try presence("v")["instruction"] as? String)
        XCTAssertTrue(early.contains("vorzeitig beendet") && early.hasSuffix("Weiter nach der Pause."))
        server.queue.sync { held.timers[1].1() }                            // the old timer: nothing more
        clock.t += SessionRegistry.resendAfter
        XCTAssertEqual(try presence("v", ack: "x")["instruction"] as? String, early)   // only the resend of the one
    }

    func testCancelDropsAQueuedTurnDiscardsAVoicedOneAndEndsAWait() throws {
        try presence("x"); try presence("a"); try presence("b"); try presence("w")
        turn("x", 1)                                                        // holds the voice
        turn("a", 1)
        XCTAssertEqual(server.queuedCount(), 1)
        XCTAssertEqual(post("/turn/cancel", #"{"session_id":"a","turn_id":"a:1"}"#).0, 200)
        XCTAssertEqual(server.queuedCount(), 0)
        XCTAssertEqual(try presence("a", awaiting: "a:1")["unknown_turn"] as? Bool, true)
        XCTAssertEqual(post("/turn/cancel", #"{"session_id":"a","turn_id":"a:1"}"#).0, 404)

        XCTAssertEqual(post("/turn/cancel", #"{"session_id":"x","turn_id":"x:1"}"#).0, 200)   // being voiced
        answer("x", TurnReply(transcript: "Zu spät gesagt", park: false))
        XCTAssertNil(try presence("x")["instruction"])
        XCTAssertNotEqual(reg.info("x")?.state, "working")

        turn("w", 1)
        answer("w", TurnReply(transcript: "", park: false, waitSeconds: 60, resume: "weiter"))
        XCTAssertEqual(post("/turn/cancel", #"{"session_id":"w","turn_id":"w:1"}"#).0, 200)
        XCTAssertNotEqual(reg.info("w")?.state, "waiting")
        server.queue.sync { held.timers[0].1() }
        XCTAssertNil(try presence("w")["instruction"])
    }

    func testANewerTurnDropsTheOlderOne() throws {
        try presence("x"); try presence("a")
        turn("x", 1)
        turn("a", 1)
        turn("a", 2)
        XCTAssertEqual(server.queuedCount(), 1)
        XCTAssertEqual(try presence("a", awaiting: "a:1")["unknown_turn"] as? Bool, true)
        XCTAssertNil(try presence("a", awaiting: "a:2")["unknown_turn"])
    }

    func testTheModsCloseClearsQueueAndDeliveries() throws {
        try presence("x"); try presence("a")
        turn("x", 1)
        turn("a", 1)
        server.resume(id: "a", instruction: "Noch offen"); barrier()
        XCTAssertEqual(post("/close", #"{"session_id":"a"}"#).0, 200)
        XCTAssertEqual(server.queuedCount(), 0)
        XCTAssertNil(try presence("a")["instruction"])
        XCTAssertEqual(try presence("a", awaiting: "a:1")["unknown_turn"] as? Bool, true)
    }

    func testUnknownTurnAfterARestart() throws {
        XCTAssertEqual(try presence("a", awaiting: "a:7")["unknown_turn"] as? Bool, true)
        XCTAssertEqual(post("/presence", #"{"session_id":"a","state":"idle","async":1}"#).1, "{}")   // nothing awaited
    }

    func testModIsLiveWhileAnAsyncModReports() throws {
        func live(_ id: String) throws -> Bool? {
            try object(server.handle(HTTPRequest(method: "GET", path: "/mod?session_id=\(id)", body: Data())).1)["live"] as? Bool
        }
        XCTAssertEqual(try live("a"), false)
        try presence("a", async: false)
        XCTAssertEqual(try live("a"), false)                                // an older mod: the hook carries it
        try presence("a")
        XCTAssertEqual(try live("a"), true)
        clock.t += SessionRegistry.modLive + 1
        XCTAssertEqual(try live("a"), false)                                // the mod is gone: the hook again
    }
}
