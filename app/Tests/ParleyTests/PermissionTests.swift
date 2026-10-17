import XCTest
@testable import Parley

// POST /permission: the spoken question, the keyword decision, the queue + fast paths.
final class PermissionPromptTests: XCTestCase {
    func testKeywordDecisions() {
        let allow = ["Ja", "ja, mach", "Okay.", "Mach's", "Erlaube es", "klar doch", "Kein Problem", "warum nicht",
                     "Yes", "ja bitte", "Genehmigt", "mach halt", "Leg los", "Gib frei", "auf jeden Fall", "passt"]
        let deny = ["Nein", "nein, lass das", "Stopp!", "auf keinen Fall", "lieber nicht", "nicht jetzt",
                    "Ja, aber nicht die Datei", "verbiete das", "no", "nee", "Halt", "abbrechen", "ablehnen bitte"]
        let ask = ["", "hmm", "weiß nicht", "Vielleicht", "ja vielleicht", "keine Ahnung", "bitte?", "was genau?"]
        for t in allow { XCTAssertEqual(PermissionPrompt.decide(t), .allow, t) }
        for t in deny { XCTAssertEqual(PermissionPrompt.decide(t), .deny, t) }
        for t in ask { XCTAssertEqual(PermissionPrompt.decide(t), .ask, t) }
    }

    func testDescriptions() {
        func d(_ tool: String, _ input: [String: String] = [:]) -> String { PermissionPrompt.describe(tool: tool, input: input) }
        XCTAssertEqual(d("Bash", ["command": "npm test"]), "den Befehl npm test ausführen")
        XCTAssertEqual(d("Bash", ["command": "git status\ngit diff"]), "den Befehl git status ausführen")
        XCTAssertEqual(d("Edit", ["file_path": "/a/b/Sessions.swift"]), "die Datei Sessions.swift ändern")
        XCTAssertEqual(d("MultiEdit", ["file_path": "/a/README.md"]), "die Datei README.md ändern")
        XCTAssertEqual(d("Write", ["file_path": "/a/new.txt"]), "die Datei new.txt schreiben")
        XCTAssertEqual(d("Read", ["file_path": "/a/x.swift"]), "die Datei x.swift lesen")
        XCTAssertEqual(d("WebFetch", ["url": "https://example.com/docs?q=1"]), "die Seite example.com abrufen")
        XCTAssertEqual(d("WebSearch", ["query": "swift http2"]), "im Web nach swift http2 suchen")
        XCTAssertEqual(d("Task", ["description": "Tests prüfen"]), "einen Agenten starten: Tests prüfen")
        XCTAssertEqual(d("mcp__github__create_issue"), "das Werkzeug create issue von github benutzen")
        XCTAssertEqual(d("Foo"), "das Werkzeug Foo benutzen")
        XCTAssertEqual(d("Edit"), "eine Datei ändern")
        let long = d("Bash", ["command": String(repeating: "word ", count: 40)])
        XCTAssertTrue(long.hasSuffix(" … ausführen"))
        XCTAssertLessThan(long.count, 110)
    }

    func testQuestion() {
        XCTAssertEqual(PermissionPrompt.question(label: "Tippfrei", tool: "Bash", input: ["command": "npm test"]),
                       "Tippfrei möchte den Befehl npm test ausführen — erlauben?")
    }

    func testDecodeKeepsStringInputs() {
        let body = #"{"session_id":"s","cwd":"/x","tool_name":"Bash","tool_input":{"command":"ls","timeout":5}}"#
        XCTAssertEqual(PermissionRequest.decode(Data(body.utf8)),
                       PermissionRequest(sessionId: "s", cwd: "/x", toolName: "Bash", input: ["command": "ls"]))
        XCTAssertNil(PermissionRequest.decode(Data(#"{"tool_name":"Bash"}"#.utf8)))
        XCTAssertNil(PermissionRequest.decode(Data("x".utf8)))
    }
}

final class PermissionServerTests: XCTestCase {
    private var server: ControlServer!
    private final class Box: @unchecked Sendable { var values: [String] = []; let lock = NSLock()
        func add(_ v: String) { lock.withLock { values.append(v) } }
        var all: [String] { lock.withLock { values } } }

    override func setUp() {
        server = ControlServer(sessions: SessionRegistry(phase: { "idle" }, daily: DailyStats()))
        let presence = #"{"session_id":"a","label":"Tippfrei","cwd":"/x/tippfrei","state":"working"}"#
        _ = server.handle(HTTPRequest(method: "POST", path: "/presence", body: Data(presence.utf8)))
    }

    private func body(_ sid: String) -> Data {
        Data(#"{"session_id":"\#(sid)","cwd":"/x/tippfrei","tool_name":"Bash","tool_input":{"command":"npm test"}}"#.utf8)
    }

    func testUnknownSessionAsksAtOnce() {
        server.replyProvider = { _, _ in XCTFail("an unknown session is never voiced") }
        let got = Box()
        XCTAssertTrue(server.permission(body("stranger")) { got.add($0) })
        XCTAssertEqual(got.all, [#"{"decision":"ask"}"#])
        XCTAssertFalse(server.permission(Data("bad".utf8)) { got.add($0) })
    }

    func testKnownSessionIsAskedAloudAndTheReplyDecides() {
        for (reply, decision) in [("Ja, mach", "allow"), ("Nein", "deny"), ("", "ask")] {
            var asked: TurnPayload?
            server.replyProvider = { turn, done in asked = turn; done(TurnReply(transcript: reply, park: false)) }
            let got = Box()
            let answered = expectation(description: reply)
            XCTAssertTrue(server.permission(body("a")) { got.add($0); answered.fulfill() })
            wait(for: [answered], timeout: 2)
            XCTAssertEqual(asked?.event, ControlServer.permissionEvent)
            XCTAssertEqual(asked?.speak, "Tippfrei möchte den Befehl npm test ausführen — erlauben?")
            XCTAssertEqual(got.all, [#"{"decision":"\#(decision)"}"#])
        }
    }

    // Not asked within the hold (another turn holds the voice): "ask", and the question is
    // dropped from the queue instead of being voiced late.
    func testHoldTimesOutToAskAndDropsTheQuestion() {
        server.permissionHold = 0.1
        final class Held: @unchecked Sendable { var done: ((TurnReply) -> Void)?; var events: [String] = [] }
        let held = Held()
        server.replyProvider = { turn, done in held.events.append(turn.event); held.done = done }
        server.receiveTurn(TurnPayload(event: "turn", session_id: "b", cwd: "/x/b", project: "b", tmux_pane: "", speak: "hi")) { _ in }
        let got = Box()
        let answered = expectation(description: "timeout")
        XCTAssertTrue(server.permission(body("a")) { got.add($0); answered.fulfill() })
        wait(for: [answered], timeout: 2)
        XCTAssertEqual(got.all, [#"{"decision":"ask"}"#])
        held.done?(TurnReply(transcript: "", park: false))                    // the turn ends …
        _ = server.resumableList()
        XCTAssertEqual(held.events, ["turn"])                                 // … and no late question follows
    }

    func testWakeOnlyWhenIdle() {
        final class Seen: @unchecked Sendable { var events: [String] = []; var done: ((TurnReply) -> Void)? }
        let seen = Seen()
        server.replyProvider = { turn, done in seen.events.append(turn.event); seen.done = done }
        server.wakeFromPhone()
        _ = server.resumableList()
        XCTAssertEqual(seen.events, ["wake"])
        server.wakeFromPhone()                                                // busy with the first → ignored
        _ = server.resumableList()
        XCTAssertEqual(seen.events, ["wake"])
        seen.done?(TurnReply(transcript: "", park: false))
        _ = server.resumableList()
        server.wakeFromPhone()
        _ = server.resumableList()
        XCTAssertEqual(seen.events, ["wake", "wake"])
    }
}
