import XCTest
@testable import Parley

final class HTTPParseTests: XCTestCase {
    func testParsesPostWithBody() {
        let body = #"{"a":1}"#
        let raw = "POST /turn HTTP/1.1\r\nHost: x\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let req = HTTPParse.parse(Data(raw.utf8))
        XCTAssertEqual(req?.method, "POST")
        XCTAssertEqual(req?.path, "/turn")
        XCTAssertEqual(req.map { String(data: $0.body, encoding: .utf8) }, body)
    }

    func testReturnsNilUntilBodyComplete() {
        let raw = "POST /turn HTTP/1.1\r\nContent-Length: 10\r\n\r\nshort"
        XCTAssertNil(HTTPParse.parse(Data(raw.utf8)))
    }

    func testGetNoBody() {
        let req = HTTPParse.parse(Data("GET /health HTTP/1.1\r\n\r\n".utf8))
        XCTAssertEqual(req?.method, "GET")
        XCTAssertEqual(req?.path, "/health")
        XCTAssertEqual(req?.body.count, 0)
    }

    func testResponseHasContentLength() {
        let r = HTTPParse.response(status: 200, json: #"{"ok":true}"#)
        let s = String(data: r, encoding: .utf8)!
        XCTAssertTrue(s.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(s.contains("Content-Length: 11\r\n"))
        XCTAssertTrue(s.hasSuffix(#"{"ok":true}"#))
    }
}

final class ContractDecodeTests: XCTestCase {
    func testDecodeTurn() {
        let json = #"{"event":"turn","session_id":"s","cwd":"/tmp/p","project":"p","tmux_pane":"%3","speak":"hi"}"#
        let t = Contract.decodeTurn(Data(json.utf8))
        XCTAssertEqual(t?.speak, "hi")
        XCTAssertEqual(t?.tmux_pane, "%3")
        XCTAssertEqual(t?.project, "p")
    }

    func testDecodeReadyOptionalSession() {
        let json = #"{"event":"ready","cwd":"/tmp/p","project":"p","tmux_pane":""}"#
        let r = Contract.decodeReady(Data(json.utf8))
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.tmux_pane, "")
        XCTAssertNil(r?.session_id)
    }

    func testDecodeBadReturnsNil() {
        XCTAssertNil(Contract.decodeTurn(Data("not json".utf8)))
    }
}

final class TurnQueueTests: XCTestCase {
    private func turn(_ pane: String) -> TurnPayload {
        TurnPayload(event: "turn", session_id: pane, cwd: "/", project: "p", tmux_pane: pane, speak: "x")
    }

    func testFIFOSingleActive() {
        let q = TurnQueue()
        q.enqueue(turn("%1")); q.enqueue(turn("%2")); q.enqueue(turn("%3"))
        XCTAssertEqual(q.pendingCount, 3)

        let a = q.activateNext()
        XCTAssertEqual(a?.tmux_pane, "%1")
        XCTAssertTrue(q.isActive)
        // Busy: second activate is a no-op.
        XCTAssertNil(q.activateNext())
        XCTAssertEqual(q.pendingCount, 2)

        let b = q.complete()
        XCTAssertEqual(b?.tmux_pane, "%2")
        let c = q.complete()
        XCTAssertEqual(c?.tmux_pane, "%3")
        let d = q.complete()
        XCTAssertNil(d)
        XCTAssertFalse(q.isActive)
    }
}

final class ServerHandleTests: XCTestCase {
    func testHealth() {
        let s = ControlServer()
        let (status, body) = s.handle(HTTPRequest(method: "GET", path: "/health", body: Data()))
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body, #"{"ok":true}"#)
    }

    func testTurnFiresCallback() {
        let s = ControlServer()
        var spoken: TurnPayload?
        s.onTurn = { spoken = $0 }
        let json = #"{"event":"turn","session_id":"s","cwd":"/tmp/p","project":"p","tmux_pane":"%9","speak":"hallo"}"#
        let (status, _) = s.handle(HTTPRequest(method: "POST", path: "/turn", body: Data(json.utf8)))
        XCTAssertEqual(status, 200)
        XCTAssertEqual(spoken?.speak, "hallo")
    }

    func testBadTurn400() {
        let s = ControlServer()
        let (status, _) = s.handle(HTTPRequest(method: "POST", path: "/turn", body: Data("x".utf8)))
        XCTAssertEqual(status, 400)
    }

    func testUnknownRoute404() {
        let s = ControlServer()
        let (status, _) = s.handle(HTTPRequest(method: "GET", path: "/nope", body: Data()))
        XCTAssertEqual(status, 404)
    }
}
