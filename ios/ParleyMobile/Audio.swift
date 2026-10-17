import AVFAudio
import Foundation

// Call audio on the wire (docs/IPHONE.md → Protocol v2): raw PCM 16-bit little-endian, mono,
// 16 kHz, one binary WebSocket frame per 20 ms (640 bytes), no header. These helpers are pure
// (or self-contained) so they can be unit-tested without an audio session.

enum PCM {
    static let sampleRate = 16_000.0
    static let frameSamples = 320           // 20 ms at 16 kHz
    static let frameBytes = frameSamples * 2
    static let frameDuration = 0.020

    /// What the engine side works in: Float32 mono 16 kHz (the mixer converts to the output).
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    /// Parley's voice plays at 24 kHz, the TTS's own rate: a host that got `"down":24000` sends
    /// 960-byte frames; an older host's 640-byte 16 kHz frames are upsampled.
    static let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    static let hiFiFrameBytes = 960

    /// Float samples (−1…1, clamped) → Int16 little-endian bytes.
    static func encode<C: Collection<Float>>(_ samples: C) -> Data {
        var out = Data(count: samples.count * 2)
        out.withUnsafeMutableBytes { raw in
            var offset = 0
            for x in samples {
                let v = Int16((min(1, max(-1, x)) * 32767).rounded())
                raw.storeBytes(of: v.littleEndian, toByteOffset: offset, as: Int16.self)
                offset += 2
            }
        }
        return out
    }

    /// Int16 little-endian bytes → float samples. A trailing odd byte is ignored.
    static func decode(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            (0..<raw.count / 2).map { i in
                Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
            }
        }
    }

    /// A received frame as a playable buffer in `format`.
    static func buffer(_ data: Data, format: AVAudioFormat = format) -> AVAudioPCMBuffer? {
        let samples = decode(data)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    /// Root mean square, 0…1.
    static func rms<C: Collection<Float>>(_ samples: C) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// RMS → a 0…1 display level (−50 dBFS … 0 dBFS), for the waveform.
    static func level(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 50) / 50))
    }
}

/// Slices a continuous 16 kHz sample stream into 640-byte wire frames.
struct FrameChunker {
    private var pending: [Float] = []

    var pendingSamples: Int { pending.count }

    mutating func push<C: Collection<Float>>(_ samples: C) -> [Data] {
        pending.append(contentsOf: samples)
        let whole = pending.count / PCM.frameSamples
        guard whole > 0 else { return [] }
        let frames = (0..<whole).map { i in
            PCM.encode(pending[(i * PCM.frameSamples)..<((i + 1) * PCM.frameSamples)])
        }
        pending.removeFirst(whole * PCM.frameSamples)
        return frames
    }

    mutating func reset() { pending.removeAll(keepingCapacity: true) }
}

/// Streaming sample-rate / channel conversion (e.g. the 48 kHz mic → 16 kHz mono). Keeps the
/// converter's filter state between calls, so consecutive buffers join without clicks.
/// Not thread-safe: use it from one thread (the mic tap).
final class Resampler {
    let input: AVAudioFormat
    let output: AVAudioFormat
    private let converter: AVAudioConverter

    init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        if input.channelCount > output.channelCount { converter.downmix = true }
        self.input = input
        self.output = output
        self.converter = converter
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        let ratio = output.sampleRate / input.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        let feed = Feed(buffer)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, status in feed.next(status) }
        guard status != .error, error == nil else { return nil }
        return out
    }

    /// Hands the converter one buffer, then "no data now" (streaming, not end of stream).
    private final class Feed: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard let b = buffer else { status.pointee = .noDataNow; return nil }
            buffer = nil
            status.pointee = .haveData
            return b
        }
    }
}

/// Decides when received frames go to the player: it holds back `prebuffer` frames (100 ms) when
/// playback (re)starts, so network jitter doesn't stutter, then passes frames straight through
/// while the player still has audio queued. A short burst that never reaches the prebuffer is
/// released by `flush()` (the caller arms a timer). Frames are never reordered or dropped,
/// except beyond `capacity` queued frames (a stuck player).
struct JitterBuffer {
    var prebuffer = 5                        // 100 ms: mobile networks jitter
    var capacity = 1500                      // 30 s
    private(set) var waiting: [Data] = []    // held back, not yet scheduled
    private(set) var inFlight = 0            // scheduled on the player, not yet played

    var isPlaying: Bool { inFlight > 0 }

    /// A frame arrived; returns the frames to schedule now, in order.
    mutating func push(_ frame: Data) -> [Data] {
        guard inFlight + waiting.count < capacity else { return [] }
        if inFlight > 0 {
            inFlight += 1
            return [frame]
        }
        waiting.append(frame)
        return waiting.count >= prebuffer ? release() : []
    }

    /// One scheduled frame finished playing.
    mutating func played() { inFlight = max(0, inFlight - 1) }

    /// The prebuffer wait timed out: play what there is.
    mutating func flush() -> [Data] { inFlight == 0 && !waiting.isEmpty ? release() : [] }

    mutating func reset() {
        waiting.removeAll()
        inFlight = 0
    }

    private mutating func release() -> [Data] {
        let out = waiting
        waiting.removeAll()
        inFlight += out.count
        return out
    }
}

/// A tiny lock box for state shared with audio threads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&stored) } }
}

/// Mic and playback levels (0…1) for the waveform: written from audio threads, read by the
/// view's animation timeline. Deliberately not observable — 50 updates a second would
/// re-render the whole screen.
final class AudioMeter: @unchecked Sendable {
    private struct Level {
        var value: Float = 0
        var at: TimeInterval = 0
    }
    private let levels = Locked((mic: Level(), out: Level()))

    /// Mic level after the 16 kHz conversion.
    var mic: Float {
        get { Self.read(levels.value.mic) }
        set { levels.withLock { $0.mic = Self.smooth($0.mic, newValue) } }
    }

    /// Level of the host's voice as it plays.
    var out: Float {
        get { Self.read(levels.value.out) }
        set { levels.withLock { $0.out = Self.smooth($0.out, newValue) } }
    }

    func reset() { levels.value = (Level(), Level()) }

    /// A level nobody updated for a moment (the stream stopped) has fallen to silence.
    private static func read(_ l: Level) -> Float {
        ProcessInfo.processInfo.systemUptime - l.at > 0.15 ? 0 : l.value
    }

    /// Fast attack, slower release.
    private static func smooth(_ old: Level, _ new: Float) -> Level {
        let now = ProcessInfo.processInfo.systemUptime
        let base = now - old.at > 0.15 ? 0 : old.value
        return Level(value: new > base ? base + (new - base) * 0.6 : base + (new - base) * 0.25, at: now)
    }
}
