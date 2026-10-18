import AVFAudio
import Foundation

/// The call's audio: an `AVAudioEngine` with voice processing (echo cancellation) on the I/O.
/// Mic → 16 kHz PCM16 frames → `send`; received frames → jitter buffer → player → output.
/// The audio session itself belongs to CallKit (it activates it); this only runs the engine.
@MainActor
final class CallAudio {
    /// The engine and its player. Only `start` touches them off the main actor — turning on voice
    /// processing and starting the I/O take a few hundred ms, which froze the answer animation —
    /// and nothing else uses them before `isRunning`.
    private final class IO: @unchecked Sendable {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
    }
    private let io = IO()
    private var engine: AVAudioEngine { io.engine }
    private var player: AVAudioPlayerNode { io.player }
    private var starting = false
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

    func start() async throws {
        guard !isRunning, !starting else { return }
        starting = true
        defer { starting = false }
        let run = generation
        let (io, mic, usesMicrophone) = (io, mic, Self.usesMicrophone)
        let r = try await Task.detached(priority: .userInitiated) {
            try Self.startIO(io, mic: mic, usesMicrophone: usesMicrophone)
        }.value
        guard run == generation else {   // stopped while starting
            Self.stopIO(io, hasMicrophone: r.hasMicrophone)
            return
        }
        echoCancellation = r.echoCancellation
        hasMicrophone = r.hasMicrophone
        isRunning = true
    }

    private nonisolated static func startIO(_ io: IO, mic: MicPipeline, usesMicrophone: Bool) throws
        -> (echoCancellation: Bool, hasMicrophone: Bool) {
        var echo = false, hasMic = false
        if usesMicrophone {
            let input = io.engine.inputNode
            do {
                if !input.isVoiceProcessingEnabled { try input.setVoiceProcessingEnabled(true) }
                echo = true
            } catch {
                echo = false
            }
            let format = input.outputFormat(forBus: 0)
            hasMic = format.sampleRate > 0 && format.channelCount > 0
            if hasMic {
                mic.prepare(input: format)
                input.installTap(onBus: 0, bufferSize: 1024, format: format, block: tap(mic))
            }
        }
        io.engine.connect(io.player, to: io.engine.mainMixerNode, format: PCM.playFormat)
        io.engine.prepare()
        do {
            try io.engine.start()
        } catch {
            if hasMic { io.engine.inputNode.removeTap(onBus: 0) }
            throw error
        }
        io.player.play()
        return (echo, hasMic)
    }

    private nonisolated static func stopIO(_ io: IO, hasMicrophone: Bool) {
        if hasMicrophone { io.engine.inputNode.removeTap(onBus: 0) }
        io.player.stop()
        io.engine.stop()
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
        generation += 1   // also cancels a start still under way
        guard isRunning else { return }
        isRunning = false
        Self.stopIO(io, hasMicrophone: hasMicrophone)
        jitter.reset()
        flushTimer?.cancel()
        flushTimer = nil
        meter.reset()
    }

    func restart() {
        guard isRunning else { return }
        stop()
        Task { try? await start() }
    }

    // MARK: - Playback

    /// Barge-in: quiet at once — the queued audio is dropped, and frames still arriving are too,
    /// until `unsilence()` (the host stopped and listens).
    private var silenced = false

    func silence() {
        guard isRunning else { return }
        silenced = true
        flushTimer?.cancel()
        flushTimer = nil
        jitter.reset()
        player.stop()
        player.play()
    }

    func unsilence() { silenced = false }

    /// One received wire frame (20 ms: 960 bytes at 24 kHz, or 640 at 16 kHz).
    func play(_ frame: Data) {
        guard isRunning, !silenced else { return }
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
