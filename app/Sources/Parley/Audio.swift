import Foundation
import AVFoundation

// PCM playback for TTS output. ElevenLabs pcm_24000 is signed 16-bit LE mono at
// 24 kHz; we convert to Float32 buffers and schedule them on an AVAudioPlayerNode
// as chunks arrive. The Int16->Float conversion is the only pure bit and is tested.
enum PCM {
    /// Convert signed 16-bit little-endian mono samples to normalized Float32 [-1, 1].
    static func int16LEtoFloat(_ data: Data) -> [Float] {
        let count = data.count / 2
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<count {
                let lo = UInt16(p[i * 2])
                let hi = UInt16(p[i * 2 + 1])
                let s = Int16(bitPattern: hi << 8 | lo)
                out[i] = Float(s) / 32768.0
            }
        }
        return out
    }
}

final class TTSPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()   // playback speed w/o pitch shift
    private let format: AVAudioFormat
    private var carry = Data()   // odd trailing byte between streamed chunks

    // rate 1.0 = normal; >1 faster. Preserves pitch (natural voice at speed).
    init(sampleRate: Double = ElevenLabs.sampleRate, rate: Double = 1.0) {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: sampleRate, channels: 1, interleaved: false)!
        timePitch.rate = Float(min(2.0, max(0.5, rate)))
        engine.attach(node)
        engine.attach(timePitch)
        engine.connect(node, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
    }

    /// Set playback rate for the next buffers (pitch preserved). Cheap; safe to call often.
    func setRate(_ rate: Double) {
        let v = Float(min(2.0, max(0.5, rate)))
        if timePitch.rate != v { timePitch.rate = v }
    }

    func start() throws {
        carry.removeAll(keepingCapacity: true)   // fresh playback; drop any stale odd byte
        if !engine.isRunning { try engine.start() }
        node.play()
    }

    /// Schedule a streamed PCM chunk. Buffers an odd leftover byte for the next chunk.
    func enqueue(pcmChunk: Data) {
        carry.append(pcmChunk)
        let evenCount = (carry.count / 2) * 2
        guard evenCount > 0 else { return }
        let usable = carry.prefix(evenCount)
        carry.removeFirst(evenCount)
        let floats = PCM.int16LEtoFloat(Data(usable))
        guard let buf = makeBuffer(floats) else { return }
        node.scheduleBuffer(buf, completionHandler: nil)
    }

    /// Schedule a beep tone (played after speech). completion fires when it has actually
    /// been PLAYED BACK (not merely consumed) — so the caller can stop() without cutting it
    /// off. The tone also runs through the timePitch unit, which has real latency for very
    /// short buffers; .dataPlayedBack accounts for that.
    func scheduleBeep(frequency: Double = 880, seconds: Double = 0.18,
                      amplitude: Double = 0.3, completion: (() -> Void)? = nil) {
        let n = Int(format.sampleRate * seconds)
        var samples = [Float](repeating: 0, count: n)
        let twoPiF = 2.0 * Double.pi * frequency / format.sampleRate
        for i in 0..<n { samples[i] = Float(amplitude * sin(Double(i) * twoPiF)) }
        guard let buf = makeBuffer(samples) else { completion?(); return }
        node.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { _ in completion?() }
    }

    /// Schedule an elegant "glass" chime: fundamental + octave + soft 3rd harmonic under a
    /// bell envelope (fast attack, exponential ring-out). Sounds refined, not a flat beep.
    func scheduleChime(frequency: Double, seconds: Double = 0.5,
                       amplitude: Double = 0.5, decay: Double = 7.0,
                       completion: (() -> Void)? = nil) {
        let sr = format.sampleRate
        let n = Int(sr * seconds)
        var samples = [Float](repeating: 0, count: n)
        let w1 = 2.0 * Double.pi * frequency / sr
        let w2 = 2.0 * Double.pi * frequency * 2.0 / sr
        // Gentle: mostly the fundamental with just a hint of octave; drop the bright 3rd
        // harmonic that made it shrill. Slow, soft attack.
        let norm = 1.0 / 1.15
        for i in 0..<n {
            let t = Double(i) / sr
            let attack = min(1.0, t / 0.014)
            let env = attack * exp(-t * decay)
            let s = sin(Double(i) * w1) + 0.15 * sin(Double(i) * w2)
            samples[i] = Float(amplitude * env * s * norm)
        }
        guard let buf = makeBuffer(samples) else { completion?(); return }
        node.scheduleBuffer(buf, completionHandler: { completion?() })
    }

    private func makeBuffer(_ floats: [Float]) -> AVAudioPCMBuffer? {
        guard !floats.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(floats.count)) else { return nil }
        buf.frameLength = AVAudioFrameCount(floats.count)
        if let ch = buf.floatChannelData { floats.withUnsafeBufferPointer { ch[0].update(from: $0.baseAddress!, count: floats.count) } }
        return buf
    }

    func stop() {
        node.stop()
        engine.stop()
        carry.removeAll()
    }

    deinit {
        node.stop()
        engine.stop()   // ensure the audio device is released when this player is dropped
    }
}
