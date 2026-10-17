import XCTest
@testable import Parley

final class TranscriptTests: XCTestCase {
    private func line(_ obj: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: obj) }

    // 1×1 PNG
    private let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    private var lines: [Data] {
        [
            line(["type": "user", "uuid": "u1", "timestamp": "2026-10-17T10:00:00.000Z",
                  "message": ["role": "user", "content": "Bau bitte den Export ein."]]),
            line(["type": "assistant", "uuid": "a1", "message": ["role": "assistant", "content": [
                ["type": "thinking", "thinking": "hm"],
                ["type": "text", "text": "Erledigt.\n<reply on=\"ja\">Sehr wohl.</reply>\n<speak>Export ist drin, Sir.</speak>"],
                ["type": "tool_use", "name": "mcp__Claude_Browser__computer", "input": ["action": "screenshot"]],
            ]]]),
            line(["type": "user", "uuid": "r1", "message": ["role": "user", "content": [
                ["type": "tool_result", "content": [["type": "text", "text": "ok"],
                                                    ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png]]]],
            ]]]),
            line(["type": "user", "uuid": "v1", "isMeta": true, "message": ["role": "user",
                  "content": "Stop hook feedback:\nJa, passt.\n\n[Parley hat darauf bereits geantwortet: „Sehr wohl.“ – nicht wiederholen.]"]]),
            line(["type": "user", "uuid": "m1", "isMeta": true, "message": ["role": "user", "content": "<system-reminder>x</system-reminder>"]]),
            line(["type": "user", "uuid": "c1", "message": ["role": "user",
                  "content": "<command-name>/parley:voice</command-name><command-args></command-args>"]]),
            line(["type": "assistant", "uuid": "s1", "isSidechain": true, "message": ["content": [["type": "text", "text": "subagent"]]]]),
            line(["type": "attachment", "uuid": "x1"]),
        ]
    }

    func testItems() {
        let items = Transcript.items(lines)
        XCTAssertEqual(items.map(\.k), ["user", "assistant", "speak", "tool", "image", "voice", "user"])
        XCTAssertEqual(items.map(\.text), ["Bau bitte den Export ein.", "Erledigt.", "Export ist drin, Sir.",
                                           "computer · screenshot", nil, "Ja, passt.", "/parley:voice"])
        XCTAssertEqual(items[4].id, "r1#0")
        XCTAssertEqual(items[4].who, "assistant")
        XCTAssertEqual(items[0].at, 1_792_231_200_000)
    }

    func testSpeakOnlyTheLastTag() {
        let (body, spoken) = Transcript.split("Format: `<speak>…</speak>` am Ende.\n\n<speak-end>Fertig, Sir.</speak-end>")
        XCTAssertEqual(body, "Format: `<speak>…</speak>` am Ende.")
        XCTAssertEqual(spoken, "Fertig, Sir.")
        XCTAssertEqual(Transcript.split("Nur Text.").spoken, nil)
    }

    func testImageAndFrames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("proj"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("proj/sess-1.jsonl")
        try Data(lines.map { $0 + Data("\n".utf8) }.joined()).write(to: url)

        XCTAssertEqual(Transcript.file(for: "sess-1", root: dir)?.resolvingSymlinksInPath(), url.resolvingSymlinksInPath())
        XCTAssertNil(Transcript.file(for: "../proj/sess-1", root: dir))
        XCTAssertEqual(Transcript.items(Transcript.tailLines(url)).count, 7)
        let lastThree = lines.suffix(3).map { $0.count + 1 }.reduce(0, +)   // c1, s1, x1 (+ a cut-off m1)
        XCTAssertEqual(Transcript.items(Transcript.tailLines(url, bytes: lastThree + 10)).map(\.text), ["/parley:voice"])

        let jpeg = try XCTUnwrap(Transcript.image(in: url, key: "r1#0"))
        XCTAssertEqual(jpeg.prefix(2), Data([0xFF, 0xD8]))
        XCTAssertNil(Transcript.image(in: url, key: "a1#0"))           // not an image item
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Transcript.imageFrame(key: "r1#0", jpeg: jpeg).utf8)) as? [String: Any])
        XCTAssertEqual(frame["t"] as? String, "image")
        XCTAssertNotNil(Data(base64Encoded: frame["data"] as? String ?? ""))

        let latest = Transcript.page(url, before: nil)
        XCTAssertEqual(latest.items.count, 7)
        XCTAssertFalse(latest.more)
        let older = Transcript.page(url, before: "r1#0")             // the 4 items before the screenshot
        XCTAssertEqual(older.items.map(\.id), ["u1#0", "a1#0", "a1#1", "a1#2"])
        XCTAssertFalse(older.more)
        XCTAssertEqual(Transcript.page(url, before: "gone#0").items, [])

        let big = (0..<200).map { Transcript.Item(id: "i\($0)", k: "assistant", text: String(repeating: "x", count: 2000)) }
        let history = Transcript.historyFrame(session: "sess-1", items: big)
        XCTAssertLessThanOrEqual(history.utf8.count, Transcript.maxFrame)
        XCTAssertTrue(history.contains("\"i199\""))                    // the newest survive
        XCTAssertTrue(history.contains("\"more\":true"))              // trimmed → older exists
    }

    // PARLEY_TRANSCRIPT=<path to a real .jsonl> swift test --filter testRealTranscript
    func testRealTranscript() throws {
        guard let path = ProcessInfo.processInfo.environment["PARLEY_TRANSCRIPT"] else { throw XCTSkip("no PARLEY_TRANSCRIPT") }
        let url = URL(fileURLWithPath: path)
        let items = Transcript.items(Transcript.tailLines(url))
        for i in items { print("·", i.k, i.who ?? "", (i.text ?? i.id).prefix(100).replacingOccurrences(of: "\n", with: " ")) }
        if let key = ProcessInfo.processInfo.environment["PARLEY_KEY"] ?? items.last(where: { $0.k == "image" })?.id {
            let jpeg = Transcript.image(in: url, key: key)
            print("image", key, jpeg?.count ?? -1, "bytes")
            if let out = ProcessInfo.processInfo.environment["PARLEY_OUT"] { try jpeg?.write(to: URL(fileURLWithPath: out)) }
        }
        print("frame", Transcript.historyFrame(session: "x", items: items).utf8.count, "bytes")
    }
}
