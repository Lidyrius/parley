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

// The beep and the chime as samples — the Mac's TTSPlayer schedules them, the phone path sends
// them down the call (PhoneVoice).
enum Tones {
    /// The "you can talk now" beep: a plain sine.
    static func beep(sampleRate: Double, frequency: Double = 880, seconds: Double = 0.18,
                     amplitude: Double = 0.3) -> [Float] {
        let n = Int(sampleRate * seconds)
        let twoPiF = 2.0 * Double.pi * frequency / sampleRate
        return (0..<n).map { Float(amplitude * sin(Double($0) * twoPiF)) }
    }

    /// A "glass" chime: fundamental + a hint of octave under a bell envelope (soft attack,
    /// exponential ring-out). The bright 3rd harmonic was dropped — it made it shrill.
    static func chime(sampleRate sr: Double, frequency: Double, seconds: Double = 0.5,
                      amplitude: Double = 0.5, decay: Double = 7.0) -> [Float] {
        let n = Int(sr * seconds)
        let w1 = 2.0 * Double.pi * frequency / sr
        let w2 = 2.0 * Double.pi * frequency * 2.0 / sr
        let norm = 1.0 / 1.15
        return (0..<n).map { i in
            let t = Double(i) / sr
            let env = min(1.0, t / 0.014) * exp(-t * decay)
            return Float(amplitude * env * (sin(Double(i) * w1) + 0.15 * sin(Double(i) * w2)) * norm)
        }
    }

    /// The two-note chime that ends a turn without words (Mac: two scheduled chimes).
    static func turnChime(sampleRate: Double) -> [Float] {
        chime(sampleRate: sampleRate, frequency: 523.25, seconds: 0.32, amplitude: 0.4, decay: 8)
            + chime(sampleRate: sampleRate, frequency: 783.99, seconds: 0.6, amplitude: 0.4, decay: 5.5)
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
        // Output level for GET /status (same dB→0…1 mapping as the mic).
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buf, _ in
            guard let ch = buf.floatChannelData else { return }
            let db = Level.dB(Level.rms(Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))))
            LiveStatus.push((db + 55) / 45)
        }
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
        let samples = Tones.beep(sampleRate: format.sampleRate, frequency: frequency, seconds: seconds, amplitude: amplitude)
        guard let buf = makeBuffer(samples) else { completion?(); return }
        node.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { _ in completion?() }
    }

    /// Schedule an elegant "glass" chime: fundamental + octave + soft 3rd harmonic under a
    /// bell envelope (fast attack, exponential ring-out). Sounds refined, not a flat beep.
    func scheduleChime(frequency: Double, seconds: Double = 0.5,
                       amplitude: Double = 0.5, decay: Double = 7.0,
                       completion: (() -> Void)? = nil) {
        let samples = Tones.chime(sampleRate: format.sampleRate, frequency: frequency, seconds: seconds,
                                  amplitude: amplitude, decay: decay)
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
        engine.mainMixerNode.removeTap(onBus: 0)
        node.stop()
        engine.stop()
        carry.removeAll()
    }

    deinit {
        node.stop()
        engine.stop()   // ensure the audio device is released when this player is dropped
    }
}
