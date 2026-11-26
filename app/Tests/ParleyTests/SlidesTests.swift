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

    func testFocusRefAndCloseUps() {
        XCTAssertEqual(Slides.focus("0.1, 0.2, 0.5, 0.3"), [0.1, 0.2, 0.5, 0.3])
        XCTAssertEqual(Slides.focus("10,20,50,30"), [0.1, 0.2, 0.5, 0.3])        // percent
        XCTAssertEqual(Slides.focus("0.8,0.9,0.5,0.5"), [0.8, 0.9, 0.2, 0.1])    // kept inside
        XCTAssertNil(Slides.focus("0.1,0.2,0.5"))
        XCTAssertNil(Slides.focus("0.1,0.2,0.01,0.3"))                            // too small
        XCTAssertNil(Slides.focus(nil))
        let specs = [SlideSpec(word: 0, image: "last", focus: "0,0,0.5,0.5"),
                     SlideSpec(word: 3, image: "last", focus: "0.5,0.5,0.5,0.5"),
                     SlideSpec(word: 5, image: "last-2"),
                     SlideSpec(word: 6, text: "x", focus: "0,0,1,1")]
        let items = Slides.items(specs, timed: nil, prefix: "s")
        XCTAssertEqual(items.map(\.ref), [nil, "s-0", nil, nil])
        XCTAssertNil(items[3].focus)                                               // not an image
        let jobs = Slides.imageJobs(specs, items)
        XCTAssertEqual(jobs.map(\.key), ["s-0", "s-0.hd", "s-1.hd", "s-2"])
        let c = Slides.closeUp([0.5, 0.5, 0.5, 0.5])
        XCTAssertEqual(c.maxX, 1, accuracy: 1e-9)
        XCTAssertEqual(c.minX, 0.44, accuracy: 1e-9)
    }

    func testCroppedJPEG() throws {
        // 4×4 PNG, cropped to its right half → a JPEG 2 px wide
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertNil(Transcript.jpeg(png, crop: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)))   // under 8 px: nothing
        let big = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let jpeg = try XCTUnwrap(Transcript.jpeg(try XCTUnwrap(big.representation(using: .png, properties: [:])),
                                                 crop: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)))
        XCTAssertEqual(NSBitmapImageRep(data: jpeg)?.pixelsWide, 32)
    }
}
