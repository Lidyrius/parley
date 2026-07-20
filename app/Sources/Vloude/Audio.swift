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
    private let format: AVAudioFormat
    private var carry = Data()   // odd trailing byte between streamed chunks

    init(sampleRate: Double = ElevenLabs.sampleRate) {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: sampleRate, channels: 1, interleaved: false)!
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func start() throws {
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

    /// Schedule a beep tone (played after speech). completion fires when it ends.
    func scheduleBeep(frequency: Double = 880, seconds: Double = 0.12, completion: (() -> Void)? = nil) {
        let n = Int(format.sampleRate * seconds)
        var samples = [Float](repeating: 0, count: n)
        let twoPiF = 2.0 * Double.pi * frequency / format.sampleRate
        for i in 0..<n { samples[i] = Float(0.25 * sin(Double(i) * twoPiF)) }
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
