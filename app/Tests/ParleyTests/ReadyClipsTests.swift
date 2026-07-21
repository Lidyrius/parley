import XCTest
@testable import Parley

final class ReadyClipsTests: XCTestCase {
    func testPickEmptyIsNil() {
        XCTAssertNil(ReadyClips.pick(from: []))
    }

    func testPickReturnsMember() {
        let files = [URL(fileURLWithPath: "/a/ready_00.pcm"),
                     URL(fileURLWithPath: "/a/ready_01.pcm")]
        let picked = ReadyClips.pick(from: files)
        XCTAssertNotNil(picked)
        XCTAssertTrue(files.contains(picked!))
    }

    func testAllFiltersToPCM() {
        // Bundle may have zero clips (none committed); must not crash and returns
        // only .pcm entries (README.txt excluded).
        for url in ReadyClips.all() {
            XCTAssertEqual(url.pathExtension, "pcm")
        }
    }
}
