import XCTest
@testable import Parley

// Überwachungsmodus: only the Zentrale talks to Sir; the others report to it (Supervisor.swift).
final class SupervisorTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_760_000_000) }
    private var clock = Clock()
    private var reg: SessionRegistry!
    private var server: ControlServer!
    private var voiced: [TurnPayload] = []
    private var starts: [String] = []
    private var root = ""
    private var zentrale = ""
    private var shirts = ""

    override func setUpWithError() throws {
        clock = Clock()
        let c = clock
        reg = SessionRegistry(now: { c.t }, phase: { "idle" }, daily: DailyStats(now: { c.t }))
        server = ControlServer(sessions: reg, now: { c.t })
        voiced = []
        starts = []
        server.replyProvider = { [unowned self] turn, done in self.voiced.append(turn); done(TurnReply(transcript: "", park: true)) }
        server.starter = { [unowned self] folder, _, _ in self.starts.append(folder) }
        server.parleyStartRunning = { _ in false }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parley-supervisor-\(UUID().uuidString)")
        root = Zentrale.normalize(url.path)
        zentrale = root + "/zentrale"
        shirts = root + "/shirts"
        for d in [zentrale, shirts] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        let z = zentrale
        server.zentraleDir = { z }
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: root) }

    @discardableResult
    private func post(_ path: String, _ json: String) -> (Int, String) {
        server.handle(HTTPRequest(method: "POST", path: path, body: Data(json.utf8)))
    }

    private func get(_ path: String) -> String { server.handle(HTTPRequest(method: "GET", path: path, body: Data())).1 }

    @discardableResult
    private func presence(_ id: String, _ label: String, _ cwd: String, _ state: String = "idle", extra: String = "") -> String {
        post("/presence", #"{"session_id":"\#(id)","label":"\#(label)","cwd":"\#(cwd)","state":"\#(state)"\#(extra)}"#).1
    }

    private func turn(_ id: String, _ label: String, _ cwd: String, _ speak: String, listen: Bool = true, context: String? = nil) -> TurnPayload {
        var t = TurnPayload(event: "turn", session_id: id, cwd: cwd, project: (cwd as NSString).lastPathComponent, tmux_pane: "",
                            speak: speak, label: label, listen: listen)
        t.context = context
        return t
    }

    /// The server after a restart of Parley: the same sessions, nothing in memory — and, like
    /// `server`, no real Terminal session started from a test.
    private func restarted() -> ControlServer {
        let again = ControlServer(sessions: reg, now: { [clock] in clock.t })
        again.starter = { [unowned self] folder, _, _ in self.starts.append(folder) }
        again.parleyStartRunning = { _ in false }
        again.zentraleDir = server.zentraleDir
        return again
    }

    private func settle() { _ = server.sessionsJSON() }   // a voiced turn's reply lands on the server's queue

    private func on(_ on: Bool = true) { XCTAssertEqual(post("/supervisor", #"{"on":\#(on)}"#).0, 200) }

    private func sessions() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reg.json().utf8)) as? [String: Any])
    }

    private func row(_ id: String) throws -> [String: Any]? {
        (try sessions()["sessions"] as? [[String: Any]])?.first { $0["id"] as? String == id }
    }

    // MARK: - a session's turn becomes a report

    func testATurnIsNotVoicedButReportedToTheZentraleAndTheSessionParks() throws {
        on()
        presence("z", "Zentrale", zentrale)
        var replies: [TurnReply] = []
        var t = turn("s1", "Shirts", shirts, "Die Tests sind grün. Soll ich deployen?", context: "Alle 24 Tests laufen durch.")
        t.replies = [Reply(on: "ja", say: "Sehr wohl."), Reply(on: "nein, morgen", say: "Verstanden.")]
        server.receiveTurn(t) { replies.append($0) }

        XCTAssertTrue(voiced.isEmpty)                                                  // Sir hears nothing of it
        XCTAssertEqual(replies.map(\.transcript), [""])
        XCTAssertEqual(replies.first?.park, true)                                      // its hook parks: resumable
        XCTAssertEqual(try row("s1")?["state"] as? String, "parked")
        XCTAssertEqual((try row("s1")?["stats"] as? [String: Any])?["lastLine"] as? String, "Die Tests sind grün. Soll ich deployen?")

        let got = presence("z", "Zentrale", zentrale)
        XCTAssertTrue(got.contains("[Bericht von Shirts · Frage an Sir] Die Tests sind grün. Soll ich deployen?"), got)
        XCTAssertTrue(got.contains("Erwartete Antworten: ja · nein, morgen"), got)
        XCTAssertTrue(got.contains("Alle 24 Tests laufen durch."), got)
        XCTAssertTrue(got.contains("Session s1") && got.contains(shirts.replacingOccurrences(of: "/", with: #"\/"#)), got)
        XCTAssertEqual(presence("z", "Zentrale", zentrale), "{}")                      // once
    }

    func testSpeakEndIsReportedAsDone() {
        on()
        presence("z", "Zentrale", zentrale)
        server.receiveTurn(turn("s1", "Shirts", shirts, "Der Export ist gebaut.", listen: false)) { _ in }
        let got = presence("z", "Zentrale", zentrale)
        XCTAssertTrue(got.contains("[Bericht von Shirts · fertig] Der Export ist gebaut."), got)
        XCTAssertTrue(got.contains("keine Antwort erwartet"), got)
    }

    func testOffEverythingIsVoicedAsBefore() {
        presence("z", "Zentrale", zentrale)
        server.receiveTurn(turn("s1", "Shirts", shirts, "Fertig, Sir.")) { _ in }
        settle()
        XCTAssertEqual(voiced.map(\.speak), ["Fertig, Sir."])
        XCTAssertEqual(presence("z", "Zentrale", zentrale), "{}")
    }

    func testTheZentraleAndExemptSessionsKeepTalkingToSir() {
        post("/supervisor", #"{"on":true,"exempt":["Shirts"]}"#)
        presence("z", "Zentrale", zentrale)
        server.receiveTurn(turn("z", "Zentrale", zentrale, "Shirts ist fertig, Sir.")) { _ in }
        settle()
        server.receiveTurn(turn("s1", "Shirts", shirts, "Ich bin ausgenommen.")) { _ in }
        settle()
        server.receiveTurn(turn("s2", "Angebote", root, "Ich nicht.")) { _ in }
        XCTAssertEqual(voiced.map(\.speak), ["Shirts ist fertig, Sir.", "Ich bin ausgenommen."])
    }

    func testTheModsTurnIsQueuedAndEndsWithoutADelivery() throws {
        on()
        presence("z", "Zentrale", zentrale)
        presence("s1", "Shirts", shirts, "working", extra: #","async":1"#)
        let body = #"{"event":"turn","session_id":"s1","cwd":"\#(shirts)","project":"shirts","tmux_pane":"","speak":"Fertig.","label":"Shirts","listen":false,"async":true,"turn_id":"s1:1"}"#
        XCTAssertEqual(post("/turn", body).1, #"{"queued":true}"#)
        XCTAssertTrue(voiced.isEmpty)
        let next = presence("s1", "Shirts", shirts, extra: #","async":1,"awaiting":"s1:1""#)
        XCTAssertEqual(next, #"{"unknown_turn":true}"#)                                // its turn is over: parked by presence
        XCTAssertTrue(presence("z", "Zentrale", zentrale).contains("[Bericht von Shirts · fertig] Fertig."))
    }

    func testAfterRemindersStillFireWhenASupervisedTurnEnds() {
        on()
        presence("z", "Zentrale", zentrale)
        presence("s1", "Shirts", shirts, "working")
        XCTAssertEqual(post("/remind", #"{"to":"Zentrale","text":"Deploye","after":"Shirts"}"#).0, 200)
        server.receiveTurn(turn("s1", "Shirts", shirts, "Fertig.", listen: false)) { _ in }
        let first = presence("z", "Zentrale", zentrale)                                // the Wiedervorlage …
        XCTAssertTrue(first.contains("Deploye") && first.contains("Shirts ist fertig"), first)
        let second = presence("z", "Zentrale", zentrale)                               // … and then the report: neither is lost
        XCTAssertTrue(second.contains("[Bericht von Shirts · fertig] Fertig."), second)
    }

    // MARK: - nothing is lost on the way to the Zentrale

    func testReportsGatherWhileTheZentraleTalksToSirAndFollowItsTurn() {
        on()
        presence("z", "Zentrale", zentrale, extra: #","async":1"#)
        var held: ((TurnReply) -> Void)?
        server.replyProvider = { _, done in held = done }
        post("/turn", #"{"event":"turn","session_id":"z","cwd":"\#(zentrale)","project":"zentrale","tmux_pane":"","speak":"Sir?","label":"Zentrale","listen":true,"async":true,"turn_id":"z:1"}"#)
        server.receiveTurn(turn("s1", "Shirts", shirts, "Eins.")) { _ in }
        server.receiveTurn(turn("s2", "Angebote", root, "Zwei.")) { _ in }
        XCTAssertEqual(presence("z", "Zentrale", zentrale, extra: #","async":1,"awaiting":"z:1""#), "{}")   // not mid-conversation
        held?(TurnReply(transcript: "Ja.", park: false))
        _ = server.sessionsJSON()
        let answer = presence("z", "Zentrale", zentrale, extra: #","async":1,"awaiting":"z:1""#)
        XCTAssertTrue(answer.contains(#""instruction":"Ja.""#), answer)                 // Sir's answer first
        let id = try? XCTUnwrap((JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any])?["delivery_id"] as? String)
        presence("z", "Zentrale", zentrale, "working", extra: #","async":1,"ack":"\#(id ?? "")""#)        // taken: the reports may follow
        let both = presence("z", "Zentrale", zentrale, "working", extra: #","async":1"#)
        XCTAssertTrue(both.contains("[Bericht von Shirts") && both.contains("[Bericht von Angebote"), both)
    }

    func testAnUntakenBatchSurvivesTheZentralesOwnTurnAndAnotherInstruction() throws {
        on()
        let mod = #","async":1"#
        presence("z", "Zentrale", zentrale, "working", extra: mod)
        server.receiveTurn(turn("s1", "Shirts", shirts, "Eins.")) { _ in }               // handed over, not taken yet
        // Its own turn wipes what waited for it …
        post("/turn", #"{"event":"turn","session_id":"z","cwd":"\#(zentrale)","project":"zentrale","tmux_pane":"","speak":"Moment, Sir.","label":"Zentrale","listen":false,"async":true,"turn_id":"z:1"}"#)
        settle()
        XCTAssertEqual(voiced.map(\.speak), ["Moment, Sir."])
        XCTAssertEqual(presence("z", "Zentrale", zentrale, extra: mod), "{}")           // … so it is handed over again,
        XCTAssertEqual(post("/dispatch", #"{"cwd":"\#(zentrale)","instruction":"Vom Telefon","start":false}"#).0, 200)   // and overwritten
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(presence("z", "Zentrale", zentrale, extra: mod).utf8)) as? [String: Any])
        XCTAssertEqual(first["instruction"] as? String, "Vom Telefon")
        let ack = try XCTUnwrap(first["delivery_id"] as? String)
        presence("z", "Zentrale", zentrale, "working", extra: #","async":1,"ack":"\#(ack)""#)
        XCTAssertTrue(presence("z", "Zentrale", zentrale, "working", extra: mod).contains("[Bericht von Shirts"))   // still not lost
    }

    func testNoZentraleRunningStartsItAndTheReportsWait() {
        on()
        server.receiveTurn(turn("s1", "Shirts", shirts, "Eins.")) { _ in }
        XCTAssertEqual(starts, [zentrale])
        clock.t += PendingInstructions.ttl + 60                                         // no 10-min limit on reports
        server.receiveTurn(turn("s2", "Angebote", root, "Zwei.")) { _ in }
        presence("z", "Zentrale", zentrale)                                             // it shows up
        let got = presence("z", "Zentrale", zentrale)
        XCTAssertTrue(got.contains("[Bericht von Shirts") && got.contains("[Bericht von Angebote"), got)
    }

    func testAHookCarriedZentraleTakesTheReportsWithItsReply() {
        on()
        var held: ((TurnReply) -> Void)?
        server.replyProvider = { _, done in held = done }
        var got: [TurnReply] = []
        server.receiveTurn(turn("z", "Zentrale", zentrale, "Sir?")) { got.append($0) }   // no mod: hook only
        server.receiveTurn(turn("s1", "Shirts", shirts, "Eins.")) { _ in }
        held?(TurnReply(transcript: "Ja.", park: false))
        settle()
        XCTAssertEqual(got.count, 1)
        XCTAssertTrue(got[0].transcript.hasPrefix("Ja.\n\n[Bericht von Shirts"), got[0].transcript)
    }

    // MARK: - the switch

    func testTheSwitchIsKeptAndShownInSessions() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("supervisor-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        server.supervisorFile = file
        XCTAssertTrue(get("/supervisor").contains(#""on":false"#))
        XCTAssertNil(try sessions()["supervisor"])                                       // off: /sessions as before
        XCTAssertEqual(post("/supervisor", "{}").0, 400)
        presence("z", "Zentrale", zentrale)
        presence("s1", "Shirts", shirts)
        let set = post("/supervisor", #"{"on":true,"exempt":[" Shirts "]}"#).1
        XCTAssertTrue(set.contains(#""on":true"#) && set.contains(#""exempt":["Shirts"]"#) && set.contains(#""zentrale":"z""#), set)
        XCTAssertEqual(try sessions()["supervisor"] as? Bool, true)
        XCTAssertEqual(try row("z")?["zentrale"] as? Bool, true)
        XCTAssertNil(try row("s1")?["zentrale"])

        let again = restarted()
        again.supervisorFile = file
        XCTAssertTrue(again.supervisorOn())
        XCTAssertTrue(again.handle(HTTPRequest(method: "GET", path: "/supervisor", body: Data())).1.contains(#""exempt":["Shirts"]"#))
        again.setSupervisor(on: false)
        XCTAssertFalse(Supervisor.load(file).on)
    }

    func testSwitchingOnTurnsTheWaitingQueueIntoReports() {
        presence("z", "Zentrale", zentrale)
        var held: ((TurnReply) -> Void)?
        server.replyProvider = { [unowned self] turn, done in self.voiced.append(turn); held = done }
        server.receiveTurn(turn("s1", "Shirts", shirts, "Eins.")) { _ in }               // being voiced: stays
        var second: [TurnReply] = []
        server.receiveTurn(turn("s2", "Angebote", root, "Zwei.")) { second.append($0) }  // waits behind it
        var own: [TurnReply] = []
        server.receiveTurn(turn("z", "Zentrale", zentrale, "Sir?")) { own.append($0) }
        XCTAssertEqual(server.queuedCount(), 2)
        on()
        XCTAssertEqual(server.queuedCount(), 1)                                         // the Zentrale's own still waits
        XCTAssertEqual(second.first?.park, true)
        held?(TurnReply(transcript: "", park: true))
        settle()
        XCTAssertEqual(voiced.map(\.speak), ["Eins.", "Sir?"])
        held?(TurnReply(transcript: "", park: true))
        settle()
        XCTAssertEqual(own.first?.transcript.contains("[Bericht von Angebote · Frage an Sir] Zwei."), true)   // with its reply
    }

    // MARK: - who asks

    func testADispatchSaysWhoAsksAndWhereTheAnswerGoes() {
        presence("s1", "Shirts", shirts)
        post("/dispatch", #"{"cwd":"\#(shirts)","instruction":"Lass die Tests laufen","from":"Zentrale","start":false}"#)
        XCTAssertEqual(presence("s1", "Shirts", shirts), #"{"instruction":"[Auftrag von Zentrale] Lass die Tests laufen"}"#)
        on()
        post("/dispatch", #"{"cwd":"\#(shirts)","instruction":"Und deploye","from":"Zentrale","start":false}"#)
        let got = presence("s1", "Shirts", shirts)
        XCTAssertTrue(got.contains("[Auftrag von Zentrale] Und deploye") && got.contains("geht als Bericht an Zentrale"), got)
        post("/dispatch", #"{"cwd":"\#(shirts)","instruction":"Ohne Absender","start":false}"#)
        XCTAssertEqual(presence("s1", "Shirts", shirts), #"{"instruction":"Ohne Absender"}"#)
    }

    func testInstructionKeepsTheSenderInert() {
        XCTAssertEqual(Supervisor.instruction("x", from: " ]Zen[trale\n ", reportsBack: false), "[Auftrag von Zentrale] x")
        XCTAssertEqual(Supervisor.instruction("x", from: "", reportsBack: true), "x")
        XCTAssertEqual(Supervisor.instruction("", from: "Zentrale", reportsBack: true), "")
    }

    // MARK: - recurring Wiedervorlage

    private func tick() {
        server.tickReminders()
        _ = server.sessionsJSON()   // waits for the queue
    }

    func testEveryComesAgainAndAgainUntilCancelled() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("reminders-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        server.remindersFile = file
        presence("z", "Zentrale", zentrale)
        let made = post("/remind", #"{"to":"Zentrale","text":"Prüfe Mails und Sessions","every":5}"#)
        XCTAssertEqual(made.0, 200, made.1)
        XCTAssertTrue(made.1.contains(#""every":5"#), made.1)
        tick()
        XCTAssertEqual(presence("z", "Zentrale", zentrale), "{}")                       // first after one interval
        clock.t += 5 * 60 + 1
        tick()
        XCTAssertTrue(presence("z", "Zentrale", zentrale).contains("Wiedervorlage (alle 5 Minuten): Prüfe Mails und Sessions"))
        tick()
        XCTAssertEqual(presence("z", "Zentrale", zentrale), "{}")                       // not twice a round

        clock.t += 5 * 60
        presence("z", "Zentrale", zentrale, "working")
        tick()                                                                          // busy: this round is skipped
        XCTAssertEqual(presence("z", "Zentrale", zentrale), "{}")

        clock.t += 3 * 3600                                                             // the Mac slept: one round, not 36
        let again = restarted()                                                         // … and Parley restarted
        again.remindersFile = file
        again.tickReminders()
        _ = again.sessionsJSON()
        let handed = again.handle(HTTPRequest(method: "POST", path: "/presence", body: Data(#"{"session_id":"z","label":"Zentrale","cwd":"\#(zentrale)","state":"idle"}"#.utf8))).1
        XCTAssertTrue(handed.contains("Prüfe Mails und Sessions"), handed)
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(again.handle(HTTPRequest(method: "GET", path: "/remind", body: Data())).1.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(list["reminders"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)                                                   // still there
        let at = try XCTUnwrap(rows[0]["at"] as? Double) / 1000
        XCTAssertTrue(at > clock.t.timeIntervalSince1970 && at <= clock.t.timeIntervalSince1970 + 300, "\(at)")
        let id = try XCTUnwrap(rows[0]["id"] as? String)
        XCTAssertEqual(again.handle(HTTPRequest(method: "POST", path: "/remind/cancel", body: Data(#"{"id":"\#(id)"}"#.utf8))).0, 200)
    }

    func testEveryRules() {
        presence("z", "Zentrale", zentrale)
        XCTAssertEqual(post("/remind", #"{"to":"Zentrale","text":"x","every":0.5}"#).0, 400)         // at least a minute
        XCTAssertEqual(post("/remind", #"{"to":"Zentrale","text":"x","every":5,"after":"Zentrale"}"#).0, 400)
        XCTAssertEqual(post("/remind", #"{"to":"Zentrale","text":"x","every":5,"in":1}"#).0, 200)    // first in a minute, then every five
        let r = Reminder(id: "r", text: "x", label: "Z", at: Date(timeIntervalSince1970: 1000), every: 5, created: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(Reminders.next(r, after: Date(timeIntervalSince1970: 1000)), Date(timeIntervalSince1970: 1300))
        XCTAssertEqual(Reminders.next(r, after: Date(timeIntervalSince1970: 1900)), Date(timeIntervalSince1970: 2200))
        XCTAssertNil(Reminders.next(Reminder(id: "r", text: "x", label: "Z", at: Date(), created: Date()), after: Date()))
    }

    // MARK: - a call Sir didn't take

    func testMissedLinesAreKeptCountedAndComeBackAsOneInstruction() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("missed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        server.missedFile = file
        on()
        presence("z", "Zentrale", zentrale)
        presence("s1", "Shirts", shirts, "working")
        XCTAssertTrue(server.isZentrale("z", supervised: true))
        XCTAssertFalse(server.isZentrale("s1"))
        XCTAssertNil(server.takeMissed())                                                // nothing waits
        XCTAssertNil(try sessions()["missed"])

        XCTAssertEqual(server.addMissed(turn("z", "Zentrale", zentrale, "Shirts ist fertig.", listen: false)), 1)   // the ring he didn't take
        clock.t += 300
        XCTAssertEqual(server.addMissed(turn("z", "Zentrale", zentrale, "Angebote fragt: Rabatt auch für Bestandskunden?")), 2)
        clock.t += 300
        XCTAssertEqual(server.addMissed(turn("z", "Zentrale", zentrale, "Der Export läuft.", listen: false)), 3)
        XCTAssertEqual(server.missedCount(), 3)
        XCTAssertEqual(try sessions()["missed"] as? Int, 3)
        XCTAssertEqual(try row("z")?["callback"] as? Int, 0)                             // "wartet auf Rückruf" — the tile offers Rückrufen
        XCTAssertNil(try row("s1")?["callback"])
        XCTAssertEqual((try row("z")?["stats"] as? [String: Any])?["lastLine"] as? String, "Der Export läuft.")
        XCTAssertTrue(get("/supervisor").contains(#""missed":3"#))
        presence("z", "Zentrale", zentrale)                                              // (ten minutes on: it still runs)
        let live = LiveActivity.content(fromSessions: reg.json())
        XCTAssertEqual(live.line, "3 Updates warten auf deinen Rückruf")                 // the Live Activity counts them
        XCTAssertEqual(live.from, "Zentrale")
        XCTAssertEqual(live.sessions.first?.callback, 0)

        let again = restarted()                                                          // a restart keeps them
        again.missedFile = file
        XCTAssertEqual(again.missedCount(), 3)

        let all = try XCTUnwrap(server.takeMissed(said: "Was gibt es Neues?"))
        let open = try XCTUnwrap(all.range(of: "Rabatt auch für Bestandskunden?"))
        let done = try XCTUnwrap(all.range(of: "Shirts ist fertig."))
        XCTAssertTrue(open.lowerBound < done.lowerBound)                                 // what is open comes first
        XCTAssertTrue(try XCTUnwrap(all.range(of: "Shirts ist fertig.")).lowerBound < (try XCTUnwrap(all.range(of: "Der Export läuft."))).lowerBound)
        XCTAssertTrue(all.contains("diese 3 Zeilen") && all.contains("EINE gesprochene Zusammenfassung"), all)
        XCTAssertTrue(all.hasSuffix("Außerdem sagt Sir gerade: „Was gibt es Neues?“"), all)
        XCTAssertEqual(server.missedCount(), 0)
        XCTAssertNil(try sessions()["missed"])
        XCTAssertNil(try row("z")?["callback"])
        XCTAssertEqual(Missed.load(file), [])                                            // … and gone for good
        XCTAssertEqual(LiveActivity.content(fromSessions: reg.json()).line, "Der Export läuft.")   // its own last line again
    }

    func testTheRingSirAskedForComesOnceAndACallBackIsOneDialog() {
        on()
        presence("z", "Zentrale", zentrale)
        var held: [(TurnReply) -> Void] = []
        server.replyProvider = { [unowned self] turn, done in self.voiced.append(turn); held.append(done) }
        server.addMissed(turn("z", "Zentrale", zentrale, "Bitte Rückruf.", listen: false), ringAgain: 300)   // "In 5 Min."
        tick()
        XCTAssertTrue(voiced.isEmpty)                                                    // not yet
        clock.t += 301
        tick()
        XCTAssertEqual(voiced.map(\.event), [ControlServer.callbackEvent])
        XCTAssertEqual(voiced.first?.speak, "ring")
        tick()
        XCTAssertEqual(voiced.count, 1)                                                  // once
        held.removeFirst()(TurnReply(transcript: "", park: false))
        settle()

        server.callBack(); server.callBack()                                             // Sir calls in (twice in a hurry)
        settle()
        server.callBack()
        settle()
        XCTAssertEqual(voiced.map(\.speak), ["ring", ""])                                // one is at it, one more may wait — not three
        XCTAssertEqual(server.queuedCount(), 1)
    }

    func testANoteForTheFirstMissAndNoneWithoutMissedLines() {
        XCTAssertTrue(Missed.note.contains("nicht angenommen") && Missed.note.contains("<speak-end></speak-end>"))
        XCTAssertEqual(Missed.waiting(1), "1 Update wartet auf deinen Rückruf")
        let one = Missed.instruction([MissedLine(at: Date(timeIntervalSince1970: 1_760_000_000), text: "Nur das.", asks: false)])
        XCTAssertTrue(one.contains("diese Zeile") && one.contains("Zur Kenntnis") && !one.contains("Offen —") && !one.contains("Außerdem"), one)
    }

    // MARK: - the Live Activity

    func testTheLiveActivityShowsTheZentraleAlone() {
        on()
        presence("z", "Zentrale", zentrale)
        presence("s1", "Shirts", shirts, "working")
        let c = LiveActivity.content(fromSessions: reg.json())
        XCTAssertEqual(c.sessions.map(\.label), ["Zentrale"])
        XCTAssertEqual(c.alive, 2)
        XCTAssertEqual(LiveActivity.widget(fromSessions: reg.json()).sessions.count, 2)   // the widgets keep the list
        on(false)
        XCTAssertEqual(LiveActivity.content(fromSessions: reg.json()).sessions.count, 2)
    }
}
