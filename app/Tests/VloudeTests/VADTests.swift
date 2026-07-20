import XCTest
@testable import Vloude

final class LevelTests: XCTestCase {
    func testRMSOfConstant() {
        XCTAssertEqual(Level.rms([0.5, -0.5, 0.5, -0.5]), 0.5, accuracy: 1e-6)
    }
    func testRMSEmptyIsZero() {
        XCTAssertEqual(Level.rms([]), 0)
    }
    func testSilenceIsFloor() {
        XCTAssertEqual(Level.dB(0), -120)
    }
    func testFullScaleIsZeroDB() {
        XCTAssertEqual(Level.dB(1.0), 0, accuracy: 1e-4)
    }
}

final class SilenceVADTests: XCTestCase {
    func testWaitsBeforeSpeech() {
        var v = SilenceVAD(speechThresholdDB: -40, trailingSilence: 1.2)
        // quiet before any speech -> keep waiting, never ends
        for _ in 0..<100 {
            XCTAssertEqual(v.process(rmsDB: -60, duration: 0.1), .waiting)
        }
        XCTAssertFalse(v.started)
    }

    func testEndsAfterTrailingSilence() {
        var v = SilenceVAD(speechThresholdDB: -40, trailingSilence: 1.2)
        XCTAssertEqual(v.process(rmsDB: -10, duration: 0.1), .speaking) // speech starts
        // 11 quiet buffers of 0.1s = 1.1s < 1.2s -> still speaking
        for _ in 0..<11 { XCTAssertEqual(v.process(rmsDB: -80, duration: 0.1), .speaking) }
        // one more crosses 1.2s
        XCTAssertEqual(v.process(rmsDB: -80, duration: 0.1), .ended)
    }

    func testSpeechResetsSilenceTimer() {
        var v = SilenceVAD(speechThresholdDB: -40, trailingSilence: 0.95)
        _ = v.process(rmsDB: -10, duration: 0.1)                 // start
        for _ in 0..<9 { _ = v.process(rmsDB: -80, duration: 0.1) } // 0.9s silence
        XCTAssertEqual(v.process(rmsDB: -10, duration: 0.1), .speaking) // speech again -> reset
        XCTAssertEqual(v.silenceElapsed, 0, accuracy: 1e-9)
        for _ in 0..<9 { XCTAssertEqual(v.process(rmsDB: -80, duration: 0.1), .speaking) } // 0.9s < 0.95
        XCTAssertEqual(v.process(rmsDB: -80, duration: 0.1), .ended) // crosses 0.95
    }
}

final class WAVTests: XCTestCase {
    func testHeaderFields() {
        let wav = WAV.encode(int16: [0, 1, -1, 32767], sampleRate: 16000)
        XCTAssertEqual(wav.count, 44 + 8)              // header + 4 samples * 2 bytes
        XCTAssertEqual(String(data: wav.subdata(in: 0..<4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: wav.subdata(in: 12..<16), encoding: .ascii), "fmt ")
        // sample rate at offset 24 (LE u32)
        let sr = wav.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        XCTAssertEqual(sr, 16000)
        // bits per sample at offset 34 (LE u16)
        let bits = wav.subdata(in: 34..<36).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
        XCTAssertEqual(bits, 16)
        XCTAssertEqual(String(data: wav.subdata(in: 36..<40), encoding: .ascii), "data")
    }
}

final class GroqRequestTests: XCTestCase {
    func testRequestShape() {
        let wav = WAV.encode(int16: [1, 2, 3], sampleRate: 16000)
        let req = Groq.transcriptionRequest(wav: wav, apiKey: "gsk_x", boundary: "BOUND")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "https://api.groq.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer gsk_x")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=BOUND")
        let body = String(data: req.httpBody!, encoding: .isoLatin1)!
        XCTAssertTrue(body.contains(#"name="model""#))
        XCTAssertTrue(body.contains("whisper-large-v3-turbo"))
        XCTAssertTrue(body.contains(#"filename="reply.wav""#))
        XCTAssertTrue(body.contains("--BOUND--"))
    }
}
