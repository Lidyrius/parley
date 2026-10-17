import XCTest
@testable import Parley

// Barge-in at the Mac: Sir's words count, Parley's own echo doesn't (same rule as the phone).
final class BargeTests: XCTestCase {
    func testSirNotTheEcho() {
        let spoken = Set(Barge.tokens("Die Tests sind grün, Sir. Einen Moment noch, ich deploye."))
        XCTAssertFalse(Barge.isInterruption("die tests sind grün", spoken: spoken))     // echo
        XCTAssertFalse(Barge.isInterruption("einen Moment", spoken: spoken))            // its own "Moment"
        XCTAssertTrue(Barge.isInterruption("Stopp", spoken: spoken))
        XCTAssertTrue(Barge.isInterruption("nein mach erst staging", spoken: spoken))    // two foreign words
        XCTAssertFalse(Barge.isInterruption("Sir grün", spoken: spoken))
        XCTAssertTrue(Barge.isInterruption("Wärte", spoken: []))                        // folded: "warte"
    }
}
