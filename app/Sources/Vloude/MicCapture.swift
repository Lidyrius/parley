import Foundation
import AVFoundation

// Mic capture + silence VAD. Installs a tap on the input node, converts to 16 kHz
// mono Int16, runs each buffer through SilenceVAD, and calls `onFinished` with the
// accumulated WAV once trailing silence ends. Runtime-only (needs a mic + permission).
final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var vad = SilenceVAD()
    private var samples: [Int16] = []
    private let targetRate = 16000.0
    private var onFinished: ((Data) -> Void)?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    func start(onFinished: @escaping (Data) -> Void) {
        self.onFinished = onFinished
        vad.reset()
        samples.removeAll()

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: targetRate, channels: 1, interleaved: true)!
        targetFormat = outFormat
        converter = AVAudioConverter(from: inFormat, to: outFormat)

        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buf, _ in
            self?.handle(buf)
        }
        try? engine.start()
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let targetFormat else { return }
        let ratio = targetRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard err == nil, let ch = out.int16ChannelData else { return }
        let n = Int(out.frameLength)
        var floats = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let s = ch[0][i]
            samples.append(s)
            floats[i] = Float(s) / 32768.0
        }
        let db = Level.dB(Level.rms(floats))
        let duration = Double(n) / targetRate
        if vad.process(rmsDB: db, duration: duration) == .ended {
            finish()
        }
    }

    private func finish() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let wav = WAV.encode(int16: samples)
        onFinished?(wav)
        onFinished = nil
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        onFinished = nil
    }
}
