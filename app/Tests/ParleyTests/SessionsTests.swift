import XCTest
@testable import Parley

// Session registry + /presence, /sessions, /resume, /wake — driven with a fake clock and a
// fake active-turn phase so state ageing is deterministic.
final class SessionsTests: XCTestCase {
    private final class Clock { var t = Date(timeIntervalSince1970: 1_760_000_000); var phase = "speaking" }
    private var clock = Clock()
    private var reg: SessionRegistry!
    private var server: ControlServer!

    override func setUp() {
        clock = Clock()
        let c = clock
        reg = SessionRegistry(now: { c.t }, phase: { c.phase })
        server = ControlServer(sessions: reg)
    }

    private func advance(_ s: TimeInterval) { clock.t = clock.t.addingTimeInterval(s) }
    private var nowMs: Int64 { Int64(clock.t.timeIntervalSince1970 * 1000) }

    private func post(_ path: String, _ json: String) -> (Int, String) {
        server.handle(HTTPRequest(method: "POST", path: path, body: Data(json.utf8)))
    }

    private func presence(_ id: String, _ state: String, label: String = "") -> (Int, String) {
        post("/presence", #"{"session_id":"\#(id)","label":"\#(label)","project":"","cwd":"/Users/x/\#(id)-proj","state":"\#(state)"}"#)
    }

    private func wake(_ id: String) -> (Int, String) {
        post("/wake", #"{"session_id":"\#(id)","cwd":"/x/\#(id)","project":"\#(id)","tmux_pane":"","label":""}"#)
    }

    private func sessions() throws -> [[String: Any]] {
        let (status, body) = server.handle(HTTPRequest(method: "GET", path: "/sessions", body: Data()))
        XCTAssertEqual(status, 200)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        return try XCTUnwrap(obj["sessions"] as? [[String: Any]])
    }

    private func state(_ id: String) throws -> String? {
        try sessions().first { $0["id"] as? String == id }?["state"] as? String
    }

    private func reply(_ transcript: String = "", park: Bool = false, wait: Int = 0) -> TurnReply {
        TurnReply(transcript: transcript, park: park, waitSeconds: wait, resume: wait > 0 ? "weiter" : "")
    }

    // MARK: - /presence + /sessions shape

    func testPresenceUpsertAndSessionsShape() throws {
        let (status, body) = presence("a", "working", label: "Parley")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body, "{}")

        var rows = try sessions()
        XCTAssertEqual(rows.count, 1)
        let r = rows[0]
        XCTAssertEqual(Set(r.keys), ["id", "label", "project", "state", "since", "until", "voice"])
        XCTAssertEqual(r["id"] as? String, "a")
        XCTAssertEqual(r["label"] as? String, "Parley")
        XCTAssertEqual(r["project"] as? String, "a-proj")   // cwd basename when project is empty
        XCTAssertEqual(r["state"] as? String, "working")
        XCTAssertEqual((r["since"] as? NSNumber)?.int64Value, nowMs)
        XCTAssertTrue(r["until"] is NSNull)                  // present, null
        XCTAssertEqual(r["voice"] as? Bool, false)

        // Upsert: same id, new state → one row, since moves; an empty label keeps the old one.
        advance(5)
        _ = presence("a", "idle")
        rows = try sessions()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["state"] as? String, "idle")
        XCTAssertEqual(rows[0]["label"] as? String, "Parley")
        XCTAssertEqual((rows[0]["since"] as? NSNumber)?.int64Value, nowMs)
    }

    func testBadPresence400() {
        XCTAssertEqual(post("/presence", "nope").0, 400)
        XCTAssertEqual(post("/presence", #"{"session_id":""}"#).0, 400)
    }

    // MARK: - precedence

    func testStatePrecedence() throws {
        _ = presence("a", "working")
        XCTAssertEqual(try state("a"), "working")

        // parked beats working
        reg.queued(id: "a", label: "", project: "a")
        reg.activate(id: "a")
        reg.finished(id: "a", reply: reply(park: true))
        XCTAssertEqual(try state("a"), "parked")

        // waiting beats parked/working; `until` is set while waiting
        reg.queued(id: "a", label: "", project: "a")
        reg.activate(id: "a")
        reg.finished(id: "a", reply: reply(wait: 300))
        let rows = try sessions()
        XCTAssertEqual(rows[0]["state"] as? String, "waiting")
        XCTAssertEqual((rows[0]["until"] as? NSNumber)?.int64Value, nowMs + 300_000)

        // queued beats waiting
        reg.queued(id: "a", label: "", project: "a")
        XCTAssertEqual(try state("a"), "queued")

        // active phase beats everything, and that session holds the voice
        reg.activate(id: "a")
        clock.phase = "listening"
        let active = try sessions()[0]
        XCTAssertEqual(active["state"] as? String, "listening")
        XCTAssertEqual(active["voice"] as? Bool, true)
        clock.phase = "idle"   // e.g. muted/sent between phases → still the voiced turn
        XCTAssertEqual(try state("a"), "speaking")
    }

    func testWaitingEndsAtUntil() throws {
        // No presence (Codex-style): after the wait the hook injects the resume prompt → working.
        reg.queued(id: "c", label: "", project: "c")
        reg.activate(id: "c")
        reg.finished(id: "c", reply: reply(wait: 120))
        advance(119)
        XCTAssertEqual(try state("c"), "waiting")
        advance(2)
        XCTAssertEqual(try state("c"), "working")
        let row = try sessions()[0]
        XCTAssertTrue(row["until"] is NSNull)
    }

    func testHookOnlyWorkingThenIdleThenStopped() throws {
        reg.queued(id: "c", label: "", project: "codex-proj")
        reg.activate(id: "c")
        reg.finished(id: "c", reply: reply("mach weiter"))
        XCTAssertEqual(try state("c"), "working")
        XCTAssertEqual(try sessions()[0]["label"] as? String, "codex-proj")   // label falls back to project

        // Speak-only turn (no transcript) → idle until 5 min of hook silence.
        reg.queued(id: "c", label: "", project: "codex-proj")
        reg.activate(id: "c")
        reg.finished(id: "c", reply: reply())
        XCTAssertEqual(try state("c"), "idle")
        advance(301)
        XCTAssertEqual(try state("c"), "stopped")
    }

    // MARK: - stopped + dropped

    func testStoppedAfterSilenceThenDropped() throws {
        _ = presence("a", "idle")
        let started = nowMs
        advance(19)
        XCTAssertEqual(try state("a"), "idle")
        advance(2)
        XCTAssertEqual(try state("a"), "stopped")
        let row = try sessions()[0]
        XCTAssertEqual((row["since"] as? NSNumber)?.int64Value, nowMs)
        XCTAssertGreaterThan(nowMs, started)

        advance(570)   // 10 min after the last presence → still listed
        XCTAssertEqual(try state("a"), "stopped")
        advance(20)
        XCTAssertNil(try state("a"))
        XCTAssertTrue(try sessions().isEmpty)
    }

    func testParkedExpiresWithoutWakePolls() throws {
        _ = presence("a", "idle")
        reg.queued(id: "a", label: "", project: "a")
        reg.activate(id: "a")
        reg.finished(id: "a", reply: reply(park: true))
        advance(10); _ = presence("a", "idle"); _ = wake("a")
        advance(25); _ = presence("a", "idle")
        XCTAssertEqual(try state("a"), "parked")   // last poll 25 s ago
        advance(6); _ = presence("a", "idle")
        XCTAssertEqual(try state("a"), "idle")     // hook gone → presence decides
    }

    func testSortVoiceFirstAliveByLabelStoppedLast() throws {
        _ = presence("s", "idle", label: "Alpha")
        advance(30)                                  // "s" goes stopped
        _ = presence("z", "idle", label: "Zulu")
        _ = presence("b", "working", label: "bravo")
        reg.queued(id: "v", label: "Yankee", project: "v")
        reg.activate(id: "v")
        let ids = try sessions().map { $0["id"] as? String }
        XCTAssertEqual(ids, ["v", "b", "z", "s"])
    }

    // MARK: - /wake + /resume

    func testWakeIdentifiesSessionWithoutTurnFields() throws {
        // The hook's /wake payload has no `event`/`speak`; it must still key by session_id.
        let (status, body) = wake("p")
        XCTAssertEqual(status, 200)
        XCTAssertTrue(body.contains(#""transcript":"""#))
        XCTAssertEqual(try state("p"), "parked")
        XCTAssertEqual(server.parkedList().map(\.id), ["p"])
        XCTAssertEqual(server.parkedList().map(\.label), ["p"])
    }

    func testResumeParkedVersusNotParked() throws {
        _ = presence("idle", "idle")
        XCTAssertEqual(post("/resume", #"{"id":"idle"}"#).0, 404)
        XCTAssertEqual(post("/resume", #"{"id":"unknown"}"#).1, #"{"ok":false}"#)
        XCTAssertEqual(post("/resume", "garbage").0, 404)

        _ = wake("p")
        let (status, body) = post("/resume", #"{"id":"p"}"#)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body, #"{"ok":true}"#)

        // The hook's next poll gets the tray instruction and the session goes back to work.
        let (_, wakeBody) = wake("p")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(wakeBody.utf8)) as? [String: Any])
        XCTAssertEqual(obj["transcript"] as? String, "Wir machen weiter.")
        XCTAssertEqual(try state("p"), "working")
        XCTAssertEqual(post("/resume", #"{"id":"p"}"#).0, 404)   // no longer parked
    }

    func testResumeRightAfterParkReplyBeforeFirstPoll() throws {
        reg.queued(id: "p", label: "", project: "p")
        reg.activate(id: "p")
        reg.finished(id: "p", reply: reply(park: true))
        XCTAssertEqual(post("/resume", #"{"id":"p"}"#).0, 200)
        let (_, wakeBody) = wake("p")
        XCTAssertTrue(wakeBody.contains("Wir machen weiter."))
    }

    // MARK: - announcement condition

    func testOthersAliveDecidesAnnouncement() {
        reg.queued(id: "me", label: "", project: "me")
        reg.activate(id: "me")
        XCTAssertFalse(reg.othersAlive(except: "me"))        // alone

        _ = presence("other", "idle")
        XCTAssertTrue(reg.othersAlive(except: "me"))         // another session idle → announce

        advance(21)                                          // other went stopped
        XCTAssertFalse(reg.othersAlive(except: "me"))

        _ = wake("parked")                                   // a parked one counts too
        XCTAssertTrue(reg.othersAlive(except: "me"))
    }

    func testAnnouncementPhrase() {
        XCTAssertEqual(ProjectClips.phrase(name: "Parley", language: "Deutsch"), "Update zu Parley")
        XCTAssertEqual(ProjectClips.phrase(name: "Parley", language: "English"), "Update on Parley")
        XCTAssertEqual(ProjectClips.phrase(name: "Parley", language: "Klingonisch"), "Update zu Parley")
    }
}

// End to end over a real loopback socket: /turn → queued/active → reply → state; /wake.
final class SessionsLoopbackTests: XCTestCase {
    private func call(_ port: UInt16, _ method: String, _ path: String, _ json: String = "") async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.httpMethod = method
        if !json.isEmpty { req.httpBody = Data(json.utf8) }
        for attempt in 0..<20 {   // the listener comes up asynchronously
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            } catch where attempt < 19 { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        throw URLError(.cannotConnectToHost)
    }

    func testTurnAndWakeOverHTTP() async throws {
        let port = UInt16.random(in: 40_000...60_000)
        let server = ControlServer(port: port, sessions: SessionRegistry(phase: { "listening" }))
        server.replyProvider = { _, done in done(TurnReply(transcript: "weiter so", park: false)) }
        server.start()

        let turn = #"{"event":"turn","session_id":"s1","cwd":"/x/proj","project":"proj","tmux_pane":"","speak":"hi","label":"Projekt"}"#
        let reply = try await call(port, "POST", "/turn", turn)
        XCTAssertEqual(reply["transcript"] as? String, "weiter so")

        var list = try await call(port, "GET", "/sessions")
        var rows = try XCTUnwrap(list["sessions"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["id"] as? String, "s1")
        XCTAssertEqual(rows.first?["label"] as? String, "Projekt")
        XCTAssertEqual(rows.first?["state"] as? String, "working")   // transcript injected, no presence
        XCTAssertEqual(rows.first?["voice"] as? Bool, false)

        _ = try await call(port, "POST", "/wake", #"{"session_id":"s2","cwd":"/x/b","project":"b","tmux_pane":"","label":""}"#)
        list = try await call(port, "GET", "/sessions")
        rows = try XCTUnwrap(list["sessions"] as? [[String: Any]])
        XCTAssertEqual(rows.first { $0["id"] as? String == "s2" }?["state"] as? String, "parked")
        let resumed = try await call(port, "POST", "/resume", #"{"id":"s2"}"#)
        XCTAssertEqual(resumed["ok"] as? Bool, true)
    }
}
