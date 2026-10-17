import XCTest
@testable import Parley

// POST /dispatch, pending-by-cwd delivery + expiry, the session starter, the Zentrale folder.
final class DispatchTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_760_000_000) }
    private var clock = Clock()
    private var reg: SessionRegistry!
    private var server: ControlServer!
    private var starts: [String] = []
    private var resumed: [String?] = []
    private var dir = ""

    override func setUpWithError() throws {
        clock = Clock()
        let c = clock
        reg = SessionRegistry(now: { c.t }, phase: { "idle" }, daily: DailyStats(now: { c.t }))
        server = ControlServer(sessions: reg, now: { c.t })
        starts = []
        resumed = []
        server.starter = { [unowned self] folder, resume in self.starts.append(folder); self.resumed.append(resume) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parley-dispatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        dir = Zentrale.normalize(url.path)
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    private func post(_ path: String, _ json: String) -> (Int, String) {
        server.handle(HTTPRequest(method: "POST", path: path, body: Data(json.utf8)))
    }

    private func dispatch(_ instruction: String, start: Bool = true, cwd: String? = nil) -> (Int, String) {
        post("/dispatch", #"{"cwd":"\#(cwd ?? dir)","instruction":"\#(instruction)","start":\#(start)}"#)
    }

    @discardableResult
    private func presence(_ id: String, _ state: String, cwd: String? = nil) -> String {
        post("/presence", #"{"session_id":"\#(id)","label":"Neu","cwd":"\#(cwd ?? dir)","state":"\#(state)"}"#).1
    }

    private func turn(_ id: String, cwd: String? = nil) -> TurnPayload {
        TurnPayload(event: "turn", session_id: id, cwd: cwd ?? dir, project: "neu", tmux_pane: "", speak: "Bereit, Sir.", label: "Neu", listen: true)
    }

    private func state(_ id: String) throws -> String? {
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reg.json().utf8)) as? [String: Any])
        return (obj["sessions"] as? [[String: Any]])?.first { $0["id"] as? String == id }?["state"] as? String
    }

    // MARK: - starting + the first turn

    func testNoSessionThereStartsOneOnceAndItsFirstTurnTakesTheInstructions() throws {
        XCTAssertEqual(dispatch("Baue X").1, #"{"ok":true,"delivered":"pending","started":true}"#)
        XCTAssertEqual(starts, [dir])
        clock.t += 30
        XCTAssertEqual(dispatch("Und Y").1, #"{"ok":true,"delivered":"pending","started":false}"#)   // not twice in 2 min
        XCTAssertEqual(starts.count, 1)

        server.replyProvider = { _, _ in XCTFail("the opening line must not be voiced") }
        var replies: [String] = []
        server.receiveTurn(turn("t1")) { replies.append($0.transcript) }
        XCTAssertEqual(replies, ["Baue X\n\nUnd Y"])
        XCTAssertEqual(try state("t1"), "working")

        server.replyProvider = { _, done in done(TurnReply(transcript: "ok", park: false)) }
        server.receiveTurn(turn("t1")) { replies.append($0.transcript) }                 // consumed: voiced normally
        _ = server.resumableList()
        XCTAssertEqual(replies, ["Baue X\n\nUnd Y", "ok"])
    }

    func testStartsAgainAfterTheGuard() {
        _ = dispatch("", start: true)
        clock.t += ControlServer.restartGuard + 1
        XCTAssertEqual(dispatch("", start: true).1, #"{"ok":true,"delivered":"none","started":true}"#)
        XCTAssertEqual(starts.count, 2)
    }

    // MARK: - presence / wake delivery, expiry

    func testIdlePresenceTakesItWorkingDoesNot() {
        _ = dispatch("Prüfe die Tests", start: false)
        XCTAssertEqual(starts, [])
        XCTAssertEqual(presence("m1", "working"), "{}")
        XCTAssertEqual(presence("m1", "idle"), #"{"instruction":"Prüfe die Tests"}"#)
        XCTAssertEqual(presence("m1", "idle"), "{}")                                     // exactly once
    }

    func testParkedHookTakesItOnItsWakePoll() throws {
        _ = dispatch("Weiter mit Schritt 2", start: false)
        let (_, body) = post("/wake", #"{"session_id":"p1","cwd":"\#(dir)/","project":"neu","tmux_pane":"","label":""}"#)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(obj["transcript"] as? String, "Weiter mit Schritt 2")
    }

    func testExpiresAfterTenMinutes() {
        _ = dispatch("Zu spät", start: false)
        clock.t += PendingInstructions.ttl + 1
        XCTAssertEqual(presence("m1", "idle"), "{}")
    }

    // MARK: - a session is already there

    func testReachableSessionGetsItDirectly() {
        presence("m1", "idle")
        XCTAssertEqual(dispatch("Mach Y").1, #"{"ok":true,"delivered":"session","started":false}"#)
        XCTAssertEqual(starts, [])
        XCTAssertEqual(presence("m1", "idle"), #"{"instruction":"Mach Y"}"#)
    }

    // A hook-only session (no mod) that is busy: no second session, the task waits for its turn.
    func testBusyHookOnlySessionGetsItAtItsNextTurn() {
        server.replyProvider = { _, done in done(TurnReply(transcript: "weiter", park: false)) }
        server.receiveTurn(turn("h1")) { _ in }
        _ = server.resumableList()
        XCTAssertEqual(dispatch("Danach Z").1, #"{"ok":true,"delivered":"pending","started":false}"#)
        server.replyProvider = { _, _ in XCTFail("not voiced") }
        var got = ""
        server.receiveTurn(turn("h1")) { got = $0.transcript }
        XCTAssertEqual(got, "Danach Z")
    }

    // A routed wake utterance for such a session takes the same way.
    func testRoutedToABusyHookOnlySessionWaitsByFolder() {
        server.replyProvider = { _, done in done(TurnReply(transcript: "weiter", park: false)) }
        server.receiveTurn(turn("h1")) { _ in }
        _ = server.resumableList()
        server.deliverRouted(id: "h1", instruction: "Vom Telefon")
        _ = server.resumableList()
        server.replyProvider = { _, _ in XCTFail("not voiced") }
        var got = ""
        server.receiveTurn(turn("h1")) { got = $0.transcript }
        XCTAssertEqual(got, "Vom Telefon")
    }

    func testValidation() {
        XCTAssertEqual(post("/dispatch", "nope").0, 400)
        XCTAssertEqual(post("/dispatch", #"{"instruction":"x"}"#).0, 400)
        XCTAssertEqual(dispatch("x", cwd: "relative/path").0, 400)
        XCTAssertEqual(dispatch("x", cwd: dir + "/missing").0, 400)
        XCTAssertEqual(dispatch("", start: false).0, 400)                                  // nothing to do
        XCTAssertEqual(post("/dispatch", #"{"cwd":"\#(dir)/"}"#).1, #"{"ok":true,"delivered":"none","started":true}"#)   // start defaults on
        XCTAssertEqual(starts, [dir])                                                      // normalized
    }

    // MARK: - past sessions: /past + /dispatch resume

    private func pastSession(_ id: String, title: String) throws -> URL {
        let root = URL(fileURLWithPath: dir).appendingPathComponent("transcripts")
        let folder = root.appendingPathComponent("-proj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = [#"{"type":"user","cwd":"\#(dir)","sessionId":"\#(id)","message":{"content":"Hallo"}}"#,
                     #"{"type":"custom-title","customTitle":"\#(title)"}"#,
                     #"{"type":"last-prompt","lastPrompt":"Bau den Export"}"#]
        try lines.joined(separator: "\n").write(to: folder.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
        server.transcripts = root
        return root
    }

    func testPastFindsBySearchTerm() throws {
        _ = try pastSession("aaaa-1111", title: "Rechnungen Export")
        let hit = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(post("/past", #"{"q":"rechnung"}"#).1.utf8)) as? [String: Any])
        let list = try XCTUnwrap(hit["sessions"] as? [[String: Any]])
        XCTAssertEqual(list.first?["id"] as? String, "aaaa-1111")
        XCTAssertEqual(list.first?["title"] as? String, "Rechnungen Export")
        XCTAssertEqual(list.first?["lastPrompt"] as? String, "Bau den Export")
        XCTAssertEqual(list.first?["cwd"] as? String, dir)
        XCTAssertEqual(post("/past", #"{"q":"nichts davon"}"#).1, #"{"sessions":[]}"#)
    }

    func testResumeStartsThePastSessionInItsFolderWithItsInstruction() throws {
        _ = try pastSession("aaaa-1111", title: "Rechnungen")
        XCTAssertEqual(post("/dispatch", #"{"resume":"aaaa-1111","instruction":"Weiter mit PDF"}"#).1,
                       #"{"ok":true,"delivered":"pending","started":true}"#)
        XCTAssertEqual(starts, [dir])
        XCTAssertEqual(resumed, ["aaaa-1111"])
        // It shows up (same id) → the instruction rides back with its presence.
        clock.t += 5
        XCTAssertTrue(presence("aaaa-1111", "idle").contains("Weiter mit PDF"))
    }

    func testResumeOfARunningSessionDeliversInsteadOfStarting() throws {
        _ = try pastSession("aaaa-1111", title: "Rechnungen")
        presence("aaaa-1111", "working")
        XCTAssertEqual(post("/dispatch", #"{"resume":"aaaa-1111","instruction":"Noch was"}"#).1,
                       #"{"ok":true,"delivered":"session","started":false}"#)
        XCTAssertEqual(starts, [])
    }

    func testResumeRejectsUnknownOrUnsafeIds() throws {
        _ = try pastSession("aaaa-1111", title: "Rechnungen")
        XCTAssertEqual(post("/dispatch", #"{"resume":"bbbb-2222"}"#).0, 404)
        XCTAssertEqual(post("/dispatch", #"{"resume":"x'; rm -rf ~ #"}"#).0, 404)
        XCTAssertEqual(starts, [])
    }
}

final class SessionStarterTests: XCTestCase {
    func testCommandQuotesTheFolderAndCarriesOnlyTheFixedPrompt() {
        XCTAssertEqual(SessionStarter.command(folder: "/Users/x/it's here"),
                       #"cd '/Users/x/it'\''s here' && claude '/parley:voice'"#)
        XCTAssertEqual(SessionStarter.command(folder: "/tmp/$(rm -rf ~)"), #"cd '/tmp/$(rm -rf ~)' && claude '/parley:voice'"#)
        XCTAssertEqual(SessionStarter.command(folder: "/p", resume: "abc-123"), #"cd '/p' && claude --resume 'abc-123' '/parley:voice'"#)
    }

    func testOsascriptGetsTheCommandAsArgvNotAsScript() {
        let args = SessionStarter.osascriptArguments(folder: #"/x/"quoted""#)
        XCTAssertEqual(args.last, SessionStarter.command(folder: #"/x/"quoted""#))
        let script = args.dropLast().joined(separator: "\n")
        XCTAssertFalse(script.contains("quoted"))
        XCTAssertFalse(script.contains("activate"))
        XCTAssertTrue(script.contains(#"tell application "Terminal" to do script (item 1 of argv)"#))
    }
}

final class ZentraleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("parley-zentrale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func json(_ url: URL) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String])
    }

    func testCreatedFromTheTemplateWithProjectsDir() throws {
        let template = root.appendingPathComponent("repo/zentrale")
        try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
        try Data("# Zentrale\n".utf8).write(to: template.appendingPathComponent("CLAUDE.md"))
        try Data(#"{"name":"Zentrale"}"#.utf8).write(to: template.appendingPathComponent(".parley.json"))
        let s = ZentraleSettings(zentraleDir: root.appendingPathComponent("home/parley-zentrale").path, projectsDir: "/p")

        XCTAssertTrue(try Zentrale.ensure(s, template: template))
        let dir = URL(fileURLWithPath: s.zentraleDir)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("CLAUDE.md"), encoding: .utf8), "# Zentrale\n")
        XCTAssertEqual(try json(dir.appendingPathComponent(".parley.json")), ["name": "Zentrale", "projectsDir": "/p"])
        XCTAssertFalse(try Zentrale.ensure(s, template: template))                        // exists: kept
        XCTAssertFalse(try Zentrale.ensure(ZentraleSettings(zentraleDir: s.zentraleDir, projectsDir: "/q"), template: nil))
        XCTAssertEqual(try json(dir.appendingPathComponent(".parley.json"))["projectsDir"], "/q")   // kept current
    }

    func testMinimalWithoutATemplate() throws {
        let s = ZentraleSettings(zentraleDir: root.appendingPathComponent("z").path, projectsDir: "/p")
        XCTAssertTrue(try Zentrale.ensure(s, template: nil))
        XCTAssertEqual(try json(URL(fileURLWithPath: s.zentraleDir).appendingPathComponent(".parley.json")),
                       ["name": "Zentrale", "projectsDir": "/p"])
    }

    func testNormalize() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(Zentrale.normalize("~/workspace/privat/"), home + "/workspace/privat")
        XCTAssertEqual(Zentrale.normalize(" /a//b/./c/ "), "/a/b/c")
    }

    func testPendingInstructionsJoinAndExpire() {
        var p = PendingInstructions()
        let t = Date(timeIntervalSince1970: 0)
        p.add("eins", cwd: "/a", at: t)
        p.add("zwei", cwd: "/a", at: t.addingTimeInterval(300))
        p.add("drei", cwd: "/b", at: t)
        XCTAssertEqual(p.prune(now: t.addingTimeInterval(650)), ["/a", "/b"])
        XCTAssertFalse(p.has(cwd: "/b", now: t.addingTimeInterval(650)))
        XCTAssertEqual(p.take(cwd: "/a", now: t.addingTimeInterval(650)), "zwei")
        XCTAssertNil(p.take(cwd: "/a", now: t.addingTimeInterval(650)))
        p.add("x", cwd: "/c", at: t)
        p.add("y", cwd: "/c", at: t)
        XCTAssertEqual(p.take(cwd: "/c", now: t), "x\n\ny")
    }

}
