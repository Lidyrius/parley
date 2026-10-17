import XCTest
@testable import Parley

final class CaptionsTests: XCTestCase {
    // Tone for `on` seconds, silence for `off` — at 24 kHz, as Google delivers it.
    private func speech(_ parts: [(on: Double, off: Double)]) -> Data {
        var samples: [Int16] = []
        for p in parts {
            samples += (0..<Int(p.on * 24000)).map { Int16(12000 * sin(Double($0) * 2 * .pi * 220 / 24000)) }
            samples += [Int16](repeating: 0, count: Int(p.off * 24000))
        }
        return PCMFrames.bytes(samples)
    }

    func testPausesAnchorThePunctuation() throws {
        let pcm = speech([(0.5, 0.3), (0.8, 0.3), (0.4, 0)])
        let t = try XCTUnwrap(Captions.timings(text: "Hallo Sir. Der Export ist fertig, wirklich.", pcm: pcm, sampleRate: 24000))
        XCTAssertEqual(t.words.count, 7)
        XCTAssertEqual(t.starts[0], 0, accuracy: 0.02)
        XCTAssertEqual(t.starts[2], 0.8, accuracy: 0.02)        // "Der" right after the first pause
        XCTAssertEqual(t.starts[6], 1.9, accuracy: 0.02)        // "wirklich." after the second
        XCTAssertEqual(t.end, 2.3, accuracy: 0.02)
        XCTAssertEqual(t.starts, t.starts.sorted())
    }

    func testRateScalesAndSilenceIsNil() throws {
        let pcm = speech([(1.0, 0)])
        let t = try XCTUnwrap(Captions.timings(text: "eins zwei", pcm: pcm, sampleRate: 24000, rate: 2))
        XCTAssertEqual(t.end, 0.5, accuracy: 0.02)
        XCTAssertNil(Captions.timings(text: "eins", pcm: Data(count: 4800), sampleRate: 24000))
        XCTAssertNil(Captions.timings(text: " ", pcm: pcm, sampleRate: 24000))
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Captions.frame(t).utf8)) as? [String: Any])
        XCTAssertEqual(frame["t"] as? String, "caption")
        XCTAssertEqual(frame["words"] as? [String], ["eins", "zwei"])
        XCTAssertEqual((frame["at"] as? [Double])?.count, 2)
    }

    // PARLEY_GOOGLE_KEY=… PARLEY_GOOGLE_VOICE=… swift test --filter testRealGoogleLine
    func testRealGoogleLine() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["PARLEY_GOOGLE_KEY"], let voice = env["PARLEY_GOOGLE_VOICE"] else { throw XCTSkip("no key") }
        let text = "Erledigt, Sir: Die Session-Ansicht sieht jetzt aus wie in der Claude-App. Build zehn ist bei TestFlight, bitte einmal aktualisieren."
        let (data, _) = try await URLSession.shared.data(for: GoogleTTS.request(text: text, apiKey: key, voice: voice))
        let pcm = try XCTUnwrap(GoogleTTS.pcm(from: data))
        let t = try XCTUnwrap(Captions.timings(text: text, pcm: pcm, sampleRate: 24000))
        print("audio", Double(pcm.count) / 48000, "s")
        for (w, s) in zip(t.words, t.starts) { print(String(format: "%6.2f  %@", s, w)) }
        print("end", t.end)
    }
}

