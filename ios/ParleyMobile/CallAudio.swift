import AVFAudio
import Foundation

/// The call's audio: an `AVAudioEngine` with voice processing (echo cancellation) on the I/O.
/// Mic → 16 kHz PCM16 frames → `send`; received frames → jitter buffer → player → output.
/// The audio session itself belongs to CallKit (it activates it); this only runs the engine.
@MainActor
final class CallAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let mic: MicPipeline
    private let meter: AudioMeter
    private var jitter = JitterBuffer()
    /// An older host's 16 kHz frames → the player's 24 kHz.
    private let upsample = Resampler(from: PCM.format, to: PCM.playFormat)
    /// Bumped on every stop, so late "played" callbacks from an old run are ignored.
    private var generation = 0
    private var flushTimer: Task<Void, Never>?
    private(set) var isRunning = false
    /// The call's frame clock for captions: frames received and frames played (20 ms each).
    private(set) var received = 0
    private(set) var played = 0
    /// False where voice processing is unavailable (e.g. the simulator): plain I/O, no AEC.
    private(set) var echoCancellation = false
    private(set) var hasMicrophone = false

    init(meter: AudioMeter, speech: SpeechFeed, send: @escaping @Sendable (Data) -> Void) {
        self.meter = meter
        mic = MicPipeline(send: send, meter: meter, speech: speech)
        engine.attach(player)
        // A route change (AirPods, car, speaker) rebuilds the engine's I/O: rejoin with the new formats.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }
    }

    var muted: Bool {
        get { mic.isMuted }
        set { mic.isMuted = newValue }
    }

    func start() throws {
        guard !isRunning else { return }
        hasMicrophone = false
        if Self.usesMicrophone {
            let input = engine.inputNode
            do {
                if !input.isVoiceProcessingEnabled { try input.setVoiceProcessingEnabled(true) }
                echoCancellation = true
            } catch {
                echoCancellation = false
            }
            let format = input.outputFormat(forBus: 0)
            hasMicrophone = format.sampleRate > 0 && format.channelCount > 0
            if hasMicrophone {
                mic.prepare(input: format)
                input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(mic))
            }
        }
        engine.connect(player, to: engine.mainMixerNode, format: PCM.playFormat)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            if hasMicrophone { engine.inputNode.removeTap(onBus: 0) }
            throw error
        }
        player.play()
        isRunning = true
    }

    /// The simulator's audio input is the Mac's microphone; when that path isn't available, an
    /// input-enabled session deadlocks the simulator's audio device and CoreAudio aborts the app
    /// ("RPC timeout", not a catchable error). There the call runs playback-only (session and
    /// engine) unless launched with `-simulatorMic`. Devices always use the mic.
    static var usesMicrophone: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("-simulatorMic")
        #else
        true
        #endif
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if hasMicrophone { engine.inputNode.removeTap(onBus: 0) }
        player.stop()
        engine.stop()
        generation += 1
        jitter.reset()
        flushTimer?.cancel()
        flushTimer = nil
        meter.reset()
    }

    func restart() {
        guard isRunning else { return }
        stop()
        try? start()
    }

    // MARK: - Playback

    /// One received wire frame (20 ms: 960 bytes at 24 kHz, or 640 at 16 kHz).
    func play(_ frame: Data) {
        guard isRunning else { return }
        received += 1
        for f in jitter.push(frame) { schedule(f) }
        if !jitter.waiting.isEmpty, !jitter.isPlaying, flushTimer == nil {
            // A short burst below the prebuffer still has to come out.
            flushTimer = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, !Task.isCancelled else { return }
                flushTimer = nil
                for f in jitter.flush() { schedule(f) }
            }
        }
    }

    private func schedule(_ frame: Data) {
        let buffer = frame.count == PCM.hiFiFrameBytes
            ? PCM.buffer(frame, format: PCM.playFormat)
            : PCM.buffer(frame).flatMap { upsample?.convert($0) }
        guard let buffer, buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else {
            jitter.played()
            return
        }
        let level = PCM.level(rms: PCM.rms(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack,
                              completionHandler: Self.played(self, generation: generation, level: level))
        if !player.isPlaying { player.play() }
    }

    private func didPlay(generation: Int, level: Float) {
        guard generation == self.generation else { return }
        played += 1
        jitter.played()
        meter.out = level
    }

    // Callbacks built outside the main actor: AVFAudio calls them on its own threads.

    private nonisolated static func played(_ audio: CallAudio, generation: Int, level: Float) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { [weak audio] _ in
            Task { @MainActor in audio?.didPlay(generation: generation, level: level) }
        }
    }

    private nonisolated static func tap(_ mic: MicPipeline) -> AVAudioNodeTapBlock {
        { buffer, _ in mic.process(buffer) }
    }
}

enum CallAudioError: Error {
    case noMicrophone
}

/// Runs on the mic tap's thread: feeds the wake-word recognizer, converts to 16 kHz mono,
/// meters, slices into 640-byte frames and sends them. Muted sends silence, so the host's
/// voice detection still sees the end of speech.
final class MicPipeline: @unchecked Sendable {
    private let send: @Sendable (Data) -> Void
    private let meter: AudioMeter
    private let speech: SpeechFeed
    private let mutedFlag = Locked(false)
    // Touched only by `prepare` (before the tap is installed) and then the tap thread.
    private var resampler: Resampler?
    private var chunker = FrameChunker()

    init(send: @escaping @Sendable (Data) -> Void, meter: AudioMeter, speech: SpeechFeed) {
        self.send = send
        self.meter = meter
        self.speech = speech
    }

    var isMuted: Bool {
        get { mutedFlag.value }
        set { mutedFlag.value = newValue }
    }

    func prepare(input: AVAudioFormat) {
        resampler = Resampler(from: input, to: PCM.format)
        chunker.reset()
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        let muted = isMuted
        if !muted { speech.append(buffer) }
        guard let out = resampler?.convert(buffer), out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }
        let samples = UnsafeBufferPointer(start: channel, count: Int(out.frameLength))
        meter.mic = muted ? 0 : PCM.level(rms: PCM.rms(samples))
        let frames = muted ? chunker.push(repeatElement(Float(0), count: samples.count)) : chunker.push(samples)
        for frame in frames { send(frame) }
    }
}
