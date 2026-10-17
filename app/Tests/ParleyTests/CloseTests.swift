import XCTest
@testable import Parley

// POST /close: by id / ids / project, the Zentrale refused, unknown + stopped ids, the state
// afterwards, and how SessionCloser finds a session's claude process.
final class CloseTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_760_000_000) }
    private var clock = Clock()
    private var reg: SessionRegistry!
    private var server: ControlServer!
    private var closes: [String] = []
    private var refuse: String?

    override func setUp() {
        clock = Clock()
        let c = clock
        reg = SessionRegistry(now: { c.t }, phase: { "idle" }, daily: DailyStats(now: { c.t }))
        server = ControlServer(sessions: reg, now: { c.t })
        closes = []
        refuse = nil
        server.closer = { [unowned self] id, _ in
            if let why = self.refuse { return why }
            self.closes.append(id)
            return nil
        }
        server.zentraleDir = { "/z/parley-zentrale" }
        presence("a1", "Literally Apps", "/p/literally-apps.id")
        presence("b2", "Shirts", "/p/shirts")
        presence("b3", "Shirts", "/p/shirts")
        presence("z", "Zentrale", "/z/parley-zentrale")
    }

    @discardableResult
    private func post(_ path: String, _ json: String) -> (Int, String) {
        server.handle(HTTPRequest(method: "POST", path: path, body: Data(json.utf8)))
    }

    private func presence(_ id: String, _ label: String, _ cwd: String) {
        post("/presence", #"{"session_id":"\#(id)","label":"\#(label)","cwd":"\#(cwd)","state":"idle"}"#)
    }

    private func json(_ s: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
    }

    func testClosesOneByIdAndItShowsStopped() throws {
        let (code, body) = post("/close", #"{"id":"a1"}"#)
        XCTAssertEqual(code, 200)
        let o = try json(body)
        XCTAssertEqual(o["ok"] as? Bool, true)
        XCTAssertEqual(o["closed"] as? [[String: String]], [["id": "a1", "label": "Literally Apps"]])
        XCTAssertEqual((o["failed"] as? [Any])?.count, 0)
        XCTAssertEqual(closes, ["a1"])
        XCTAssertEqual(reg.info("a1")?.state, "stopped")
        XCTAssertFalse(reg.knows("a1"))
        // Closing it again: already stopped, nothing killed twice.
        XCTAssertEqual(post("/close", #"{"id":"a1"}"#).0, 409)
        XCTAssertEqual(closes, ["a1"])
    }

    func testUnknownIdIs404() throws {
        let (code, body) = post("/close", #"{"id":"nope"}"#)
        XCTAssertEqual(code, 404)
        XCTAssertEqual(try json(body)["ok"] as? Bool, false)
        XCTAssertTrue(closes.isEmpty)
    }

    func testTheZentraleNeverClosesItselfByLabelOrFolder() throws {
        XCTAssertEqual(post("/close", #"{"id":"z"}"#).0, 403)
        presence("z2", "Hauptquartier", "/z/parley-zentrale")   // renamed, same folder
        XCTAssertEqual(post("/close", #"{"id":"z2"}"#).0, 403)
        XCTAssertTrue(closes.isEmpty)
        XCTAssertEqual(post("/close", #"{"project":"zentrale"}"#).0, 403)
    }

    func testByProjectClosesEveryRunningOneOfIt() throws {
        let (code, body) = post("/close", #"{"project":"shirts"}"#)
        XCTAssertEqual(code, 200)
        XCTAssertEqual(closes, ["b2", "b3"])
        XCTAssertEqual((try json(body)["closed"] as? [Any])?.count, 2)
        XCTAssertEqual(post("/close", #"{"project":"shirts"}"#).0, 404)   // none running any more
        XCTAssertEqual(post("/close", #"{"project":"literally-apps.id"}"#).0, 200)   // folder name works too
    }

    func testSeveralIdsReportEachOne() throws {
        let (code, body) = post("/close", #"{"ids":["a1","z","nope","a1"]}"#)
        XCTAssertEqual(code, 200)
        let o = try json(body)
        XCTAssertEqual(o["ok"] as? Bool, false)
        XCTAssertEqual(closes, ["a1"])
        XCTAssertEqual((o["failed"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["z", "nope"])
    }

    func testAProcessThatCannotBeClosedStaysRunning() throws {
        refuse = "not a terminal session"
        let (code, body) = post("/close", #"{"id":"a1"}"#)
        XCTAssertEqual(code, 409)
        XCTAssertTrue(body.contains("not a terminal session"))
        XCTAssertNotEqual(reg.info("a1")?.state, "stopped")
    }

    func testBadPayloads() {
        XCTAssertEqual(post("/close", "nope").0, 400)
        XCTAssertEqual(post("/close", "{}").0, 400)
    }

    func testTheDyingModsLastPresenceIsIgnoredALaterOneRevives() {
        post("/close", #"{"id":"a1"}"#)
        clock.t += 2
        presence("a1", "Literally Apps", "/p/literally-apps.id")
        XCTAssertEqual(reg.info("a1")?.state, "stopped")
        clock.t += SessionRegistry.presenceTTL
        presence("a1", "Literally Apps", "/p/literally-apps.id")   // still alive: the kill did not take
        XCTAssertEqual(reg.info("a1")?.state, "idle")
    }

    // MARK: - finding the process

    private let procs = [
        SessionCloser.Proc(pid: 10, tty: "ttys001", args: "claude --resume aaaa /parley:voice"),
        SessionCloser.Proc(pid: 11, tty: "ttys002", args: "claude /parley:voice"),
        SessionCloser.Proc(pid: 12, tty: "??", args: "/Applications/x/claude --output-format stream-json --resume=dddd"),
        SessionCloser.Proc(pid: 13, tty: "ttys003", args: "claude"),
    ]

    func testPicksByClaimThenArgumentsThenTheOnlyOneInTheFolder() {
        let claimed: [Int32: String] = [13: "cccc"]
        let cwds: [Int32: String] = [10: "/p/a", 11: "/p/b", 13: "/p/b"]
        func pick(_ id: String, _ cwd: String) -> Int32? {
            SessionCloser.pick(id: id, cwd: cwd, procs: procs, claimed: claimed, cwds: cwds)?.pid
        }
        XCTAssertEqual(pick("cccc", "/p/b"), 13)
        XCTAssertEqual(pick("aaaa", "/p/elsewhere"), 10)
        XCTAssertEqual(pick("dddd", ""), 12)        // found; close() then refuses it (no terminal)
        XCTAssertEqual(pick("bbbb", "/p/b"), 11)    // 13 in /p/b belongs to cccc
        XCTAssertNil(pick("eeee", "/p/none"))
        XCTAssertNil(SessionCloser.pick(id: "bbbb", cwd: "/p/b", procs: procs, claimed: [:], cwds: cwds))   // two candidates: unsure
    }

    func testOnlyClaudeItselfCountsNotAGrepForTheId() {
        let ps = """
          91480 ttys023  claude --resume aaaa /parley:voice
          47710 ttys022  claude /parley:voice
          64946 ??       /Users/s/Library/Application Support/Claude/claude-code/2.1.299/x/claude.app/Contents/MacOS/claude --output-format stream-json --resume=dddd
          50950 ??       /Users/s/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude --bg-pty-host /tmp/x.sock -- --session-id ffff
           9608 ??       ugrep -G --hidden aaaa
           9605 ??       /bin/zsh -c ps | grep aaaa
            700 ttys004  node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js
            701 ttys004  node /x/playwright/mcp aaaa
        """
        XCTAssertEqual(SessionCloser.parse(ps).map(\.pid), [91480, 47710, 64946, 50950, 700])
        XCTAssertEqual(SessionCloser.parse(ps).first?.tty, "ttys023")
    }

    func testTheWindowClosesOnlyWithNothingButTheShellLeft() {
        XCTAssertTrue(SessionCloser.onlyShell("login\n-zsh\n"))
        XCTAssertFalse(SessionCloser.onlyShell("login\nzsh\nnode\n"))   // an MCP server still exiting
        XCTAssertFalse(SessionCloser.onlyShell("login\nzsh\n2.1.302\n"))   // claude itself
    }

    func testHowEachKindOfSessionEnds() {
        let term = SessionCloser.Proc(pid: 10, tty: "ttys001", args: "claude /parley:voice")
        let desk = SessionCloser.Proc(pid: 68140, tty: "??", args: "/Users/s/Library/Application Support/Claude/claude-code/2.1/x/claude.app/Contents/MacOS/claude --output-format stream-json")
        let helper = "/Applications/Claude.app/Contents/Helpers/disclaimer --pgroup -- /Users/s/Library/Application Support/Claude/claude-code/2.1/x/claude.app/Contents/MacOS/claude"
        XCTAssertEqual(SessionCloser.ending(term, group: 10, leader: "claude"), .terminal("ttys001"))
        XCTAssertEqual(SessionCloser.ending(desk, group: 68139, leader: helper), .desktop(group: 68139))
        // Never the app's own group, nor a group claude leads itself without a terminal.
        if case .refuse = SessionCloser.ending(desk, group: 500, leader: "/Applications/Claude.app/Contents/MacOS/Claude") {} else { XCTFail("app group") }
        if case .refuse = SessionCloser.ending(desk, group: 68140, leader: helper) {} else { XCTFail("own group") }
        if case .refuse = SessionCloser.ending(desk, group: -1, leader: nil) {} else { XCTFail("no group") }
    }
}
