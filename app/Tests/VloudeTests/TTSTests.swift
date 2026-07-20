import XCTest
@testable import Vloude

final class ElevenLabsRequestTests: XCTestCase {
    func testStreamRequestShape() {
        let req = ElevenLabs.streamRequest(
            text: "hallo welt",
            config: .init(apiKey: "sk_test", voiceID: "VOICE123"))
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/v1/text-to-speech/VOICE123/stream")
        XCTAssertEqual(req.url?.query, "output_format=pcm_24000")
        XCTAssertEqual(req.value(forHTTPHeaderField: "xi-api-key"), "sk_test")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try! JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        XCTAssertEqual(body["text"] as? String, "hallo welt")
        XCTAssertEqual(body["model_id"] as? String, "eleven_flash_v2_5")
    }
}

final class PCMConversionTests: XCTestCase {
    func testInt16LEtoFloat() {
        // samples: 0, 32767 (max), -32768 (min), -1
        let bytes: [UInt8] = [0x00, 0x00,  0xFF, 0x7F,  0x00, 0x80,  0xFF, 0xFF]
        let f = PCM.int16LEtoFloat(Data(bytes))
        XCTAssertEqual(f.count, 4)
        XCTAssertEqual(f[0], 0.0, accuracy: 1e-6)
        XCTAssertEqual(f[1], 32767.0 / 32768.0, accuracy: 1e-6)
        XCTAssertEqual(f[2], -1.0, accuracy: 1e-6)
        XCTAssertEqual(f[3], -1.0 / 32768.0, accuracy: 1e-6)
    }

    func testOddByteIgnoredByCount() {
        // 3 bytes -> only 1 whole sample decoded
        let f = PCM.int16LEtoFloat(Data([0x00, 0x00, 0x7F]))
        XCTAssertEqual(f.count, 1)
    }
}
