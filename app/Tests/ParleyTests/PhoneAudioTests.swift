import XCTest
@testable import Parley

// Call audio (docs/IPHONE.md, protocol v2): framing, resampling, pacing, time stretch, the
// phone voice/listener against a fake call link — and the call ending mid-turn.

final class FakeLink: CallLink, @unchecked Sendable {
    private let lock = NSLock()
    private var _live = true
    private var _frames: [Data] = []
    private var _states: [PhoneAudioState] = []
    private var _sink: (@Sendable (Data) -> Void)?
    var dieAfterFrames: Int?
    var bargeAfterFrames: Int?          // Sir talks over Parley after this many frames
    var down = PhoneAudioFormat.sampleRate
    var barged: Bool { lock.withLock { bargeAfterFrames.map { _frames.count >= $0 } ?? false } }
    var downRate: Int { down }

    var live: Bool { get { lock.withLock { _live } } set { lock.withLock { _live = newValue } } }
    var frames: [Data] { lock.withLock { _frames } }
    var states: [PhoneAudioState] { lock.withLock { _states } }
    var sink: (@Sendable (Data) -> Void)? { lock.withLock { _sink } }

    var callGeneration: Int { 1 }
    func isLive(_ generation: Int) -> Bool { lock.withLock { _live && generation == 1 } }
    func sendAudio(_ frame: Data) {
        lock.withLock {
            _frames.append(frame)
            if let n = dieAfterFrames, _frames.count >= n { _live = false }
        }
    }
    func setAudioState(_ state: PhoneAudioState) { lock.withLock { _states.append(state) } }
    func setAudioSink(_ sink: (@Sendable (Data) -> Void)?) { lock.withLock { _sink = sink } }
}

func sine(_ hz: Double, rate: Double, seconds: Double, amp: Float = 0.5) -> [Float] {
    (0..<Int(rate * seconds)).map { amp * Float(sin(2 * .pi * hz * Double($0) / rate)) }
}

func rms(_ x: ArraySlice<Float>) -> Float { Level.rms(Array(x)) }

final class PCMFramesTests: XCTestCase {
    func testFramesAreLittleEndian640ByteChunksWithARest() {
        let samples: [Int16] = (0..<700).map { Int16($0 - 350) }
        let (frames, rest) = PCMFrames.frames(samples)
        XCTAssertEqual(frames.count, 2)
        XCTAssertTrue(frames.allSatisfy { $0.count == PhoneAudioFormat.frameBytes })
        XCTAssertEqual(rest.count, 60)
        XCTAssertEqual(Array(frames[0].prefix(4)), [0xA2, 0xFE, 0xA3, 0xFE])   // -350, -349 little-endian
        XCTAssertEqual(PCMFrames.samples(frames[0] + frames[1]) + rest, samples)
    }

    func testFloatConversionClips() {
        XCTAssertEqual(PCMFrames.int16([2, -2, 0.5, 0]), [32767, -32767, 16384, 0])
        XCTAssertEqual(PCMFrames.samples(Data([0x01, 0x00, 0xFF])), [1])   // odd byte ignored
    }
}

final class ResamplerTests: XCTestCase {
    func testLengthAndChunkedEqualsOneBlock() {
        let input = sine(1000, rate: 24000, seconds: 1)
        var whole = Resampler(from: 24000, to: 16000)
        let a = whole.process(input) + whole.flush()
        XCTAssertEqual(a.count, 16000)

        var chunked = Resampler(from: 24000, to: 16000)
        var b: [Float] = []
        let sizes = [1, 7, 480, 1000, 333]
        var i = 0, n = 0
        while i < input.count {
            let k = min(sizes[n % sizes.count], input.count - i)
            b += chunked.process(Array(input[i..<(i + k)]))
            i += k
            n += 1
        }
        b += chunked.flush()
        XCTAssertEqual(a, b)
    }

    func testKeepsTheVoiceBandAndRejectsAliases() {
        func gain(_ hz: Double) -> Float {
            var r = Resampler(from: 24000, to: 16000)
            let out = r.process(sine(hz, rate: 24000, seconds: 1)) + r.flush()
            return rms(out[2000..<14000]) / (0.5 / Float(2).squareRoot())
        }
        XCTAssertEqual(gain(300), 1, accuracy: 0.03)
        XCTAssertEqual(gain(3000), 1, accuracy: 0.03)
        XCTAssertLessThan(gain(10_000), 0.01)    // above 8 kHz: would fold back to 6 kHz
    }

    func testSameRateIsIdentity() {
        var r = Resampler(from: 16000, to: 16000)
        XCTAssertTrue(r.isIdentity)
        XCTAssertEqual(r.process([0.1, -0.2]), [0.1, -0.2])
        XCTAssertEqual(r.flush(), [])
    }
}

final class FramePacerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1000)

    func testLeadThenOneFramePerTwentyMilliseconds() throws {
        var p = FramePacer(lead: 0.1)
        XCTAssertEqual(p.due(available: 1000, now: t0), 6)                         // 100 ms prebuffer + the frame due now
        XCTAssertEqual(p.due(available: 994, now: t0.addingTimeInterval(0.01)), 0)
        XCTAssertEqual(p.due(available: 994, now: t0.addingTimeInterval(0.02)), 1)
        for ms in stride(from: 30, through: 1000, by: 10) {                         // the 10 ms timer
            _ = p.due(available: 1000, now: t0.addingTimeInterval(Double(ms) / 1000))
        }
        XCTAssertEqual(p.total, 56)                                                 // 1 s real time + lead
        XCTAssertEqual(try XCTUnwrap(p.playedOut).timeIntervalSince(t0), 1.12, accuracy: 1e-6)
        XCTAssertEqual(p.due(available: 0, now: t0.addingTimeInterval(1.05)), 0)
    }

    func testReanchorsAfterAnUnderrunInsteadOfBursting() {
        var p = FramePacer(lead: 0.1)
        XCTAssertEqual(p.due(available: 6, now: t0), 6)                             // played out at t0 + 0.12
        let late = t0.addingTimeInterval(0.5)
        XCTAssertEqual(p.due(available: 40, now: late), 6)                          // not 25 at once
        XCTAssertEqual(p.anchor, late)
        XCTAssertEqual(p.total, 12)
        XCTAssertEqual(p.leadFrames, 5)
    }
}

final class TimeStretchTests: XCTestCase {
    func testShortensByTheRateAndKeepsTheSignal() throws {
        let stretch = try XCTUnwrap(TimeStretch(rate: 1.25))
        let input = sine(440, rate: 24000, seconds: 1)
        var out: [Float] = []
        for start in stride(from: 0, to: input.count, by: 4800) { out += stretch.process(Array(input[start..<(start + 4800)])) }
        XCTAssertEqual(out.count, 19200)                                            // 24000 / 1.25
        out += stretch.flush()
        XCTAssertGreaterThan(rms(out[4000..<16000]), 0.25)                          // ≈ 0.35: audible, not silence
    }
}

final class UtteranceRecorderTests: XCTestCase {
    func testNoSpeechEndsAfterEightSecondsWithAnEmptyWAV() {
        var r = UtteranceRecorder()
        let silence = [Int16](repeating: 0, count: 1600)   // 100 ms
        var step = UtteranceRecorder.Step.listening
        for _ in 0..<200 where step == .listening { step = r.feed(silence).step }
        XCTAssertEqual(step, .ended("no-speech"))
        XCTAssertEqual(r.duration, UtteranceRecorder.noSpeechTimeout, accuracy: 0.11)
        XCTAssertEqual(r.wav(endReason: "no-speech").count, 44)
    }

    func testBeepGraceThenSpeechThenSilenceEnds() {
        var r = UtteranceRecorder()
        let loud = PCMFrames.int16(sine(300, rate: 16000, seconds: 0.1, amp: 0.3))
        XCTAssertEqual(r.feed(loud).step, .listening)                              // in the grace window: ignored
        XCTAssertFalse(r.heardSpeech)
        for _ in 0..<5 { _ = r.feed([Int16](repeating: 0, count: 1600)) }
        for _ in 0..<10 { _ = r.feed(loud) }
        XCTAssertTrue(r.heardSpeech)
        var step = UtteranceRecorder.Step.listening
        for _ in 0..<30 where step == .listening { step = r.feed([Int16](repeating: 0, count: 1600)).step }
        XCTAssertEqual(step, .ended("vad-silence"))
    }
}

final class PhoneVoiceTests: XCTestCase {
    func testPlaysEverythingInRealTimeThenReturnsNil() async throws {
        let link = FakeLink()
        let voice = PhoneVoice(link: link, rate: 1)
        let pcm = PCMFrames.bytes(PCMFrames.int16(sine(440, rate: 24000, seconds: 0.2)))
        voice.enqueue(pcm.subdata(in: 0..<3001))                                    // odd split
        voice.enqueue(pcm.subdata(in: 3001..<pcm.count))
        let start = Date()
        let rest = await voice.finish(beep: true)
        XCTAssertNil(rest)
        // 0.2 s speech + 0.18 s beep at 16 kHz = 6080 samples = 19 frames.
        XCTAssertEqual(link.frames.count, 19)
        XCTAssertTrue(link.frames.allSatisfy { $0.count == 640 })
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.3)                  // paced, not burst
        XCTAssertEqual(link.states, [.speaking])
    }

    // A phone that asked for 24 kHz gets the TTS samples as they are: 960-byte frames, no resampling.
    func testHiFiPhoneGets24kHzUnchanged() async {
        let link = FakeLink()
        link.down = PhoneAudioFormat.hiFiRate
        let voice = PhoneVoice(link: link, rate: 1)
        let samples = PCMFrames.int16(sine(440, rate: 24000, seconds: 0.2))
        voice.enqueue(PCMFrames.bytes(samples))
        let rest = await voice.finish(beep: false)
        XCTAssertNil(rest)
        // 0.2 s speech + 20 ms silent marker at 24 kHz = 5280 samples = 11 frames of 480.
        XCTAssertEqual(link.frames.count, 11)
        XCTAssertTrue(link.frames.allSatisfy { $0.count == 960 })
        XCTAssertEqual(PCMFrames.samples(link.frames[0]), Array(samples.prefix(480)))   // bit-exact
    }

    // The call ends mid-line: what the phone did not play comes back for the Mac's speaker
    // (heard = sent minus the 13 frames of lead, 0.25 s, mapped back to 24 kHz).
    func testCallEndingMidLineHandsBackTheUnheardSpeech() async throws {
        let link = FakeLink()
        link.dieAfterFrames = 30
        let voice = PhoneVoice(link: link, rate: 1)
        let pcm = PCMFrames.bytes(PCMFrames.int16(sine(440, rate: 24000, seconds: 2)))
        voice.enqueue(pcm)
        let finished = await voice.finish(beep: true)
        let rest = try XCTUnwrap(finished)
        let heardFrames = Double(pcm.count - rest.count) / (320 * 1.5 * 2)
        XCTAssertEqual(heardFrames, 17, accuracy: 2)                                // 30 sent − 13 lead
        XCTAssertEqual(rest, pcm.subdata(in: (pcm.count - rest.count)..<pcm.count))
    }

    // Barge-in: Sir talks over Parley — the line stops at once, no beep, and nothing of it is
    // handed back for the Mac's speaker.
    func testBargeInStopsTheLineAndHandsNothingBack() async throws {
        let link = FakeLink()
        link.bargeAfterFrames = 20
        let voice = PhoneVoice(link: link, rate: 1)
        voice.enqueue(PCMFrames.bytes(PCMFrames.int16(sine(440, rate: 24000, seconds: 2))))
        let finished = await voice.finish(beep: true)
        XCTAssertNil(finished)
        XCTAssertLessThan(link.frames.count, 25)    // 2 s would be 100 frames + the beep
    }

    func testCallAlreadyGoneHandsBackEverything() async throws {
        let link = FakeLink()
        link.live = false
        let voice = PhoneVoice(link: link, rate: 1.2)
        let pcm = PCMFrames.bytes(PCMFrames.int16(sine(440, rate: 24000, seconds: 0.5)))
        voice.enqueue(pcm)
        let finished = await voice.finish(beep: false)
        let rest = try XCTUnwrap(finished)
        XCTAssertEqual(rest, pcm)
        XCTAssertEqual(link.frames.count, 0)
    }
}

final class PhoneListenerTests: XCTestCase {
    private func attached(_ link: FakeLink) async throws -> @Sendable (Data) -> Void {
        for _ in 0..<200 {
            if let s = link.sink { return s }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw XCTSkip("listener never attached")
    }

    private func frames(_ samples: [Int16]) -> [Data] { PCMFrames.frames(samples).frames }
    private func silence(_ s: Double) -> [Data] { frames([Int16](repeating: 0, count: Int(16000 * s))) }
    private func voice(_ s: Double) -> [Data] { frames(PCMFrames.int16(sine(300, rate: 16000, seconds: s, amp: 0.3))) }

    func testPhoneAudioRunsThroughTheVADAndEndsOnSilence() async throws {
        let link = FakeLink()
        let listener = PhoneListener(link: link)
        let task = Task { await listener.record() }
        let sink = try await attached(link)
        for f in silence(0.6) + voice(1) + silence(2.2) { sink(f) }
        let outcome = await task.value
        guard case .finished(let wav) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(wav.count, 44 + Int(16000 * 3.4) * 2, accuracy: 640 * 2)   // grace + speech + 1.8 s silence
        XCTAssertEqual(link.states, [.listening])
        XCTAssertNil(link.sink)
    }

    // The listener starts with what Sir already said (the phone's last seconds of mic).
    func testTheListenerStartsWithThePreroll() async throws {
        let link = FakeLink()
        let listener = PhoneListener(link: link)
        let preroll = voice(1)
        let task = Task { await listener.record(preroll: preroll) }
        let sink = try await attached(link)
        for f in silence(2.2) { sink(f) }                      // then silence ends the utterance
        let outcome = await task.value
        guard case .finished(let wav) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertGreaterThan(wav.count, 44 + 16000 * 2)        // the preroll's second of speech is in it
    }

    // Call ends before anything was said → the Mac takes over the listening.
    func testCallEndingBeforeSpeechSaysSo() async throws {
        let link = FakeLink()
        let listener = PhoneListener(link: link)
        let task = Task { await listener.record() }
        let sink = try await attached(link)
        for f in silence(0.6) { sink(f) }
        link.live = false
        let outcome = await task.value
        guard case .callEnded(let wav, let spoke) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(spoke)
        XCTAssertEqual(wav.count, 44)
    }

    // A reply that had started is kept.
    func testCallEndingMidReplyKeepsWhatWasSaid() async throws {
        let link = FakeLink()
        let listener = PhoneListener(link: link)
        let task = Task { await listener.record() }
        let sink = try await attached(link)
        for f in silence(0.6) + voice(0.5) { sink(f) }
        try await Task.sleep(nanoseconds: 50_000_000)
        link.live = false
        let outcome = await task.value
        guard case .callEnded(let wav, let spoke) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(spoke)
        XCTAssertEqual(wav.count, 44 + 17600 * 2)
    }

    func testNoFramesAtAllGivesUpLikeNoSpeech() async throws {
        final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 0) }
        let clock = Clock()
        let link = FakeLink()
        let listener = PhoneListener(link: link, now: { clock.t })
        let task = Task { await listener.record() }
        _ = try await attached(link)
        clock.t = clock.t.addingTimeInterval(UtteranceRecorder.noSpeechTimeout + 1.5)
        let outcome = await task.value
        XCTAssertEqual(outcome, .finished(WAV.encode(int16: [])))
    }

    func testNoCallNoListening() async {
        let link = FakeLink()
        link.live = false
        let outcome = await PhoneListener(link: link).record()
        XCTAssertEqual(outcome, .callEnded(Data(), spoke: false))
        XCTAssertEqual(link.states, [])
    }
}
