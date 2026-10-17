import XCTest
@testable import Parley

final class SlidesTests: XCTestCase {
    func testTimesKindsAndParsing() throws {
        let timed = Captions.Timed(words: ["Der", "Export", "ist", "drin."], starts: [0, 0.4, 0.9, 1.2], end: 1.8)
        let specs = [SlideSpec(word: 1, image: "last", title: "Export"),
                     SlideSpec(word: 4, chart: "bar", labels: "Grün, Rot", values: "24,2.5", title: "Tests"),
                     SlideSpec(word: 2, metric: "98 %", note: "+3 %"),
                     SlideSpec(word: 0, text: "Gebaut: CSV")]
        let items = Slides.items(specs, timed: timed, prefix: "s")
        XCTAssertEqual(items.map(\.kind), ["image", "chart", "metric", "text"])
        XCTAssertEqual(items.map(\.at), [0.4, 1.8, 0.9, 0])          // the word's start; past the end → end
        XCTAssertEqual(items[1].labels, ["Grün", "Rot"])
        XCTAssertEqual(items[1].values, [24, 2.5])
        XCTAssertEqual(items.map(\.id), ["s-0", "s-1", "s-2", "s-3"])
        XCTAssertEqual(Slides.items(specs, timed: nil, prefix: "s").map(\.at), [0, 0, 0, 0])
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Slides.frame(items).utf8)) as? [String: Any])
        XCTAssertEqual(frame["t"] as? String, "slides")
        XCTAssertEqual((frame["items"] as? [[String: Any]])?.count, 4)
    }

    func testImageSources() throws {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let line = #"{"type":"user","uuid":"r1","message":{"role":"user","content":[{"type":"tool_result","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(png)"}}]}]}}"#
        try (line + "\n").write(to: dir.appendingPathComponent("p/sess.jsonl"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Slides.image("last", session: "sess", root: dir)?.prefix(2), Data([0xFF, 0xD8]))
        XCTAssertNil(Slides.image("last-2", session: "sess", root: dir))     // only one image
        let file = dir.appendingPathComponent("shot.png")
        try XCTUnwrap(Data(base64Encoded: png)).write(to: file)
        XCTAssertEqual(Slides.image(file.path, session: "", root: dir)?.prefix(2), Data([0xFF, 0xD8]))
        XCTAssertNil(Slides.image(dir.appendingPathComponent("p/sess.jsonl").path, session: "", root: dir))   // not an image
    }
}
