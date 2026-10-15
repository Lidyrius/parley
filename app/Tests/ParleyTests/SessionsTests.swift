import XCTest
@testable import Parley

// Session registry + /presence, /sessions, /resume, /wake — driven with a fake clock and a
// fake active-turn phase so state ageing is deterministic. Today's stats use their own
// DailyStats with the same clock and no persistence (never touches the real stats.json).
final class SessionsTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_760_000_000); var phase = "speaking" }
    private var clock = Clock()
    private var daily: DailyStats!
    private var reg: SessionRegistry!
    private var server: ControlServer!

    override func setUp() {
        clock = Clock()
        let c = clock
        daily = DailyStats(now: { c.t })
        reg = SessionRegistry(now: { c.t }, phase: { c.phase }, daily: daily)
        server = ControlServer(sessions: reg)
    }

    private func advance(_ s: TimeInterval) { clock.t = clock.t.addingTimeInterval(s) }
    private var nowMs: Int64 { Int64(clock.t.timeIntervalSince1970 * 1000) }

    private func post(_ path: String, _ json: String) -> (Int, String) {
        server.handle(HTTPRequest(method: "POST", path: path, body: Data(json.utf8)))
    }

    @discardableResult
    private func presence(_ id: String, _ state: String, label: String = "", usage: String = "null",
                          tasks: String = "[]") -> (Int, String) {
        post("/presence", #"{"session_id":"\#(id)","label":"\#(label)","project":"","cwd":"/Users/x/\#(id)-proj","state":"\#(state)","usage":\#(usage),"tasks":\#(tasks)}"#)
    }

    @discardableResult
    private func wake(_ id: String) -> (Int, String) {
        post("/wake", #"{"session_id":"\#(id)","cwd":"/x/\#(id)","project":"\#(id)","tmux_pane":"","label":""}"#)
    }

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func overview() throws -> [String: Any] {
        let (status, body) = server.handle(HTTPRequest(method: "GET", path: "/sessions", body: Data()))
        XCTAssertEqual(status, 200)
        return try object(body)
    }

    private func sessions() throws -> [[String: Any]] {
        try XCTUnwrap(try overview()["sessions"] as? [[String: Any]])
    }

    private func row(_ id: String) throws -> [String: Any]? {
        try sessions().first { $0["id"] as? String == id }
    }

    private func state(_ id: String) throws -> String? { try row(id)?["state"] as? String }
    private func stats(_ id: String) throws -> [String: Any] { try XCTUnwrap(try row(id)?["stats"] as? [String: Any]) }
    private func today() throws -> [String: Any] { try XCTUnwrap(try overview()["today"] as? [String: Any]) }

    private func reply(_ transcript: String = "", park: Bool = false, wait: Int = 0) -> TurnReply {
        TurnReply(transcript: transcript, park: park, waitSeconds: wait, resume: wait > 0 ? "weiter" : "")
    }

    private func turn(_ id: String, speak: String = "x", _ r: TurnReply) {
        reg.queued(id: id, label: "", project: id)
        reg.activate(id: id, speak: speak)
        reg.finished(id: id, reply: r)
    }

    // MARK: - /presence + /sessions shape

    func testPresenceUpsertAndSessionsShape() throws {
        let (status, body) = presence("a", "working", label: "Parley")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body, "{}")

        var rows = try sessions()
        XCTAssertEqual(rows.count, 1)
        let r = rows[0]
        XCTAssertEqual(Set(r.keys), ["id", "label", "project", "state", "since", "until", "voice", "resumable", "tasks", "stats"])
        XCTAssertEqual((r["tasks"] as? [Any])?.count, 0)
        XCTAssertEqual(r["id"] as? String, "a")
        XCTAssertEqual(r["label"] as? String, "Parley")
        XCTAssertEqual(r["project"] as? String, "a-proj")   // cwd basename when project is empty
        XCTAssertEqual(r["state"] as? String, "working")
        XCTAssertEqual((r["since"] as? NSNumber)?.int64Value, nowMs)
        XCTAssertTrue(r["until"] is NSNull)                  // present, null
        XCTAssertEqual(r["voice"] as? Bool, false)
        XCTAssertEqual(r["resumable"] as? Bool, false)       // working → not resumable
        let s = try XCTUnwrap(r["stats"] as? [String: Any])
        XCTAssertEqual(Set(s.keys), ["startedAt", "contextPercent", "costUsd", "turns", "replies", "lastLine"])
        XCTAssertEqual((s["startedAt"] as? NSNumber)?.int64Value, nowMs)   // no usage → first seen
        XCTAssertTrue(s["contextPercent"] is NSNull)
        XCTAssertTrue(s["costUsd"] is NSNull)
        XCTAssertTrue(s["lastLine"] is NSNull)

        let t = try today()
        XCTAssertEqual(Set(t.keys), ["costUsd", "turns", "spokenSeconds", "rateLimits"])
        XCTAssertEqual(t["costUsd"] as? Double, 0)
        XCTAssertEqual((t["rateLimits"] as? [Any])?.count, 0)

        // Upsert: same id, new state → one row, since moves; an empty label keeps the old one.
        advance(5)
        presence("a", "idle")
        rows = try sessions()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["state"] as? String, "idle")
        XCTAssertEqual(rows[0]["label"] as? String, "Parley")
        XCTAssertEqual((rows[0]["since"] as? NSNumber)?.int64Value, nowMs)
    }

    func testBadPresence400() {
        XCTAssertEqual(post("/presence", "nope").0, 400)
        XCTAssertEqual(post("/presence", #"{"session_id":""}"#).0, 400)
        XCTAssertEqual(post("/presence", #"{"session_id":"old","state":"idle"}"#).0, 200)   // old body, no usage
    }

    // MARK: - precedence

    func testStatePrecedence() throws {
        presence("a", "working")
        XCTAssertEqual(try state("a"), "working")

        turn("a", reply(park: true))                       // parked beats working
        XCTAssertEqual(try state("a"), "parked")

        turn("a", reply(wait: 300))                        // waiting beats parked/working
        let r = try XCTUnwrap(try row("a"))
        XCTAssertEqual(r["state"] as? String, "waiting")
        XCTAssertEqual((r["until"] as? NSNumber)?.int64Value, nowMs + 300_000)

        reg.queued(id: "a", label: "", project: "a")       // queued beats waiting
        XCTAssertEqual(try state("a"), "queued")

        reg.activate(id: "a", speak: "x")                  // the voiced turn beats everything
        clock.phase = "listening"
        let active = try XCTUnwrap(try row("a"))
        XCTAssertEqual(active["state"] as? String, "listening")
        XCTAssertEqual(active["voice"] as? Bool, true)
        clock.phase = "idle"   // e.g. muted/sent between phases → still the voiced turn
        XCTAssertEqual(try state("a"), "speaking")
    }

    func testWaitingEndsAtUntil() throws {
        // No presence (Codex-style): after the wait the hook injects the resume prompt → working.
        turn("c", reply(wait: 120))
        advance(119)
        XCTAssertEqual(try state("c"), "waiting")
        advance(2)
        XCTAssertEqual(try state("c"), "working")
        XCTAssertTrue(try row("c")?["until"] is NSNull)
    }

    func testHookOnlyWorkingThenIdleThenStopped() throws {
        reg.queued(id: "c", label: "", project: "codex-proj")
        reg.activate(id: "c", speak: "x")
        reg.finished(id: "c", reply: reply("mach weiter"))
        XCTAssertEqual(try state("c"), "working")
        XCTAssertEqual(try row("c")?["label"] as? String, "codex-proj")   // label falls back to project

        turn("c", reply())                                 // speak-only turn → idle, not resumable
        XCTAssertEqual(try state("c"), "idle")
        XCTAssertEqual(try row("c")?["resumable"] as? Bool, false)
        advance(301)
        XCTAssertEqual(try state("c"), "stopped")
    }

    // MARK: - stopped + dropped

    func testStoppedAfterSilenceThenDropped() throws {
        presence("a", "idle")
        advance(19)
        XCTAssertEqual(try state("a"), "idle")
        advance(2)
        XCTAssertEqual(try state("a"), "stopped")
        XCTAssertEqual((try row("a")?["since"] as? NSNumber)?.int64Value, nowMs)

        advance(570)   // 10 min after the last presence → still listed
        XCTAssertEqual(try state("a"), "stopped")
        advance(20)
        XCTAssertNil(try state("a"))
        XCTAssertTrue(try sessions().isEmpty)
    }

    func testParkedExpiresWithoutWakePolls() throws {
        presence("a", "idle")
        turn("a", reply(park: true))
        advance(10); presence("a", "idle"); wake("a")
        advance(25); presence("a", "idle")
        XCTAssertEqual(try state("a"), "parked")   // last poll 25 s ago
        advance(6); presence("a", "idle")
        XCTAssertEqual(try state("a"), "idle")     // hook gone → presence decides
    }

    func testSortVoiceFirstAliveByLabelStoppedLast() throws {
        presence("s", "idle", label: "Alpha")
        advance(30)                                  // "s" goes stopped
        presence("z", "idle", label: "Zulu")
        presence("b", "working", label: "bravo")
        reg.queued(id: "v", label: "Yankee", project: "v")
        reg.activate(id: "v", speak: "x")
        XCTAssertEqual(try sessions().map { $0["id"] as? String }, ["v", "b", "z", "s"])
    }

    // MARK: - resumable

    func testResumableFlag() throws {
        presence("idle", "idle")
        presence("busy", "working")
        wake("parked")
        turn("codex", reply())                       // idle without a mod
        XCTAssertEqual(try row("idle")?["resumable"] as? Bool, true)
        XCTAssertEqual(try row("busy")?["resumable"] as? Bool, false)
        XCTAssertEqual(try row("parked")?["resumable"] as? Bool, true)
        XCTAssertEqual(try row("codex")?["resumable"] as? Bool, false)
        XCTAssertEqual(server.resumableList().map(\.id), ["idle", "parked"])
        advance(31)                                  // all signals gone stale
        XCTAssertEqual(try row("idle")?["resumable"] as? Bool, false)
        XCTAssertEqual(try row("parked")?["resumable"] as? Bool, false)
    }

    func testBackgroundStateEchoesTasksAndIsNotResumable() throws {
        let tasks = #"[{"type":"subagent","description":"App: session presence + overview API"}]"#
        presence("bg", "background", tasks: tasks)
        let r = try XCTUnwrap(try row("bg"))
        XCTAssertEqual(r["state"] as? String, "background")
        XCTAssertEqual(r["resumable"] as? Bool, false)
        let echoed = try XCTUnwrap(r["tasks"] as? [[String: Any]])
        XCTAssertEqual(echoed.count, 1)
        XCTAssertEqual(echoed.first?["type"] as? String, "subagent")
        XCTAssertEqual(echoed.first?["description"] as? String, "App: session presence + overview API")
        XCTAssertEqual(post("/resume", #"{"id":"bg"}"#).0, 404)
        XCTAssertTrue(reg.othersAlive(except: "someone-else"))         // alive → announce

        presence("bg", "working")                                        // working beats background
        XCTAssertEqual(try state("bg"), "working")
        XCTAssertEqual((try row("bg")?["tasks"] as? [Any])?.count, 0)   // absent/empty → []
        presence("bg", "idle")
        XCTAssertEqual(try state("bg"), "idle")
    }

    // MARK: - /wake + /resume

    func testWakeIdentifiesSessionWithoutTurnFields() throws {
        // The hook's /wake payload has no `event`/`speak`; it must still key by session_id.
        let (status, body) = wake("p")
        XCTAssertEqual(status, 200)
        XCTAssertTrue(body.contains(#""transcript":"""#))
        XCTAssertEqual(try state("p"), "parked")
        XCTAssertEqual(server.resumableList().map(\.label), ["p"])
    }

    func testResumeNotResumable404() throws {
        presence("busy", "working")
        turn("codex", reply())
        XCTAssertEqual(post("/resume", #"{"id":"busy"}"#).0, 404)
        XCTAssertEqual(post("/resume", #"{"id":"codex"}"#).0, 404)     // idle, but no mod to deliver to
        XCTAssertEqual(post("/resume", #"{"id":"unknown"}"#).1, #"{"ok":false}"#)
        XCTAssertEqual(post("/resume", "garbage").0, 404)
    }

    func testResumeParkedWakesHook() throws {
        wake("p")
        XCTAssertEqual(post("/resume", #"{"id":"p"}"#).1, #"{"ok":true}"#)
        // No pipeline wired → the dialog answers empty → the default instruction.
        XCTAssertEqual(try state("p"), "working")
        let next = try object(wake("p").1)
        XCTAssertEqual(next["transcript"] as? String, "Wir machen weiter.")
        XCTAssertEqual(post("/resume", #"{"id":"p"}"#).0, 404)        // working now
    }

    func testResumeRightAfterParkReplyBeforeFirstPoll() throws {
        turn("p", reply(park: true))
        XCTAssertEqual(post("/resume", #"{"id":"p"}"#).0, 200)
        XCTAssertTrue(wake("p").1.contains("Wir machen weiter."))
    }

    func testResumeIdleStoresInstructionForNextPresenceOnce() throws {
        presence("a", "idle", label: "Demo")
        XCTAssertEqual(post("/resume", #"{"id":"a"}"#).0, 200)
        XCTAssertEqual(try state("a"), "working")                       // instruction on its way
        XCTAssertEqual(try row("a")?["resumable"] as? Bool, false)

        let first = presence("a", "idle")
        XCTAssertEqual(try object(first.1)["instruction"] as? String, "Wir machen weiter.")
        XCTAssertEqual(presence("a", "idle").1, "{}")                   // exactly once
        XCTAssertEqual(try state("a"), "working")                       // landed, mod not busy yet
        presence("a", "working")
        presence("a", "idle")
        XCTAssertEqual(try state("a"), "idle")                          // done → idle again
    }

    func testResumeDialogRunsThroughQueueAndDeliversTranscript() throws {
        presence("a", "idle", label: "Demo")
        var dialog: TurnPayload?
        var finish: ((TurnReply) -> Void)?
        server.replyProvider = { turn, done in dialog = turn; finish = done }

        XCTAssertEqual(post("/resume", #"{"id":"a"}"#).0, 200)           // answered at once
        XCTAssertEqual(dialog?.event, ControlServer.resumeEvent)
        XCTAssertEqual(dialog?.spokenLabel, "Demo")
        let during = try XCTUnwrap(try row("a"))
        XCTAssertEqual(during["voice"] as? Bool, true)
        XCTAssertEqual(during["state"] as? String, "speaking")
        XCTAssertEqual((try stats("a")["turns"] as? Int), 0)            // a dialog isn't a voiced turn

        finish?(TurnReply(transcript: "Mach die Tests grün", park: false))
        _ = server.resumableList()                                       // barrier: server queue drained
        XCTAssertEqual(try object(presence("a", "idle").1)["instruction"] as? String, "Mach die Tests grün")
        XCTAssertEqual(try stats("a")["replies"] as? Int, 1)
        XCTAssertEqual(try row("a")?["voice"] as? Bool, false)
    }

    // MARK: - per-session stats + today

    func testTurnsRepliesLastLine() throws {
        presence("a", "idle")
        turn("a", speak: "Erste Zeile", reply("ja"))
        turn("a", speak: "Zweite Zeile", reply())
        let s = try stats("a")
        XCTAssertEqual(s["turns"] as? Int, 2)
        XCTAssertEqual(s["replies"] as? Int, 1)
        XCTAssertEqual(s["lastLine"] as? String, "Zweite Zeile")
    }

    func testUsageFeedsStatsAndTodayCost() throws {
        let startedToday = Int64((clock.t.timeIntervalSince1970 - 60) * 1000)
        let startedLastWeek = Int64((clock.t.timeIntervalSince1970 - 7 * 86_400) * 1000)
        let limits = #"[{"kind":"five_hour","percentUsed":42,"resetsAt":null}]"#
        presence("a", "working", usage: #"{"startedAt":\#(startedToday),"contextPercent":37.5,"costUsd":0.10,"rateLimits":\#(limits)}"#)
        var s = try stats("a")
        XCTAssertEqual((s["startedAt"] as? NSNumber)?.int64Value, startedToday)
        XCTAssertEqual(s["contextPercent"] as? Double, 37.5)
        XCTAssertEqual(s["costUsd"] as? Double, 0.10)
        XCTAssertEqual(try today()["costUsd"] as? Double, 0.10)          // new today → counts in full

        presence("a", "working", usage: #"{"costUsd":0.25}"#)           // +0.15
        presence("a", "working", usage: #"{"costUsd":0.25}"#)           // no change
        // A session from last week: its first report is only a baseline.
        presence("b", "working", usage: #"{"startedAt":\#(startedLastWeek),"costUsd":3.0}"#)
        XCTAssertEqual(try today()["costUsd"] as? Double, 0.25)
        presence("b", "working", usage: #"{"costUsd":3.5}"#)            // +0.5
        XCTAssertEqual(try today()["costUsd"] as? Double, 0.75)

        s = try stats("a")
        XCTAssertEqual(s["costUsd"] as? Double, 0.25)
        XCTAssertEqual(s["contextPercent"] as? Double, 37.5)            // kept when not re-sent
        let rl = try XCTUnwrap(try today()["rateLimits"] as? [[String: Any]])
        XCTAssertEqual(rl.first?["kind"] as? String, "five_hour")
        XCTAssertEqual(rl.first?["percentUsed"] as? Double, 42)
        XCTAssertTrue(rl.first?["resetsAt"] is NSNull)
    }

    func testTodayResetsAtLocalMidnight() throws {
        clock.t = Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: clock.t)!
        let started = Int64((clock.t.timeIntervalSince1970 - 3600) * 1000)
        presence("a", "working", usage: #"{"startedAt":\#(started),"costUsd":1.0}"#)
        daily.recordTurn(spokenSeconds: 4.4)
        var t = try today()
        XCTAssertEqual(t["costUsd"] as? Double, 1.0)
        XCTAssertEqual(t["turns"] as? Int, 1)
        XCTAssertEqual(t["spokenSeconds"] as? Int, 4)

        advance(120)                                                     // 00:01 next day
        t = try today()
        XCTAssertEqual(t["costUsd"] as? Double, 0)
        XCTAssertEqual(t["turns"] as? Int, 0)
        presence("a", "working", usage: #"{"costUsd":1.4}"#)            // baseline survived the rollover
        XCTAssertEqual(try today()["costUsd"] as? Double, 0.4)
    }

    func testStatsFileStaysBackwardCompatible() throws {
        // An existing stats.json (no "today") still decodes; a new one round-trips its day.
        let old = #"{"turns":3,"charsSpoken":10,"parleyWords":2,"userWords":1,"userSpeakingSeconds":1,"timeSavedSeconds":0,"activeSeconds":0,"sessions":1,"intents":{},"projectTurns":{},"charMonth":"2026-10","charsThisMonth":10}"#
        let decoded = try JSONDecoder().decode(StatsData.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.turns, 3)
        XCTAssertNil(decoded.today)

        var file = decoded
        file.today = DayStats(day: "2026-10-15", turns: 2, spokenSeconds: 3, costUsd: 0.5,
                              costSeen: ["a": .init(cost: 0.5, at: 1)])
        let again = try JSONDecoder().decode(StatsData.self, from: JSONEncoder().encode(file))
        XCTAssertEqual(again.today, file.today)
    }

    // MARK: - announcement condition

    func testOthersAliveDecidesAnnouncement() {
        reg.queued(id: "me", label: "", project: "me")
        reg.activate(id: "me", speak: "x")
        XCTAssertFalse(reg.othersAlive(except: "me"))        // alone

        presence("other", "idle")
        XCTAssertTrue(reg.othersAlive(except: "me"))         // another session idle → announce

        advance(21)                                          // other went stopped
        XCTAssertFalse(reg.othersAlive(except: "me"))

        wake("parked")                                       // a parked one counts too
        XCTAssertTrue(reg.othersAlive(except: "me"))
    }

    func testAnnouncementAndResumePhrases() {
        XCTAssertEqual(ProjectClips.phrase(name: "Parley", language: "Deutsch"), "Update zu Parley")
        XCTAssertEqual(ProjectClips.phrase(name: "Parley", language: "English"), "Update on Parley")
        XCTAssertEqual(ProjectClips.phrase(name: "Parley", language: "Klingonisch"), "Update zu Parley")
        let de = ProjectClips.resumePhrases(name: "Demo", language: "Deutsch")
        XCTAssertEqual(de.count, 3)
        XCTAssertEqual(de[0], "Ich habe die Arbeit an Demo wieder aufgenommen. Wie kann ich Ihnen helfen, Sir?")
        for language in ["English", "Français", "Español", "Italiano", "Nederlands"] {
            XCTAssertEqual(ProjectClips.resumePhrases(name: "Demo", language: language).filter { $0.contains("Demo") }.count, 3)
        }
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
        let server = ControlServer(port: port, sessions: SessionRegistry(phase: { "listening" }, daily: DailyStats()))
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
        XCTAssertEqual((rows.first?["stats"] as? [String: Any])?["lastLine"] as? String, "hi")

        _ = try await call(port, "POST", "/wake", #"{"session_id":"s2","cwd":"/x/b","project":"b","tmux_pane":"","label":""}"#)
        list = try await call(port, "GET", "/sessions")
        rows = try XCTUnwrap(list["sessions"] as? [[String: Any]])
        XCTAssertEqual(rows.first { $0["id"] as? String == "s2" }?["state"] as? String, "parked")
        let resumed = try await call(port, "POST", "/resume", #"{"id":"s2"}"#)
        XCTAssertEqual(resumed["ok"] as? Bool, true)
        // The dialog (here: the stub pipeline answering "weiter so") wakes the parked hook.
        var woke = ""
        for _ in 0..<20 where woke.isEmpty {
            woke = try await call(port, "POST", "/wake", #"{"session_id":"s2","cwd":"/x/b","project":"b","tmux_pane":"","label":""}"#)["transcript"] as? String ?? ""
            if woke.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        XCTAssertEqual(woke, "weiter so")
    }
}
