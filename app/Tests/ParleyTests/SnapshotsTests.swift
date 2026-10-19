import XCTest
@testable import Parley

// Snapshots: keep the running sessions under a name, open them again — running ones left alone,
// past ones resumed, lost ones started anew in their folder under the same name.
final class SnapshotsTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_760_000_000) }
    private var clock = Clock()
    private var reg: SessionRegistry!
    private var server: ControlServer!
    private var starts: [String] = []
    private var resumed: [String?] = []
    private var dir = ""
    private let past = "11111111-2222-3333-4444-555555555555"   // has a transcript
    private let lost = "66666666-7777-8888-9999-000000000000"   // has none

    override func setUpWithError() throws {
        let c = clock
        reg = SessionRegistry(now: { c.t }, phase: { "idle" }, daily: DailyStats(now: { c.t }))
        server = ControlServer(sessions: reg, now: { c.t })
        server.starter = { [unowned self] folder, resume, _ in self.starts.append(folder); self.resumed.append(resume) }
        server.parleyStartRunning = { _ in false }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parley-snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("transcripts/p"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.appendingPathComponent("transcripts/p/\(past).jsonl").path, contents: Data())
        server.transcripts = url.appendingPathComponent("transcripts")
        server.snapshotsFile = url.appendingPathComponent("snapshots.json")
        dir = Zentrale.normalize(url.path)
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    private func post(_ path: String, _ json: String) -> (Int, [String: Any]) {
        let (code, body) = server.handle(HTTPRequest(method: "POST", path: path, body: Data(json.utf8)))
        return (code, (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:])
    }

    private func presence(_ id: String, _ label: String) {
        _ = post("/presence", #"{"session_id":"\#(id)","label":"\#(label)","cwd":"\#(dir)","state":"idle"}"#)
    }

    private func results(_ id: String) -> [String] {
        ((post("/snapshots/open", #"{"id":"\#(id)"}"#).1["results"] as? [[String: Any]]) ?? []).map { "\($0["name"]!) \($0["result"]!)" }
    }

    func testKeepThenOpenRunningResumedStarted() throws {
        presence(past, "Website")
        presence(lost, "Shop")
        presence("other", "Zentrale")
        let (code, saved) = post("/snapshots", #"{"name":"Kunde Müller","ids":["\#(past)","\#(lost)"]}"#)
        XCTAssertEqual(code, 200)
        let snap = try XCTUnwrap(saved["snapshot"] as? [String: Any])
        let id = try XCTUnwrap(snap["id"] as? String)
        XCTAssertEqual((snap["sessions"] as? [[String: Any]])?.map { $0["cwd"] as? String }, [dir, dir])
        XCTAssertTrue(reg.json().contains(#""name":"Kunde Müller""#))            // rides along to the phone

        XCTAssertEqual(results(id), ["Website running", "Shop running"])       // both still run: left alone
        XCTAssertEqual(starts, [])

        clock.t += 30                                                          // both gone
        XCTAssertEqual(results(id), ["Website resumed", "Shop started"])
        XCTAssertEqual(starts, [dir, dir])                                     // two in one folder, both start
        XCTAssertEqual(resumed, [past, nil])
        XCTAssertEqual(results(id), ["Website running", "Shop running"])       // starts on the way: not twice
        XCTAssertEqual(starts.count, 2)

        XCTAssertEqual(reg.name(of: past), "Website")                         // the resumed one keeps its name
    }

    func testSameNameReplacesAllRunningByDefaultDeleteAndPersist() throws {
        presence(past, "Website")
        XCTAssertEqual(post("/snapshots", #"{"name":"Kunde"}"#).0, 200)        // no ids: every running session
        presence(lost, "Shop")
        XCTAssertEqual(post("/snapshots", #"{"name":" kunde "}"#).0, 200)      // same name again: replaced
        let list = try XCTUnwrap(Snapshots.load(server.snapshotsFile))
        XCTAssertEqual(list.map(\.name), ["kunde"])
        XCTAssertEqual(list[0].sessions.map(\.name), ["Shop", "Website"])

        XCTAssertEqual(post("/snapshots", #"{"name":""}"#).0, 400)
        XCTAssertEqual(post("/snapshots/open", #"{"id":"nope"}"#).0, 404)
        XCTAssertEqual(post("/snapshots/delete", #"{"id":"\#(list[0].id)"}"#).0, 200)
        XCTAssertTrue(Snapshots.load(server.snapshotsFile).isEmpty)
        XCTAssertFalse(reg.json().contains("kunde"))
    }

    func testPhoneFrames() {
        XCTAssertEqual(RelayFrame.parse(#"{"t":"snapshot","op":"save","name":"Kunde","ids":["a"]}"#), .snapshotSave(name: "Kunde", ids: ["a"]))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"snapshot","op":"save","name":"Kunde"}"#), .snapshotSave(name: "Kunde", ids: nil))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"snapshot","op":"open","id":"x"}"#), .snapshotOpen("x"))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"snapshot","op":"delete","id":"x"}"#), .snapshotDelete("x"))
        XCTAssertNil(RelayFrame.parse(#"{"t":"snapshot","op":"save","name":" "}"#))
        XCTAssertNil(RelayFrame.parse(#"{"t":"snapshot","op":"open"}"#))
        let s = Snapshot(id: "x", name: "Kunde", at: Date(), sessions: [])
        let f = Snapshots.frame(s, [Snapshots.Outcome(id: "a", name: "Shop", result: "started")])
        let o = (try? JSONSerialization.jsonObject(with: Data(f.utf8))) as? [String: Any]
        XCTAssertEqual(o?["t"] as? String, "snapshot")
        XCTAssertEqual((o?["results"] as? [[String: String]])?.first, ["id": "a", "name": "Shop", "result": "started"])
    }
}
