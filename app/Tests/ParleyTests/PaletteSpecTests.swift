import XCTest
@testable import Parley

// POST /palette: a palette made by voice, checked and turned into the phone's `palette` frame.
final class PaletteSpecTests: XCTestCase {
    private let full = #"""
    {"name":" Apple ","note":"Systemfarben","colors":{"background":["#F2F2F7","#000000"],"card":["#ffffff","#1C1C1E"],
     "raised":["#E5E5EA","#2C2C2E"],"accent":["#007AFF","#0A84FF"],"waiting":"#FF9F0A","working":["#007AFF","#0A84FF"],
     "purple":["#AF52DE","#BF5AF2"],"idle":["#34C759","#30D158"],"stopped":["8E8E93"],"red":["#FF3B30","#FF453A"]}}
    """#

    func testAFullPaletteBecomesTheFrame() throws {
        guard case .success(let p) = PaletteSpec.frame(Data(full.utf8)) else { return XCTFail("rejected") }
        XCTAssertEqual(p.name, "Apple")
        let f = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(p.frame.utf8)) as? [String: Any])
        XCTAssertEqual(f["t"] as? String, "palette")
        XCTAssertEqual(f["alwaysDark"] as? Bool, false)
        let c = try XCTUnwrap(f["colors"] as? [String: [String]])
        XCTAssertEqual(c["card"], ["#FFFFFF", "#1C1C1E"])
        XCTAssertEqual(c["waiting"], ["#FF9F0A", "#FF9F0A"])     // one colour: both modes
        XCTAssertEqual(c["stopped"], ["#8E8E93", "#8E8E93"])
        XCTAssertEqual(c.count, 10)
    }

    func testWhatIsWrongIsSaid() {
        XCTAssertEqual(PaletteSpec.frame(Data("nope".utf8)).problem, .notJSON)
        XCTAssertEqual(PaletteSpec.frame(Data(#"{"colors":{}}"#.utf8)).problem, .noName)
        let partial = ##"{"name":"X","colors":{"background":"#000000","accent":"blue","red":["#1","#2"]}}"##
        guard case .colors(let missing, let invalid)? = PaletteSpec.frame(Data(partial.utf8)).problem else { return XCTFail("accepted") }
        XCTAssertEqual(invalid, ["accent", "red"])
        XCTAssertEqual(missing, ["card", "raised", "waiting", "working", "purple", "idle", "stopped"])
        XCTAssertTrue(PaletteSpec.message(.colors(missing: ["card"], invalid: ["red"])).contains("missing: card"))
    }

    func testTheRouteHandsItOnAndAnswers() throws {
        let server = ControlServer(sessions: SessionRegistry(), now: { Date() })
        var got: [String] = []
        server.onPalette = { name, _ in got.append(name) }
        let ok = server.handle(HTTPRequest(method: "POST", path: "/palette", body: Data(full.utf8)))
        XCTAssertEqual(ok.0, 200)
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ok.1.utf8)) as? [String: Any])["name"] as? String, "Apple")
        XCTAssertEqual(got, ["Apple"])
        XCTAssertEqual(server.handle(HTTPRequest(method: "POST", path: "/palette", body: Data("{}".utf8))).0, 400)
        XCTAssertEqual(got.count, 1)
    }

    func testThePhonesConfirmationAndHello() {
        XCTAssertEqual(RelayFrame.parse(#"{"t":"palette","saved":"Apple"}"#), .paletteSaved("Apple"))
        XCTAssertNil(RelayFrame.parse(#"{"t":"palette"}"#))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"hello","device":"iPhone"}"#), .hello)
    }
}

private extension Result where Failure == PaletteSpec.Problem {
    var problem: PaletteSpec.Problem? { if case .failure(let p) = self { p } else { nil } }
}
