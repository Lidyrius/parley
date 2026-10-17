import AVFoundation
import Foundation
import Speech

// Barge-in on the Mac's own speaker (the phone has its own: ios/ParleyMobile/WakeWord.swift):
// while Parley speaks, an on-device recognizer listens — on the echo-cancelled mic of the
// playback engine (speakers), or on the built-in mic next to Bluetooth headphones (no echo there,
// and the headphones' own mic would drop them to call quality). Only what can't be Parley's own
// echo counts: a stop word Parley didn't just say, or two words not in its line.
enum Barge {
    static let stopWords: Set<String> = ["stopp", "stop", "halt", "moment", "warte", "warten", "parley"]

    static func isInterruption(_ transcript: String, spoken: Set<String>) -> Bool {
        let words = tokens(transcript).filter { $0.count >= 2 && !spoken.contains($0) }
        if words.contains(where: stopWords.contains) { return true }
        return !spoken.isEmpty && words.count >= 2
    }

    /// Lowercased, diacritics folded, split on anything that is not a letter.
    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
    }
}

// One line's watch: fed mic buffers (any thread), it fires `onBarge` once and keeps the last 2 s
// at 16 kHz as the recording's pre-roll — so Sir's first words count.
// ponytail: @unchecked Sendable — the state is behind `lock`; the recognizer calls back on its queue.
final class BargeMonitor: @unchecked Sendable {
    static let settle: TimeInterval = 0.6          // an echo canceller is still adapting then
    static let prerollSamples = Int(UtteranceRecorder.sampleRate) * 2

    var onBarge: (@Sendable () -> Void)?
    private let lock = NSLock()
    private let spoken: Set<String>
    private let started = Date()
    private let recognizer: SFSpeechRecognizer
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?
    private var resampler: Resampler?
    private var preroll: [Int16] = []
    private var fired = false

    /// nil when on-device recognition isn't allowed or available (then no barge-in).
    init?(line: String) {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let r = SFSpeechRecognizer(locale: Locale(identifier: "de-DE")), r.isAvailable else { return nil }
        recognizer = r
        spoken = Set(Barge.tokens(line))
        request.shouldReportPartialResults = true
        if r.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.contextualStrings = ["Stopp", "Moment", "Parley"]
    }

    /// Asks once for speech recognition (the system prompt).
    static func requestAuthorization() {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
        SFSpeechRecognizer.requestAuthorization { _ in }
    }

    func start() {
        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let text = result?.bestTranscription.formattedString else { return }
            self.heard(text)
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
        guard let ch = buffer.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength)))
        lock.withLock {
            if resampler == nil { resampler = Resampler(from: Int(buffer.format.sampleRate), to: Int(UtteranceRecorder.sampleRate)) }
            preroll += PCMFrames.int16(resampler!.process(samples))
            if preroll.count > Self.prerollSamples { preroll.removeFirst(preroll.count - Self.prerollSamples) }
        }
    }

    /// Ends the watch; the last 2 s of mic at 16 kHz.
    func stop() -> [Int16] {
        task?.cancel()
        request.endAudio()
        return lock.withLock { preroll }
    }

    private func heard(_ text: String) {
        guard Date().timeIntervalSince(started) >= Self.settle, Barge.isInterruption(text, spoken: spoken) else { return }
        let first = lock.withLock { () -> Bool in
            guard !fired else { return false }
            fired = true
            return true
        }
        if first { onBarge?() }
    }
}
