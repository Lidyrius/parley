import XCTest
@testable import Parley

// Remote Control's catch-up: the state file read, the decision (idle, nothing of Parley's
// running), the dialog check, and one try per session id.
final class RemoteControlTests: XCTestCase {
    private final class Tries: @unchecked Sendable { var list: [(String, Int32)] = [] }

    func testStateFileIsReadBySessionId() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"pid":11,"sessionId":"a","cwd":"/x","status":"idle"}"#.write(to: dir.appendingPathComponent("11.json"), atomically: true, encoding: .utf8)
        try #"{"pid":12,"sessionId":"b","cwd":"/y","status":"busy","bridgeSessionId":"session_01X"}"#.write(to: dir.appendingPathComponent("12.json"), atomically: true, encoding: .utf8)
        try "not json".write(to: dir.appendingPathComponent("13.json"), atomically: true, encoding: .utf8)
        let a = try XCTUnwrap(RemoteControl.state(of: "a", dir: dir))
        XCTAssertEqual(a.pid, 11)
        XCTAssertFalse(a.connected)
        XCTAssertTrue(try XCTUnwrap(RemoteControl.state(of: "b", dir: dir)).connected)
        XCTAssertNil(RemoteControl.state(of: "c", dir: dir))
    }

    func testDecideTypesOnlyIntoAnIdleSessionParleyHoldsNothingFor() {
        let idle = RemoteControl.State(pid: 7, sessionId: "a", status: "idle", bridgeSessionId: nil)
        XCTAssertEqual(RemoteControl.decide(idle, parley: "parked"), .type(pid: 7))
        XCTAssertEqual(RemoteControl.decide(nil, parley: "parked"), .later)
        for s in ["speaking", "listening", "transcribing", "queued", "waiting", "working", nil] {
            XCTAssertEqual(RemoteControl.decide(idle, parley: s), .later, "\(s ?? "unknown")")
        }
        for st in ["busy", "waiting", "shell", nil] {
            XCTAssertEqual(RemoteControl.decide(.init(pid: 7, sessionId: "a", status: st, bridgeSessionId: nil), parley: "parked"), .later)
        }
        let on = RemoteControl.State(pid: 7, sessionId: "a", status: "busy", bridgeSessionId: "session_01X")
        XCTAssertEqual(RemoteControl.decide(on, parley: "working"), .done)
    }

    func testEnableMustBeTheSelectedOption() {
        XCTAssertTrue(RemoteControl.enableSelected("Remote Control\n\n ❯ 1. Enable Remote Control\n   2. Never mind\n"))
        XCTAssertFalse(RemoteControl.enableSelected("   1. Enable Remote Control\n ❯ 2. Never mind\n"))
        XCTAssertFalse(RemoteControl.enableSelected("> /remote-control\n"))
    }

    func testOneTryPerSessionAndNoneWhenOff() {
        let reg = SessionRegistry(phase: { "speaking" })
        let server = ControlServer(sessions: reg)
        let tries = Tries()
        var state = RemoteControl.State(pid: 9, sessionId: "a", status: "busy", bridgeSessionId: nil)
        var on = true
        server.remoteOn = { on }
        server.remoteState = { $0 == "a" ? state : nil }
        server.remoteCatchUp = { id, _, pid in tries.list.append((id, pid)) }
        func presence(_ id: String) {
            _ = server.handle(HTTPRequest(method: "POST", path: "/presence", body: Data(#"{"session_id":"\#(id)","cwd":"/x","state":"idle"}"#.utf8)))
        }
        presence("a")                       // Claude Code still busy: not yet
        XCTAssertTrue(tries.list.isEmpty)
        state.status = "idle"
        on = false
        presence("a")                       // switched off
        XCTAssertTrue(tries.list.isEmpty)
        on = true
        presence("a"); presence("a"); presence("a")
        XCTAssertEqual(tries.list.map(\.0), ["a"])
        XCTAssertEqual(tries.list.first?.1, 9)
        presence("b")                       // no state file: nothing
        XCTAssertEqual(tries.list.count, 1)
    }
}
