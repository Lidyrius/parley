import XCTest
@testable import Parley

final class AppNewsTests: XCTestCase {
    private let json = Data(#"{"latest":78,"builds":[{"build":77,"text":"B"},{"build":78,"text":"A"},{"build":1}]}"#.utf8)

    func testParse() {
        let p = AppNews.parse(json)
        XCTAssertEqual(p?.latest, 78)
        XCTAssertEqual(p?.builds.map(\.number), [78, 77])   // newest first, broken rows skipped
        XCTAssertNil(AppNews.parse(Data("nope".utf8)))
    }

    func testNext() {
        let b = AppNews.parse(json)!.builds
        XCTAssertTrue(AppNews.next(phone: 78, latest: 78, builds: b, told: nil, offered: 0).line?.contains("Neu: A") == true)
        XCTAssertNil(AppNews.next(phone: 78, latest: 78, builds: b, told: 78, offered: 78).line)
        XCTAssertTrue(AppNews.next(phone: 77, latest: 78, builds: b, told: 77, offered: 0).line?.contains("Neu darin: A") == true)
        XCTAssertNil(AppNews.next(phone: 77, latest: 78, builds: b, told: 77, offered: 78).line)
        XCTAssertTrue(AppNews.next(phone: 78, latest: 78, builds: b, told: 76, offered: 78).line?.contains("A B") == true)
    }

    func testHelloBuild() {
        XCTAssertEqual(RelayFrame.parse(#"{"t":"hello","device":"iPhone","build":78}"#), .hello(device: "iPhone", build: 78))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"hello","device":"iPhone"}"#), .hello(device: "iPhone"))
    }
}
