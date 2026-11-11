import XCTest
@testable import Parley

// A dictation of several minutes gets through: no 90-second cut, Whisper in pieces, each tried
// again, and what came through is kept when a piece is lost (Groq.swift, VAD.swift).
final class LongRecordingTests: XCTestCase {
    /// `seconds` of speech-like noise at 16 kHz, quiet for 0.4 s at each of `dips` (seconds in).
    private func speech(_ seconds: Double, dips: [Double] = []) -> [Int16] {
        var rng = SystemRandomNumberGenerator()
        var s = (0..<Int(seconds * 16000)).map { _ in Int16.random(in: -6000...6000, using: &rng) }
        for d in dips {
            let from = Int(d * 16000)
            for i in from..<min(s.count, from + 6400) { s[i] = Int16.random(in: -20...20, using: &rng) }
        }
        return s
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [URLRequest] = []
        private var paused: [Double] = []
        func add(_ r: URLRequest) -> Int { lock.withLock { list.append(r); return list.count } }
        func wait(_ s: Double) { lock.withLock { paused.append(s) } }
        var requests: [URLRequest] { lock.withLock { list } }
        var pauses: [Double] { lock.withLock { paused } }
    }

    private func body(_ r: URLRequest) -> String { String(data: r.httpBody ?? Data(), encoding: .isoLatin1) ?? "" }

    // MARK: - the cap

    func testAReplyMayRunForMinutes() {
        XCTAssertEqual(UtteranceRecorder.maxSeconds, 600)
        XCTAssertEqual(PhoneListener.maxSeconds, 600)
        var rec = UtteranceRecorder()
        var ended: UtteranceRecorder.Step?
        let chunk = speech(0.1)
        for _ in 0..<(5 * 60 * 10) {                              // five minutes of talking, no pause
            if case .ended = rec.feed(chunk).step { ended = .ended("early"); break }
        }
        XCTAssertNil(ended)
        XCTAssertEqual(rec.duration, 300, accuracy: 0.5)
        XCTAssertEqual(rec.samples.count, 300 * 16000)            // every sample is still there
    }

    func testThePhoneListenerDoesNotCutAtNinetySeconds() async throws {
        final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 0) }
        final class Link: CallLink, @unchecked Sendable {
            let lock = NSLock()
            var sink: (@Sendable (Data) -> Void)?
            var callGeneration: Int { 1 }
            func isLive(_ generation: Int) -> Bool { true }
            func setAudioState(_ state: PhoneAudioState) {}
            func setAudioSink(_ s: (@Sendable (Data) -> Void)?) { lock.withLock { sink = s } }
            func sendAudio(_ frame: Data) {}
        }
        let clock = Clock()
        let link = Link()
        let listener = PhoneListener(link: link, now: { clock.t })
        let task = Task { await listener.record() }
        while link.lock.withLock({ link.sink }) == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        let frame = PCMFrames.bytes(speech(0.5))
        for _ in 0..<4 { listener.feed(frame) }                   // Sir is talking
        try await Task.sleep(nanoseconds: 50_000_000)
        clock.t += 91                                              // … past the old cap: still listening
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(link.lock.withLock { link.sink })
        clock.t += 520                                             // the watchdog, ten minutes in
        let outcome = await task.value
        guard case .finished(let wav) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(wav.count, 44 + 2 * 16000 * 2)             // what was said goes on
    }

    // MARK: - pieces

    func testWAVRoundTrip() {
        let s: [Int16] = [0, 1, -1, 32767, -32768, 1234]
        XCTAssertEqual(WAV.samples(WAV.encode(int16: s)), s)
        XCTAssertEqual(WAV.samples(Data()), [])
    }

    func testAShortRecordingIsOnePieceALongOneIsCutWhereItIsQuiet() {
        XCTAssertEqual(Chunker.split(speech(30)), [0..<(30 * 16000)])
        let five = speech(300, dips: [110, 225])                  // five minutes, two breaths
        let parts = Chunker.split(five)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts.first?.lowerBound, 0)
        XCTAssertEqual(parts.last?.upperBound, five.count)
        for (a, b) in zip(parts, parts.dropFirst()) { XCTAssertEqual(a.upperBound, b.lowerBound) }   // nothing dropped, nothing twice
        for p in parts { XCTAssertLessThanOrEqual(Double(p.count) / 16000, Chunker.maxSeconds + Chunker.tail) }
        XCTAssertEqual(Double(parts[0].upperBound) / 16000, 110.2, accuracy: 0.25)   // in the breath, not in a word
        XCTAssertEqual(Double(parts[1].upperBound) / 16000, 225.2, accuracy: 0.25)
    }

    // MARK: - transcription

    func testFiveMinutesArriveInOrderWithTheThreadKept() async {
        let wav = WAV.encode(int16: speech(300, dips: [110, 225]))
        let calls = Calls()
        let out = await Transcriber.run(wav: wav, apiKey: "k", send: { req in
            (200, Data("Teil \(calls.add(req)).".utf8))
        }, pause: { calls.wait($0) })
        XCTAssertEqual(out, Transcriber.Outcome(text: "Teil 1. Teil 2. Teil 3.", parts: 3, failed: 0, status: 0))
        XCTAssertEqual(calls.requests.count, 3)
        XCTAssertFalse(body(calls.requests[0]).contains(#"name="prompt""#))
        XCTAssertTrue(body(calls.requests[1]).contains("name=\"prompt\"\r\n\r\nTeil 1."))   // how the piece before ended
        for r in calls.requests { XCTAssertLessThan(r.httpBody?.count ?? 0, 5_000_000) }      // small requests
        XCTAssertEqual(calls.requests.first?.timeoutInterval, Transcriber.timeout)
    }

    func testAStumbleIsTriedAgain() async {
        let calls = Calls()
        let out = await Transcriber.run(wav: WAV.encode(int16: speech(5)), apiKey: "k", send: { req in
            switch calls.add(req) {
            case 1: return nil                                    // no connection
            case 2: return (503, Data("busy".utf8))
            default: return (200, Data("Jetzt.".utf8))
            }
        }, pause: { calls.wait($0) })
        XCTAssertEqual(out.text, "Jetzt.")
        XCTAssertEqual(out.failed, 0)
        XCTAssertEqual(calls.pauses, [1, 3])
    }

    func testALostPieceCostsThatPieceOnly() async {
        let wav = WAV.encode(int16: speech(300, dips: [110, 225]))
        let calls = Calls()
        let out = await Transcriber.run(wav: wav, apiKey: "k", send: { req in
            let n = calls.add(req)
            return (2...4).contains(n) ? (500, Data()) : (200, Data(n == 1 ? "Anfang.".utf8 : "Ende.".utf8))   // the middle one, three times
        }, pause: { calls.wait($0) })
        XCTAssertEqual(out.failed, 1)
        XCTAssertEqual(out.parts, 3)
        XCTAssertEqual(out.text, "Anfang. \(Transcriber.gap(seconds: 115)) Ende.")
        XCTAssertEqual(out.status, 500)
    }

    func testNothingThroughIsAFailureAndARefusalIsNotTriedAgain() async {
        let calls = Calls()
        let gone = await Transcriber.run(wav: WAV.encode(int16: speech(5)), apiKey: "k", send: { req in _ = calls.add(req); return nil },
                                         pause: { calls.wait($0) })
        XCTAssertNil(gone.text)
        XCTAssertEqual(gone.status, -1)
        XCTAssertEqual(calls.requests.count, 3)

        let refused = Calls()
        let no = await Transcriber.run(wav: WAV.encode(int16: speech(5)), apiKey: "k", send: { req in _ = refused.add(req); return (403, Data()) },
                                       pause: { refused.wait($0) })
        XCTAssertNil(no.text)
        XCTAssertEqual(no.status, 403)
        XCTAssertEqual(refused.requests.count, 1)
    }

    func testSilenceBetweenPiecesIsNotInvented() async {
        let out = await Transcriber.run(wav: WAV.encode(int16: speech(5)), apiKey: "k", send: { _ in (200, Data("Thank you.".utf8)) })
        XCTAssertEqual(out.text, "")                              // nothing said — not a failure
    }

    func testARecordingThatFailedIsKept() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("parley-failed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = WAV.encode(int16: speech(1))
        for i in 0..<12 { XCTAssertNotNil(FailedRecordings.keep(wav, in: dir, at: Date(timeIntervalSince1970: Double(1_760_000_000 + i)), keeping: 10)) }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, 10)                           // the newest ten
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(files[0])), wav)
    }
}
