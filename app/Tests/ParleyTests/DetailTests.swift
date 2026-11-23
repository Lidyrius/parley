import XCTest
@testable import Parley

// Protocol v11 (docs/IPHONE.md): Rückmeldung beim Fortsetzen and the Detailgrad — the frames,
// the store, the note handed to the session and what /sessions says.
final class DetailTests: XCTestCase {
    private let mittel = "[Parley · Detailgrad mittel: Sprechzeile bis etwa 90 Wörter (rund 40 Sekunden) – die wichtigsten Punkte mit kurzer Begründung.]"
    private let lang = "[Parley · Detailgrad ausführlich: Sprechzeile bis etwa 180 Wörter (rund 80 Sekunden) – vollständige Zusammenfassung mit Gründen, Zahlen und offenen Punkten.]"
    private let kurz = "[Parley · Detailgrad kurz: Sprechzeile wieder höchstens etwa 40 Wörter.]"

    // MARK: - frames

    func testResumeLineFrame() {
        XCTAssertEqual(RelayFrame.parse(#"{"t":"resumeLine","on":false}"#), .resumeLine(false))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"resumeLine","on":true}"#), .resumeLine(true))
        XCTAssertNil(RelayFrame.parse(#"{"t":"resumeLine"}"#))
    }

    func testDetailFrames() {
        XCTAssertEqual(RelayFrame.parse(#"{"t":"detail","level":"mittel"}"#), .detail(id: nil, level: "mittel"))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"detail","id":"s1","level":"lang"}"#), .detail(id: "s1", level: "lang"))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"detail","id":"s1","level":""}"#), .detail(id: "s1", level: ""))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"detail","id":"","level":"kurz"}"#), .detail(id: nil, level: "kurz"))
        XCTAssertNil(RelayFrame.parse(#"{"t":"detail","level":"riesig"}"#))          // unknown level: ignored
        XCTAssertNil(RelayFrame.parse(#"{"t":"detail","level":""}"#))                // the default can't be "back to the default"
        XCTAssertNil(RelayFrame.parse(#"{"t":"detail","id":"s1","level":"Lang"}"#))
        XCTAssertNil(RelayFrame.parse(#"{"t":"detail"}"#))
    }

    func testThePhoneSetsBoth() {
        let store = PhoneHub.Store.memory()
        let detail = DetailStore(store: store, file: nil)
        let hub = PhoneHub(store: store, detail: detail, log: { _ in })
        final class Count: @unchecked Sendable { var n = 0 }
        let changes = Count()
        hub.onChange = { changes.n += 1 }

        hub.handle(.resumeLine(false))
        XCTAssertEqual(store.get(.resumeLine), "0")
        XCTAssertFalse(detail.resumeLine)
        hub.handle(.resumeLine(false))                     // no change
        hub.handle(.resumeLine(true))
        XCTAssertNil(store.get(.resumeLine))
        XCTAssertTrue(detail.resumeLine)

        hub.handle(.detail(id: nil, level: "mittel"))
        XCTAssertEqual(detail.defaultLevel, .mittel)
        hub.handle(.detail(id: "s1", level: "lang"))
        XCTAssertEqual(detail.level("s1"), .lang)
        XCTAssertEqual(detail.level("s2"), .mittel)
        hub.handle(.detail(id: "s1", level: ""))
        XCTAssertNil(detail.override("s1"))
        XCTAssertEqual(changes.n, 5)
    }

    // MARK: - the store

    func testDefaultAndUnknownLevels() {
        let store = PhoneHub.Store.memory()
        let d = DetailStore(store: store, file: nil)
        XCTAssertEqual(d.defaultLevel, .kurz)              // missing
        store.set("quatsch", .detail)
        XCTAssertEqual(d.defaultLevel, .kurz)              // unknown
        XCTAssertFalse(d.set(id: nil, level: "quatsch"))
        XCTAssertFalse(d.set(id: "s", level: "quatsch"))
        XCTAssertTrue(d.set(id: nil, level: "lang"))
        XCTAssertEqual(store.get(.detail), "lang")
        XCTAssertFalse(d.set(id: nil, level: "lang"))      // unchanged
    }

    func testDetailJsonSurvives() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("parley-detail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("detail.json")
        let d = DetailStore(store: .memory(), file: file)
        d.set(id: "a", level: "lang")
        d.set(id: "b", level: "mittel")
        d.set(id: "b", level: "")
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: String])
        XCTAssertEqual(raw, ["a": "lang"])
        XCTAssertEqual(DetailStore(store: .memory(), file: file).override("a"), .lang)
    }

    func testLabels() {
        XCTAssertEqual(DetailLevel.kurz.label, "Kurz — ca. 15 Sek. · 1–2 Sätze (bis ~40 Wörter)")
        XCTAssertEqual(DetailLevel.mittel.label, "Mittel — ca. 40 Sek. · 3–5 Sätze (bis ~90 Wörter)")
        XCTAssertEqual(DetailLevel.lang.label, "Ausführlich — ca. 80 Sek. · ganze Zusammenfassung (bis ~180 Wörter)")
    }

    // MARK: - the note

    func testTheNote() {
        let d = DetailStore(store: .memory(), file: nil)
        XCTAssertEqual(d.noted("Ja.", session: "s"), "Ja.")                     // kurz, never told: nothing
        d.set(id: "s", level: "mittel")
        XCTAssertEqual(d.noted("Ja.", session: "s"), "Ja.\n\n" + mittel)
        XCTAssertEqual(d.noted("Weiter.", session: "s"), "Weiter.\n\n" + mittel)  // mittel / lang: every turn
        d.set(id: "s", level: "lang")
        XCTAssertEqual(d.noted("Gut.", session: "s"), "Gut.\n\n" + lang)
        d.set(id: "s", level: "")                                               // back to the default (kurz)
        XCTAssertEqual(d.noted("Okay.", session: "s"), "Okay.\n\n" + kurz)      // once
        XCTAssertEqual(d.noted("Okay.", session: "s"), "Okay.")
        XCTAssertEqual(d.noted("Hallo.", session: "t"), "Hallo.")               // another session: its own memory
    }

    func testTheDefaultCounts() {
        let store = PhoneHub.Store.memory()
        let d = DetailStore(store: store, file: nil)
        d.set(id: nil, level: "mittel")
        XCTAssertEqual(d.noted("A", session: "x"), "A\n\n" + mittel)
        XCTAssertEqual(d.noted("A", session: "y"), "A\n\n" + mittel)
        d.set(id: "x", level: "kurz")                                           // its own kurz beats the default
        XCTAssertEqual(d.noted("B", session: "x"), "B\n\n" + kurz)
        XCTAssertEqual(d.noted("B", session: "y"), "B\n\n" + mittel)
        XCTAssertEqual(d.noted("C", session: "x"), "C")                         // kurz: once
    }

    func testANewStoreNotesAgain() {   // after a restart a non-kurz level is simply noted again
        let store = PhoneHub.Store.memory()
        DetailStore(store: store, file: nil).set(id: nil, level: "lang")
        let d = DetailStore(store: store, file: nil)
        XCTAssertEqual(d.noted(ControlServer.resumeInstruction, session: "s"), ControlServer.resumeInstruction + "\n\n" + lang)
    }

    func testTheNoteGoesAfterOtherNotes() {
        let d = DetailStore(store: .memory(), file: nil)
        d.set(id: "s", level: "mittel")
        let text = "Mach das.\n\n[Parley hat darauf bereits geantwortet: „Gern.“ – nicht wiederholen.]"
        XCTAssertTrue(d.noted(text, session: "s").hasSuffix("nicht wiederholen.]\n\n" + mittel))
    }

    // MARK: - /sessions

    func testSessionsJson() throws {
        let store = PhoneHub.Store.memory()
        let d = DetailStore(store: store, file: nil)
        let server = ControlServer(sessions: SessionRegistry(phase: { "idle" }, daily: DailyStats()))
        func post(_ id: String) {
            _ = server.handle(HTTPRequest(method: "POST", path: "/presence", body: Data(
                #"{"session_id":"\#(id)","label":"\#(id)","project":"","cwd":"/x/\#(id)","state":"idle","usage":null,"tasks":[]}"#.utf8)))
        }
        post("a"); post("b")
        func overview() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(server.sessionsJSON().utf8)) as? [String: Any])
        }
        func rows() throws -> [String: [String: Any]] {
            let list = try XCTUnwrap(try overview()["sessions"] as? [[String: Any]])
            return Dictionary(uniqueKeysWithValues: list.map { ($0["id"] as! String, $0) })
        }

        XCTAssertNil(try overview()["detail"])                   // no store (tests, guests): nothing said
        server.detail = d
        XCTAssertEqual(try overview()["detail"] as? String, "kurz")
        XCTAssertNil(try overview()["resumeLine"])               // on: omitted
        XCTAssertNil(try rows()["a"]?["detail"])

        store.set("0", .resumeLine)
        d.set(id: nil, level: "mittel")
        d.set(id: "a", level: "lang")
        XCTAssertEqual(try overview()["resumeLine"] as? Bool, false)
        XCTAssertEqual(try overview()["detail"] as? String, "mittel")
        XCTAssertEqual(try rows()["a"]?["detail"] as? String, "lang")
        XCTAssertNil(try rows()["b"]?["detail"])                 // uses the default: no own level

        let guest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(server.sessionsJSON(only: "a").utf8)) as? [String: Any])
        XCTAssertNil(guest["detail"])
        XCTAssertNil(guest["resumeLine"])
        XCTAssertNil((guest["sessions"] as? [[String: Any]])?.first?["detail"])
    }

    // A resume with no dialog answer (no pipeline here; Rückmeldung off takes the same path):
    // the default instruction, with the note when it is due.
    func testTheResumeInstructionCarriesTheNote() throws {
        let d = DetailStore(store: .memory(), file: nil)
        let server = ControlServer(sessions: SessionRegistry(phase: { "idle" }, daily: DailyStats()))
        server.detail = d
        func presence(_ state: String) -> [String: Any] {
            let body = #"{"session_id":"a","label":"Demo","project":"","cwd":"/x/a","state":"\#(state)","usage":null,"tasks":[]}"#
            let r = server.handle(HTTPRequest(method: "POST", path: "/presence", body: Data(body.utf8)))
            return (try? JSONSerialization.jsonObject(with: Data(r.1.utf8)) as? [String: Any]) ?? [:]
        }
        func resume() -> String? {
            XCTAssertEqual(server.handle(HTTPRequest(method: "POST", path: "/resume", body: Data(#"{"id":"a"}"#.utf8))).0, 200)
            let got = presence("idle")["instruction"] as? String
            _ = presence("working"); _ = presence("idle")      // done → parked again
            return got
        }
        _ = presence("idle")
        d.set(id: "a", level: "lang")
        XCTAssertEqual(resume(), "Wir machen weiter.\n\n" + lang)
        d.set(id: "a", level: "")
        XCTAssertEqual(resume(), "Wir machen weiter.\n\n" + kurz)
        XCTAssertEqual(resume(), "Wir machen weiter.")
    }
}
