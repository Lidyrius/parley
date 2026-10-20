import XCTest
@testable import Parley

// Hooks that would otherwise hang: a failed transcription doesn't park, /wake tells a stale
// poller to end, a newer /turn answers its session's older ones, /close empties the queue, an
// instruction for a stale-parked session goes both ways, and `queued` follows the queue.
final class StaleHookTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_760_000_000) }
    private final class Held: @unchecked Sendable { var done: [String: (TurnReply) -> Void] = [:]; var events: [String] = [] }
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
        server.closer = { _, _ in nil }
        server.zentraleDir = { "/z/parley-zentrale" }
        server.replyProvider = { turn, done in h.events.append(turn.event); h.done[ControlServer.sessionKey(turn)] = done }
    }

    @discardableResult
    private func post(_ path: String, _ json: String) -> (Int, String) {
        server.handle(HTTPRequest(method: "POST", path: path, body: Data(json.utf8)))
    }

    private func wake(_ id: String) throws -> [String: Any] {
        let body = post("/wake", #"{"session_id":"\#(id)","cwd":"/x/\#(id)","project":"\#(id)","tmux_pane":"","label":""}"#).1
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

    private func turn(_ id: String) -> TurnPayload {
        TurnPayload(event: "turn", session_id: id, cwd: "/x/\(id)", project: id, tmux_pane: "", speak: "Frage?")
    }

    private func barrier() { _ = server.resumableList() }

    // MARK: - transcription errors (AppController)

    func testAFailedTranscriptionEndsTheTurnWithoutParking() {
        XCTAssertFalse(AppController.quietEnd(stop: false, sttFailed: true).park)   // Groq 403 / network / timeout
        XCTAssertTrue(AppController.quietEnd(stop: false, sttFailed: false).park)   // silence
        XCTAssertTrue(AppController.quietEnd(stop: true, sttFailed: false).park)    // "Stopp"
    }

    // MARK: - /wake end

    func testWakeAfterCloseTellsTheHookToEnd() throws {
        XCTAssertNil(try wake("a")["end"])
        XCTAssertEqual(post("/close", #"{"id":"a"}"#).0, 200)
        XCTAssertEqual(try wake("a")["end"] as? Bool, true)
        // Resumed (same id): its new turn runs again, and so does its parking.
        server.receiveTurn(turn("a")) { _ in }
        held.done["a"]?(TurnReply(transcript: "", park: true)); barrier()
        XCTAssertNil(try wake("a")["end"])
    }

    func testWakeWhileANewerTurnIsUnansweredEndsTheStaleHook() throws {
        _ = try wake("p")
        server.receiveTurn(turn("p")) { _ in }                       // voiced, not answered yet
        let stale = try wake("p")
        XCTAssertEqual(stale["end"] as? Bool, true)
        XCTAssertEqual(stale["transcript"] as? String, "")
        held.done["p"]?(TurnReply(transcript: "", park: true)); barrier()
        XCTAssertNil(try wake("p")["end"])                           // its own hook now parks
    }

    func testWakeEndsAfterTwelveHoursParked() throws {
        XCTAssertNil(try wake("p")["end"])
        clock.t += 11 * 3600
        XCTAssertNil(try wake("p")["end"])
        clock.t += 3600 + 1
        XCTAssertEqual(try wake("p")["end"] as? Bool, true)
    }

    // MARK: - stale queued turns, /close

    func testANewerTurnAnswersTheOlderQueuedOneEmpty() {
        server.receiveTurn(turn("x")) { _ in }                       // holds the voice
        var old: [TurnReply] = []
        server.receiveTurn(turn("p")) { old.append($0) }
        XCTAssertEqual(server.queuedCount(), 1)
        server.receiveTurn(turn("p")) { _ in }
        XCTAssertEqual(old.map(\.transcript), [""])
        XCTAssertEqual(old.map(\.park), [false])
        XCTAssertEqual(server.queuedCount(), 1)                      // only the newer one waits
    }

    func testCloseAnswersItsQueuedItemsEmpty() throws {
        server.receiveTurn(turn("x")) { _ in }
        var got: [TurnReply] = []
        server.receiveTurn(turn("a")) { got.append($0) }
        XCTAssertEqual(post("/close", #"{"id":"a"}"#).0, 200)
        XCTAssertEqual(got.map(\.transcript), [""])
        XCTAssertEqual(got.map(\.park), [false])
        XCTAssertEqual(server.queuedCount(), 0)
        held.done["x"]?(TurnReply(transcript: "", park: false)); barrier()
        XCTAssertEqual(held.events, ["turn"])                       // a's turn is never voiced
    }

    // MARK: - deliver to a stale-parked session

    func testAStaleParkedSessionGetsTheInstructionOnceByWhicheverTakesItFirst() throws {
        _ = try wake("p")
        clock.t += SessionRegistry.parkTTL + 1                       // no /wake for over 30 s
        server.resume(id: "p", instruction: "Los"); barrier()
        XCTAssertEqual(try wake("p")["transcript"] as? String, "Los") // the hook took it …
        XCTAssertEqual(post("/presence", #"{"session_id":"p","cwd":"/x/p","state":"idle"}"#).1, "{}")   // … the mod's copy is gone

        _ = try wake("q")
        post("/presence", #"{"session_id":"q","cwd":"/x/q","state":"idle"}"#)
        clock.t += SessionRegistry.parkTTL + 1
        server.resume(id: "q", instruction: "Weiter"); barrier()
        XCTAssertTrue(post("/presence", #"{"session_id":"q","cwd":"/x/q","state":"idle"}"#).1.contains("Weiter"))
        XCTAssertEqual(try wake("q")["transcript"] as? String, "")   // the hook's copy is gone
    }

    func testAnEndedWaitIsNoParkedHook() {
        reg.queued(id: "w", label: "", project: "w")
        reg.finished(id: "w", reply: TurnReply(transcript: "", park: false, waitSeconds: 60, resume: "weiter"))
        reg.wakePoll(id: "w", label: "", project: "w", resumed: false)
        XCTAssertTrue(reg.parkedHookAlive("w"))
        clock.t += 61
        XCTAssertEqual(reg.info("w")?.state, "working")
        XCTAssertFalse(reg.parkedHookAlive("w"))
    }

    // MARK: - queued follows the queue

    func testADroppedDialogDoesNotHideTheSessionsQueuedTurn() {
        server.permissionHold = 0.1
        post("/presence", #"{"session_id":"a","label":"A","cwd":"/x/a","state":"working"}"#)
        server.receiveTurn(turn("x")) { _ in }                       // holds the voice
        let asked = expectation(description: "hold over")
        XCTAssertTrue(server.permission(Data(#"{"session_id":"a","cwd":"/x/a","tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8)) { _ in asked.fulfill() })
        server.queue.sync { self.server.receiveTurn(self.turn("a")) { _ in } }
        wait(for: [asked], timeout: 2)
        barrier()
        XCTAssertEqual(reg.info("a")?.state, "queued")               // its /turn still waits
    }
}
