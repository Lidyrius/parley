import XCTest
@testable import Parley

// Wiedervorlage: POST /remind → kept → handed over at its time, once a session is done, or to Sir.
final class ReminderTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_760_000_000) }
    private var clock = Clock()
    private var reg: SessionRegistry!
    private var server: ControlServer!
    private var voiced: [TurnPayload] = []
    private let dir = Zentrale.normalize(FileManager.default.temporaryDirectory.path)

    override func setUp() {
        clock = Clock()
        let c = clock
        reg = SessionRegistry(now: { c.t }, phase: { "idle" }, daily: DailyStats(now: { c.t }))
        server = ControlServer(sessions: reg, now: { c.t })
        voiced = []
        server.replyProvider = { [unowned self] turn, done in self.voiced.append(turn); done(TurnReply(transcript: "", park: false)) }
    }

    private func post(_ path: String, _ json: String) -> (Int, String) {
        server.handle(HTTPRequest(method: "POST", path: path, body: Data(json.utf8)))
    }

    @discardableResult
    private func presence(_ id: String, _ label: String, _ state: String) -> String {
        post("/presence", #"{"session_id":"\#(id)","label":"\#(label)","cwd":"\#(dir)","state":"\#(state)"}"#).1
    }

    private func tick() {
        server.tickReminders()
        _ = server.sessionsJSON()   // waits for the queue
    }

    private func listed() throws -> [[String: Any]] {
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(server.handle(HTTPRequest(method: "GET", path: "/remind", body: Data())).1.utf8)) as? [String: Any])
        return obj["reminders"] as? [[String: Any]] ?? []
    }

    func testAtATimeTheSessionGetsItAsAnInstruction() throws {
        presence("s1", "Shirts", "idle")
        let (code, body) = post("/remind", #"{"to":"Shirts","text":"Lass die Tests laufen","in":60}"#)
        XCTAssertEqual(code, 200, body)
        XCTAssertEqual(try listed().first?["to"] as? String, "Shirts")
        clock.t += 59 * 60
        tick()
        XCTAssertEqual(presence("s1", "Shirts", "idle"), "{}")                       // not yet
        clock.t += 61
        tick()
        XCTAssertTrue(presence("s1", "Shirts", "idle").contains("Lass die Tests laufen"))
        XCTAssertEqual(try listed().count, 0)                                         // once
    }

    func testAfterASessionIsDoneTheNextGetsIt() throws {
        presence("s1", "Shirts", "working")
        presence("z", "Zentrale", "idle")
        XCTAssertEqual(post("/remind", #"{"to":"Zentrale","text":"Deploye","after":"Shirts"}"#).0, 200)
        tick()
        XCTAssertEqual(presence("z", "Zentrale", "idle"), "{}")                       // Shirts still works
        let turn = TurnPayload(event: "turn", session_id: "s1", cwd: dir, project: "shirts", tmux_pane: "",
                               speak: "Fertig, Sir.", label: "Shirts", listen: true)
        server.receiveTurn(turn) { _ in }                                              // its turn ended
        _ = server.sessionsJSON()
        let handed = presence("z", "Zentrale", "idle")
        XCTAssertTrue(handed.contains("Deploye") && handed.contains("Shirts ist fertig"), handed)
    }

    func testForSirItIsSpoken() throws {
        XCTAssertEqual(post("/remind", #"{"text":"das Telefonat mit Max","in":5}"#).0, 200)
        clock.t += 5 * 60
        tick()
        XCTAssertEqual(voiced.map(\.speak), ["Erinnerung, Sir: das Telefonat mit Max"])
        XCTAssertEqual(voiced.first?.event, ControlServer.reminderEvent)
    }

    func testAReminderForSirWaitingInTheQueueEndsAFragerunde() {
        var held: ((TurnReply) -> Void)?
        server.replyProvider = { [unowned self] turn, done in voiced.append(turn); if held == nil { held = done } else { done(TurnReply(transcript: "", park: false)) } }
        let busy = TurnPayload(event: "turn", session_id: "s1", cwd: dir, project: "x", tmux_pane: "", speak: "…", label: "X", listen: true)
        server.receiveTurn(busy) { _ in }                       // being voiced (a Fragerunde gathers in it)
        XCTAssertFalse(server.timerQueued())
        XCTAssertEqual(post("/remind", #"{"text":"Probeanruf","in":0}"#).0, 200)   // due at once → queued behind
        XCTAssertTrue(server.timerQueued())
        held?(TurnReply(transcript: "", park: false))
        _ = server.sessionsJSON()
        XCTAssertFalse(server.timerQueued())
    }

    func testCancelAndBadRequests() throws {
        presence("s1", "Shirts", "idle")
        let made = post("/remind", #"{"to":"Shirts","text":"x","at":"2025-10-09T12:00:00+02:00"}"#)
        XCTAssertEqual(made.0, 200, made.1)
        let id = try XCTUnwrap(try listed().first?["id"] as? String)
        XCTAssertEqual(post("/remind/cancel", #"{"id":"\#(id)"}"#).0, 200)
        XCTAssertEqual(try listed().count, 0)
        XCTAssertEqual(post("/remind/cancel", #"{"id":"\#(id)"}"#).0, 404)
        XCTAssertEqual(post("/remind", #"{"to":"Niemand","text":"x","in":1}"#).0, 400)
        XCTAssertEqual(post("/remind", #"{"to":"Shirts","text":"x"}"#).0, 400)                  // no time
        XCTAssertEqual(post("/remind", #"{"to":"Shirts","text":"x","in":1,"after":"Shirts"}"#).0, 400)
        XCTAssertEqual(post("/remind", #"{"text":"x","after":"Shirts"}"#).0, 400)               // Sir can't wait for a turn
        XCTAssertEqual(post("/remind", #"{"to":"Shirts","text":"x","at":"2020-01-01T09:00:00Z"}"#).0, 400)
    }

    func testDueRules() {
        let made = Date(timeIntervalSince1970: 1000)
        var r = Reminder(id: "r", text: "x", label: "Z", session: "z", created: made)
        r.after = "s"
        XCTAssertFalse(Reminders.isDue(r, now: made + 60) { _ in ("working", made + 30) })
        XCTAssertFalse(Reminders.isDue(r, now: made + 60) { _ in ("idle", made - 30) })        // was idle already
        XCTAssertTrue(Reminders.isDue(r, now: made + 60) { _ in ("idle", made + 30) })
        XCTAssertTrue(Reminders.isDue(r, now: made + 60) { _ in nil })                          // gone
        XCTAssertTrue(Reminders.isDue(r, now: made + 60) { _ in ("stopped", made - 30) })
    }

    func testRemindersSurviveARestart() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("reminders-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        server.remindersFile = file
        XCTAssertEqual(post("/remind", #"{"text":"Kaffee","in":30}"#).0, 200)
        let again = ControlServer(sessions: reg, now: { [clock] in clock.t })
        again.remindersFile = file
        let list = again.handle(HTTPRequest(method: "GET", path: "/remind", body: Data())).1
        XCTAssertTrue(list.contains("Kaffee"), list)
    }
}
