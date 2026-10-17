import XCTest
@testable import Parley

final class ClassifierTests: XCTestCase {
    private func response(_ content: String) -> Data {
        Data(#"{"choices":[{"message":{"role":"assistant","content":"\#(content)"}}]}"#.utf8)
    }

    func testParsesReplyPick() {
        XCTAssertEqual(Classifier.parseReply(response("2"), count: 3), 1)
        XCTAssertNil(Classifier.parseReply(response("0"), count: 3))
        XCTAssertNil(Classifier.parseReply(response("4"), count: 3))
        XCTAssertNil(Classifier.parseReply(response("keine"), count: 3))
        let body = String(data: Classifier.replyRequest(text: "Ja", options: ["Zustimmung", "Ablehnung"], apiKey: "k").httpBody!, encoding: .utf8)!
        XCTAssertTrue(body.contains("1. Zustimmung") && body.contains("2. Ablehnung"))
    }

    func testDecodesTurnReplies() throws {
        let t = try JSONDecoder().decode(TurnPayload.self, from: Data(#"{"event":"turn","session_id":"s","cwd":"/p","project":"p","tmux_pane":"","speak":"x","replies":[{"on":"Ja","say":"Sehr wohl.","listen":false}]}"#.utf8))
        XCTAssertEqual(t.replies, [Reply(on: "Ja", say: "Sehr wohl.", listen: false)])
    }

    func testParsesEachIntent() {
        XCTAssertEqual(Classifier.parse(response("FEATURE")), .feature)
        XCTAssertEqual(Classifier.parse(response("BUG")), .bug)
        XCTAssertEqual(Classifier.parse(response("RESEARCH")), .research)
        XCTAssertEqual(Classifier.parse(response("QUESTION")), .question)
        XCTAssertEqual(Classifier.parse(response("STOP")), .stop)
        XCTAssertEqual(Classifier.parse(response("CONTINUE")), .cont)
        XCTAssertEqual(Classifier.parse(response("OTHER")), .other)
    }

    func testParsesCombosBeforeSubstrings() {
        // Must not be shadowed by FEATURE / BUG.
        XCTAssertEqual(Classifier.parse(response("FEATURE_RESEARCH")), .featureResearch)
        XCTAssertEqual(Classifier.parse(response("BUG_FEATURE")), .bugFeature)
    }

    func testParsesWithSurroundingText() {
        XCTAssertEqual(Classifier.parse(response("The intent is BUG.")), .bug)
        XCTAssertEqual(Classifier.parse(response("continue")), .cont)   // case-insensitive
    }

    func testUnknownFallsBackToOther() {
        XCTAssertEqual(Classifier.parse(response("banana")), .other)
        XCTAssertEqual(Classifier.parse(Data("not json".utf8)), .other)
    }

    func testRequestShape() {
        let req = Classifier.request(text: "fix the crash", apiKey: "k")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        let body = req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(body?["model"] as? String, Classifier.model)
    }
}
