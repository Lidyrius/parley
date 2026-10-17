import AVFAudio
import Foundation
import Testing
@testable import ParleyMobile

struct AudioTests {
    // MARK: - PCM16 packing

    @Test func wireFormatConstants() {
        #expect(PCM.frameSamples == 320)
        #expect(PCM.frameBytes == 640)
        #expect(PCM.format.sampleRate == 16_000 && PCM.format.channelCount == 1)
    }

    @Test func encodesLittleEndianInt16() {
        let data = PCM.encode([0, 0.5, -1, 1])
        #expect(data.count == 8)
        // 0 → 0x0000, 0.5 → 16384 (0x4000), −1 → −32767 (0x8001), 1 → 32767 (0x7FFF)
        #expect(Array(data) == [0x00, 0x00, 0x00, 0x40, 0x01, 0x80, 0xFF, 0x7F])
    }

    @Test func clampsOutOfRangeSamples() {
        #expect(PCM.decode(PCM.encode([1.7, -3])).map { ($0 * 32768).rounded() } == [32767, -32767])
    }

    @Test func decodesKnownBytes() {
        let samples = PCM.decode(Data([0x00, 0x80, 0xFF, 0x7F, 0x00, 0x00, 0x01]))  // odd trailing byte ignored
        #expect(samples == [-1, Float(32767) / 32768, 0])
    }

    @Test func roundTripStaysWithinOneStep() {
        let input = (0..<640).map { Float(sin(Double($0) * 0.05) * 0.9) }
        let output = PCM.decode(PCM.encode(input))
        #expect(output.count == input.count)
        #expect(zip(input, output).allSatisfy { abs($0 - $1) < 1.0 / 16_000 })
    }

    @Test func receivedFrameBecomesAPlayableBuffer() throws {
        let frame = PCM.encode([Float](repeating: 0.25, count: 320))
        let hiFi = try #require(PCM.buffer(Data(count: PCM.hiFiFrameBytes), format: PCM.playFormat))
        #expect(hiFi.frameLength == 480 && hiFi.format.sampleRate == 24_000)
        let buffer = try #require(PCM.buffer(frame))
        #expect(buffer.frameLength == 320)
        #expect(buffer.format == PCM.format)
        #expect(abs(buffer.floatChannelData![0][100] - 0.25) < 0.0001)
        #expect(PCM.buffer(Data()) == nil)
    }

    @Test func levels() {
        #expect(PCM.rms([Float]()) == 0)
        #expect(abs(PCM.rms([0.5, -0.5, 0.5, -0.5]) - 0.5) < 0.0001)
        #expect(PCM.level(rms: 0) == 0)
        #expect(PCM.level(rms: 1) == 1)
        #expect(PCM.level(rms: 0.001) == 0)  // −60 dBFS: below the floor
        #expect(abs(PCM.level(rms: pow(10, -25.0 / 20)) - 0.5) < 0.001)
    }

    // MARK: - Framing

    @Test func chunkerEmits640ByteFramesAndKeepsTheRest() {
        var chunker = FrameChunker()
        #expect(chunker.push([Float](repeating: 0.1, count: 300)).isEmpty)
        let frames = chunker.push([Float](repeating: 0.1, count: 700))
        #expect(frames.count == 3)
        #expect(frames.allSatisfy { $0.count == 640 })
        #expect(chunker.pendingSamples == 40)
        chunker.reset()
        #expect(chunker.pendingSamples == 0)
    }

    @Test func chunkingPreservesTheStream() {
        var chunker = FrameChunker()
        let input = (0..<1600).map { Float($0 % 200) / 200 - 0.5 }
        var frames: [Data] = []
        for start in stride(from: 0, to: input.count, by: 137) {  // odd-sized tap buffers
            frames += chunker.push(input[start..<min(start + 137, input.count)])
        }
        #expect(frames.count == 5)
        let joined = frames.reduce(into: Data()) { $0.append($1) }
        let output = PCM.decode(joined)
        #expect(output.count == 1600)
        #expect(zip(input, output).allSatisfy { abs($0 - $1) < 1.0 / 16_000 })
    }

    // MARK: - Resampling

    private func sine(_ hz: Double, rate: Double, seconds: Double, amplitude: Float = 0.5) -> [Float] {
        (0..<Int(rate * seconds)).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / rate)) }
    }

    private func buffer(_ samples: ArraySlice<Float>, rate: Double, channels: AVAudioChannelCount = 1) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        for c in 0..<Int(channels) {
            for (i, x) in samples.enumerated() { b.floatChannelData![c][i] = x }
        }
        b.frameLength = AVAudioFrameCount(samples.count)
        return b
    }

    /// Streams `input` through `resampler` in tap-sized chunks.
    private func stream(_ input: [Float], rate: Double, chunk: Int, channels: AVAudioChannelCount = 1, through resampler: Resampler) -> [Float] {
        var out: [Float] = []
        for start in stride(from: 0, to: input.count, by: chunk) {
            guard let converted = resampler.convert(buffer(input[start..<min(start + chunk, input.count)], rate: rate, channels: channels)) else { continue }
            out += UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength))
        }
        return out
    }

    /// Zero crossings per second ÷ 2 ≈ the frequency of a clean sine.
    private func frequency(_ samples: ArraySlice<Float>, rate: Double) -> Double {
        let crossings = zip(samples, samples.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        return Double(crossings) / 2 / (Double(samples.count) / rate)
    }

    @Test func micRateDownTo16kHz() throws {
        let mic = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let resampler = try #require(Resampler(from: mic, to: PCM.format))
        let out = stream(sine(440, rate: 48_000, seconds: 1), rate: 48_000, chunk: 480, through: resampler)
        // The converter's filter holds back a few samples; everything else comes out.
        #expect(abs(out.count - 16_000) < 100)
        let middle = out[2000..<14_000]
        #expect(abs(frequency(middle, rate: 16_000) - 440) < 5)
        #expect(abs(PCM.rms(middle) - 0.5 / Float(2).squareRoot()) < 0.02)
    }

    @Test func stereoIsDownmixedToMono() throws {
        let stereo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let resampler = try #require(Resampler(from: stereo, to: PCM.format))
        let out = stream(sine(300, rate: 48_000, seconds: 0.5), rate: 48_000, chunk: 1024, channels: 2, through: resampler)
        #expect(abs(out.count - 8000) < 100)
        #expect(abs(frequency(out[1000..<7000], rate: 16_000) - 300) < 5)
    }

    @Test func resamplingRoundTripKeepsTheSignal() throws {
        let rate44 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        let up = try #require(Resampler(from: PCM.format, to: rate44))
        let down = try #require(Resampler(from: rate44, to: PCM.format))
        let input = sine(250, rate: 16_000, seconds: 1)
        let wide = stream(input, rate: 16_000, chunk: PCM.frameSamples, through: up)
        #expect(abs(wide.count - 44_100) < 200)
        let back = stream(wide, rate: 44_100, chunk: 1024, through: down)
        #expect(abs(back.count - 16_000) < 150)
        #expect(abs(frequency(back[2000..<14_000], rate: 16_000) - 250) < 5)
        #expect(abs(PCM.rms(back[2000..<14_000]) - PCM.rms(input[2000..<14_000])) < 0.02)

        // …and it still frames into whole 640-byte wire frames.
        var chunker = FrameChunker()
        let frames = chunker.push(back)
        #expect(frames.count == back.count / 320)
        #expect(frames.allSatisfy { $0.count == PCM.frameBytes })
    }

    // MARK: - Jitter buffer

    private func frame(_ n: UInt8) -> Data { Data(repeating: n, count: PCM.frameBytes) }

    @Test func prebuffersBeforePlaying() {
        var jb = JitterBuffer(prebuffer: 3)
        #expect(jb.push(frame(1)).isEmpty)
        #expect(jb.push(frame(2)).isEmpty)
        #expect(jb.push(frame(3)) == [frame(1), frame(2), frame(3)])
        #expect(jb.inFlight == 3 && jb.isPlaying)
        // While playing, frames pass straight through.
        #expect(jb.push(frame(4)) == [frame(4)])
        #expect(jb.inFlight == 4)
    }

    @Test func underrunPrebuffersAgain() {
        var jb = JitterBuffer(prebuffer: 3)
        _ = jb.push(frame(1)); _ = jb.push(frame(2)); _ = jb.push(frame(3))
        for _ in 0..<3 { jb.played() }
        #expect(!jb.isPlaying)
        #expect(jb.push(frame(4)).isEmpty)
        #expect(jb.waiting.count == 1)
        jb.played()  // a stray callback never goes negative
        #expect(jb.inFlight == 0)
    }

    @Test func flushReleasesAShortBurst() {
        var jb = JitterBuffer()
        _ = jb.push(frame(1))
        #expect(jb.flush() == [frame(1)])
        #expect(jb.flush().isEmpty)
        #expect(jb.isPlaying)
    }

    @Test func capacityBoundsAStuckPlayer() {
        var jb = JitterBuffer(prebuffer: 1, capacity: 5)
        for i in 0..<5 { #expect(jb.push(frame(UInt8(i))).count == 1) }
        #expect(jb.push(frame(9)).isEmpty)
        jb.reset()
        #expect(jb.inFlight == 0 && jb.waiting.isEmpty)
    }

    @Test func levelSmootherEases() {
        let s = LevelSmoother()
        #expect(s.next(1, at: 0) == 0)                       // no time passed yet
        let up = s.next(1, at: 0.02)
        #expect(up > 0.3 && up < 1)                           // rises fast, not in one jump
        for k in 2...18 { _ = s.next(1, at: 0.02 + Double(k) / 60) }   // 60 Hz frames for ~0.3 s
        #expect(s.value > 0.99)
        let down = s.next(0, at: 0.02 + 19.0 / 60)
        #expect(down > 0.7)                                   // falls gently
    }
}

