import Foundation
import AVFoundation

// Mic capture + silence VAD. ALL AVAudioEngine / CoreAudio work runs on a private
// serial queue — never the main thread — so device setup (incl. selecting a specific
// input device via CoreAudio) or a blocking engine.start() can't freeze the UI.
// Fresh AVAudioEngine per recording (reuse silently kills input on later cycles).
final class MicCapture: @unchecked Sendable {
    private let q = DispatchQueue(label: "de.developaway.vloude.mic")
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
    private var buffersSeen = 0
    private var maxDBSeen: Float = -120
    private var endReason = "unknown"
    private var logCounter = 0
    private var attempt = 0

    // Live input level 0…1 for the recording HUD waveform (called on the tap thread).
    var onLevel: ((Float) -> Void)?

    private let noSpeechTimeout = 8.0
    private let maxListenSeconds = 90.0

    func start(onFinished: @escaping (Data) -> Void) {
        q.async { [weak self] in
            guard let self else { return }
            self.finished = false
            self.onFinished = onFinished
            self.vad.reset()
            self.samples.removeAll(keepingCapacity: true)
            self.totalDuration = 0
            self.buffersSeen = 0
            self.maxDBSeen = -120
            self.endReason = "unknown"
            self.logCounter = 0
            self.attempt = 0

            self.requestMicIfNeeded { granted in
                self.q.async {
                    guard granted else {
                        Log.write("mic: permission not granted")
                        self.endReason = "permission-denied"; self.finish(); return
                    }
                    self.beginCapture()
                }
            }
        }
    }

    // runs on `q`
    private func beginCapture() {
        maxTimer?.cancel()
        attempt += 1
        let myAttempt = attempt
        // Capture from the SYSTEM DEFAULT input. Per-engine AUHAL device routing proved
        // fragile (0 buffers / wrong format); the onboarding picker instead sets the
        // system default input device, which AVAudioEngine picks up reliably here.
        let engine = AVAudioEngine()
        self.engine = engine

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            endReason = "no-input-format"; Log.write("mic: no usable input format (\(inFormat.sampleRate)Hz)"); finish(); return
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
        do {
            try engine.start()
            Log.write("mic: engine started (\(Int(inFormat.sampleRate))Hz, \(inFormat.channelCount)ch)")
        } catch {
            endReason = "engine-start-failed"; Log.write("mic: engine start failed: \(error)"); finish(); return
        }

        let work = DispatchWorkItem { [weak self] in
            self?.endReason = "max-cap"; Log.write("mic: max listen cap reached"); self?.finish()
        }
        maxTimer = work
        q.asyncAfter(deadline: .now() + maxListenSeconds, execute: work)

        // Dead-capture watchdog: if no buffers arrive within 3 s, the input is stuck
        // (device contention etc.). Restart the engine once; if still dead, give up
        // fast instead of hanging on the 90 s cap.
        q.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, !self.finished, self.buffersSeen == 0 else { return }
            if myAttempt < 2 {
                Log.write("mic: no buffers after 3s (attempt \(myAttempt)), restarting engine")
                if let e = self.engine { e.inputNode.removeTap(onBus: 0); if e.isRunning { e.stop() }; self.engine = nil }
                self.beginCapture()
            } else {
                self.endReason = "no-buffers"
                Log.write("mic: still no buffers after restart, giving up")
                self.finish()
            }
        }
    }

    // runs on the AVAudioEngine tap thread
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
        // Map dBFS (~ -55…-10) to 0…1 for the live waveform.
        onLevel?(max(0, min(1, (db + 55) / 45)))
        logCounter += 1
        if logCounter % 20 == 0 {
            Log.write("mic: db=\(Int(db)) armed=\(vad.started) total=\(String(format: "%.1f", totalDuration))s buffers=\(buffersSeen)")
        }

        let decision = vad.process(rmsDB: db, duration: duration)
        if decision == .waiting && totalDuration >= noSpeechTimeout {
            endReason = "no-speech"
            q.async { [weak self] in self?.finish() }
            return
        }
        if decision == .ended {
            endReason = "vad-silence"
            q.async { [weak self] in self?.finish() }
        }
    }

    // runs on `q`
    private func finish() {
        guard !finished else { return }
        finished = true
        maxTimer?.cancel(); maxTimer = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
        engine = nil
        let count = samples.count
        writeDiagnostics(samples: count)
        Log.write("mic: finished reason=\(endReason) buffers=\(buffersSeen) samples=\(count) maxDB=\(Int(maxDBSeen))")
        let wav = WAV.encode(int16: samples)
        let cb = onFinished
        onFinished = nil
        cb?(wav)
    }

    func stop() {
        q.async { [weak self] in
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
            AVCaptureDevice.requestAccess(for: .audio) { granted in done(granted) }
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
