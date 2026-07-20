import Foundation
import AVFoundation

// Mic capture + silence VAD. Fresh AVAudioEngine per recording (reusing one instance
// across start/stop cycles can silently stop delivering input buffers). Converts to
// 16 kHz mono Int16, runs each buffer through SilenceVAD, calls `onFinished` with the
// WAV once trailing silence ends. Writes a diagnostics file after each recording.
final class MicCapture: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var vad = SilenceVAD(speechThresholdDB: -50)
    private var samples: [Int16] = []
    private let targetRate = 16000.0
    private var onFinished: ((Data) -> Void)?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var finished = false
    private var totalDuration = 0.0
    private var maxTimer: DispatchWorkItem?

    // diagnostics (instance-local; written to a file on finish)
    private var buffersSeen = 0
    private var maxDBSeen: Float = -120
    private var endReason = "unknown"

    private let noSpeechTimeout = 8.0
    private let maxListenSeconds = 20.0

    func start(onFinished: @escaping (Data) -> Void) {
        finished = false
        self.onFinished = onFinished
        vad.reset()
        samples.removeAll(keepingCapacity: true)
        totalDuration = 0
        buffersSeen = 0
        maxDBSeen = -120
        endReason = "unknown"

        requestMicIfNeeded { [weak self] granted in
            guard let self else { return }
            guard granted else { self.endReason = "permission-denied"; self.finish(); return }
            self.beginCapture()
        }
    }

    private func beginCapture() {
        let engine = AVAudioEngine()          // fresh instance every recording
        self.engine = engine
        let input = engine.inputNode
        // Do NOT touch mainMixerNode for input-only capture: it lazily instantiates the
        // output HAL and can renegotiate the device, zeroing the input sample rate.
        // Use the input node's real output format for the tap.
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            endReason = "no-input-format"; NSLog("Vloude: no usable mic input format"); finish(); return
        }
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: targetRate, channels: 1, interleaved: true) else {
            endReason = "no-out-format"; finish(); return
        }
        targetFormat = outFormat
        converter = AVAudioConverter(from: inFormat, to: outFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buf, _ in
            self?.handle(buf)
        }
        engine.prepare()
        do { try engine.start() }
        catch { endReason = "engine-start-failed"; NSLog("Vloude: audio engine start failed: \(error)"); finish(); return }

        let work = DispatchWorkItem { [weak self] in
            self?.endReason = "max-cap"; self?.finish()
        }
        maxTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + maxListenSeconds, execute: work)
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
        guard n > 0 else { return }
        var floats = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let s = ch[0][i]
            samples.append(s)
            floats[i] = Float(s) / 32768.0
        }
        let db = Level.dB(Level.rms(floats))
        let duration = Double(n) / targetRate
        totalDuration += duration
        buffersSeen += 1
        if db > maxDBSeen { maxDBSeen = db }

        let decision = vad.process(rmsDB: db, duration: duration)
        if decision == .waiting && totalDuration >= noSpeechTimeout {
            endReason = "no-speech"
            DispatchQueue.main.async { [weak self] in self?.finish() }
            return
        }
        if decision == .ended {
            endReason = "vad-silence"
            DispatchQueue.main.async { [weak self] in self?.finish() }
        }
    }

    private func finish() {
        if !Thread.isMainThread { DispatchQueue.main.async { [weak self] in self?.finish() }; return }
        guard !finished else { return }
        finished = true
        maxTimer?.cancel(); maxTimer = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
        engine = nil
        writeDiagnostics(samples: samples.count)
        let wav = WAV.encode(int16: samples)
        let cb = onFinished
        onFinished = nil
        cb?(wav)
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.finished else { return }
            self.finished = true
            self.maxTimer?.cancel(); self.maxTimer = nil
            if let engine = self.engine {
                engine.inputNode.removeTap(onBus: 0)
                if engine.isRunning { engine.stop() }
            }
            self.engine = nil
            self.onFinished = nil
        }
    }

    private func requestMicIfNeeded(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { done(granted) }
            }
        default:
            done(false)
        }
    }

    private func authString() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    // After each recording, dump what happened so it can be inspected without logs.
    private func writeDiagnostics(samples: Int) {
        let json = """
        {"auth":"\(authString())","buffers":\(buffersSeen),"maxDB":\(Int(maxDBSeen)),"samples":\(samples),"seconds":\(String(format: "%.1f", totalDuration)),"endReason":"\(endReason)"}
        """
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vloude", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? Data(json.utf8).write(to: base.appendingPathComponent("last-recording.json"))
    }
}
