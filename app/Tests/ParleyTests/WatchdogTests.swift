import XCTest
@testable import Parley

// The Wachhund: tool calls from a transcript, the three findings, once per half hour, and the
// dialog that hands the session a hint on "ja".
final class WatchdogTests: XCTestCase {
    private func use(_ id: String, _ command: String) -> String {
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"\#(id)","name":"Bash","input":{"command":"\#(command)"}}]}}"#
    }
    private func result(_ id: String, failed: Bool) -> String {
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","is_error":\#(failed)}]}}"#
    }
    private func lines(_ l: [String]) -> [Data] { l.map { Data($0.utf8) } }
    private let now = Date(timeIntervalSince1970: 100_000)

    func testCallsComeWithTheirResults() {
        let calls = Watchdog.calls(lines([use("a", "npm test"), result("a", failed: true), use("b", "ls"), result("b", failed: false), "junk"]))
        XCTAssertEqual(calls.map(\.label), ["Bash · npm test", "Bash · ls"])
        XCTAssertEqual(calls.map(\.failed), [true, false])
        XCTAssertNotEqual(calls[0].key, calls[1].key)
    }

    func testAFinishedTurnIsNotHanging() {
        let ended = #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Fertig."}]}}"#
        let tool = #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"t","name":"Bash","input":{}}]}}"#
        let result = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t"}]}}"#
        let meta = #"{"type":"last-prompt"}"#
        XCTAssertTrue(Watchdog.turnEnded(lines([tool, result, ended, meta])))
        XCTAssertFalse(Watchdog.turnEnded(lines([ended, tool])))                 // a new step runs
        XCTAssertFalse(Watchdog.turnEnded(lines([tool, result])))                // waiting on its result
        XCTAssertFalse(Watchdog.turnEnded(lines([])))
    }

    func testCirclesFailingAndSilence() {
        var l: [String] = []
        for i in 0..<4 { l += [use("t\(i)", "npm test"), result("t\(i)", failed: false), use("o\(i)", "ls \(i)"), result("o\(i)", failed: false)] }
        let circling = Watchdog.calls(lines(l))
        XCTAssertEqual(Watchdog.check(state: "working", since: now, lastWrite: now, calls: circling, now: now),
                       .circles(times: 4, what: "Bash · npm test"))
        XCTAssertNil(Watchdog.check(state: "idle", since: now, lastWrite: now, calls: circling, now: now))   // only working

        let failing = Watchdog.calls(lines((0..<6).flatMap { [use("f\($0)", "build \($0)"), result("f\($0)", failed: true)] }))
        XCTAssertEqual(Watchdog.check(state: "working", since: now, lastWrite: now, calls: failing, now: now), .failing(times: 6))
        let fiveOfSix = Watchdog.calls(lines((0..<6).flatMap { [use("f\($0)", "build \($0)"), result("f\($0)", failed: $0 > 0)] }))
        XCTAssertNil(Watchdog.check(state: "working", since: now, lastWrite: now, calls: fiveOfSix, now: now))

        let quiet = now.addingTimeInterval(-12 * 60)
        XCTAssertEqual(Watchdog.check(state: "working", since: now.addingTimeInterval(-20 * 60), lastWrite: quiet, calls: [], now: now),
                       .silent(minutes: 12))
        XCTAssertNil(Watchdog.check(state: "working", since: now.addingTimeInterval(-5 * 60), lastWrite: quiet, calls: [], now: now))   // not long enough
    }

    func testOncePerKindPerHalfHourAndTheWords() {
        var memory = WatchdogMemory()
        XCTAssertTrue(memory.shouldReport("s", .failing(times: 6), now: now))
        XCTAssertFalse(memory.shouldReport("s", .failing(times: 6), now: now + 60))
        XCTAssertTrue(memory.shouldReport("s", .silent(minutes: 10), now: now + 60))    // another kind
        XCTAssertTrue(memory.shouldReport("s", .failing(times: 6), now: now + WatchdogMemory.quiet))
        XCTAssertTrue(Watchdog.question(label: "Shirts", .circles(times: 5, what: "Bash · npm test")).contains("5-mal dasselbe: Bash, npm test"))
        XCTAssertTrue(Watchdog.hint(.silent(minutes: 12)).contains("Seit 12 Minuten"))
    }

    func testAYesHandsTheSessionTheHint() throws {
        let reg = SessionRegistry()
        let server = ControlServer(sessions: reg, now: { Date() })
        _ = server.handle(HTTPRequest(method: "POST", path: "/presence",
                                      body: Data(#"{"session_id":"s1","label":"Shirts","cwd":"/p","state":"working"}"#.utf8)))
        var asked: [String] = []
        server.replyProvider = { turn, done in asked.append(turn.speak); done(TurnReply(transcript: "Ja, bitte", park: false)) }
        let delivered = expectation(description: "hint")
        server.watchdog(id: "s1", question: "Wachhund, Sir: …", hint: "Halte inne.")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            let body = server.handle(HTTPRequest(method: "POST", path: "/presence",
                                                 body: Data(#"{"session_id":"s1","label":"Shirts","cwd":"/p","state":"working"}"#.utf8))).1
            XCTAssertTrue(body.contains("Halte inne."), body)
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(asked, ["Wachhund, Sir: …"])
    }
}
