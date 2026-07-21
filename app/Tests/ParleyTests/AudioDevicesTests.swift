import XCTest
@testable import Parley

final class AudioDevicesTests: XCTestCase {
    // Regression: hasInput() used AudioBufferList.allocate(maximumBuffers:), which traps
    // on output-only devices (count 0). Enumerating must not crash.
    func testInputDevicesDoesNotCrash() {
        let devices = AudioDevices.inputDevices()
        // Every returned device must have a non-empty UID we can resolve back.
        for d in devices {
            XCTAssertFalse(d.uid.isEmpty, "input device \(d.name) has empty UID")
            XCTAssertEqual(AudioDevices.deviceID(forUID: d.uid), d.id)
        }
    }
}
