import AVFAudio
import Foundation
import Speech

/// "Hey Parley" in a (German) transcript. Lenient: case, diacritics and punctuation don't
/// matter, and the recognizer's likely mishearings count — the name alone when it is one edit
/// away ("Parle", "Parlay", "Barley"), and close relatives ("Partie", "Party") after a greeting.
enum WakeWord {
    static let name = "parley"
    static let greetings: Set<String> = ["hey", "hei", "hay", "he", "hej", "hee", "ey", "eh", "hi", "hallo", "ok", "okay"]
    /// Heard for "Parley" after a greeting, though more than an edit or two away.
    static let lookalikes: Set<String> = ["partie", "parti", "partei", "party", "pali", "bali", "paley", "pauli", "harley", "marley"]

    static func matches(_ transcript: String) -> Bool {
        let words = tokens(transcript)
        for (i, word) in words.enumerated() {
            let next = i + 1 < words.count ? words[i + 1] : nil
            // The recognizer sometimes splits the name: "Par Lee", "Bar Ley".
            let candidates = [word] + (next.map { [word + $0] } ?? [])
            let greeted = i > 0 && greetings.contains(words[i - 1])
            if candidates.contains(where: { isName($0) || (greeted && isNameAfterGreeting($0)) }) { return true }
        }
        return false
    }

    /// Lowercased, diacritics folded, split on anything that is not a letter.
    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
    }

    /// Strong enough alone: "parley" or one edit away, starting like it (p/b).
    private static func isName(_ w: String) -> Bool {
        w.count >= 5 && (w.first == "p" || w.first == "b") && distance(w, name) <= 1
    }

    /// After "hey": two edits away, or a known lookalike.
    private static func isNameAfterGreeting(_ w: String) -> Bool {
        lookalikes.contains(w) || (w.count >= 4 && (w.first == "p" || w.first == "b") && distance(w, name) <= 2)
    }

    /// Levenshtein distance.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previous : 1 + min(previous, row[j], row[j - 1])
                previous = current
            }
        }
        return row[b.count]
    }
}

/// The mic tap's handle on the current recognition request (tap thread ↔ main actor).
final class SpeechFeed: @unchecked Sendable {
    private let request = Locked<SFSpeechAudioBufferRecognitionRequest?>(nil)

    func use(_ r: SFSpeechAudioBufferRecognitionRequest?) {
        request.withLock { old in
            if old !== r { old?.endAudio() }
            old = r
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request.withLock { $0?.append(buffer) }
    }
}

/// On-device speech recognition on the call's mic, only for the wake word. Started while the
/// host is idle, stopped otherwise (power). Tasks end by themselves (≈1 min, silence, errors);
/// each end starts a fresh one while listening is wanted.
@MainActor
final class WakeListener {
    let feed = SpeechFeed()
    var onWake: (() -> Void)?
    private(set) var isRunning = false
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de-DE"))
    private var task: SFSpeechRecognitionTask?
    private var restart: Task<Void, Never>?
    private var renew: Task<Void, Never>?
    private var failures = 0
    /// Bumped per recognition task, so a cancelled task's late callbacks are ignored.
    private var generation = 0

    nonisolated static var isAuthorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    /// Asks once (the system shows the prompt the first time only). Nonisolated: TCC calls back
    /// on its own queue, and a main-actor closure there traps.
    nonisolated static func requestAuthorization() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in done.resume() }
            }
        }
        return isAuthorized
    }

    var isAvailable: Bool { Self.isAuthorized && recognizer?.isAvailable == true }

    func start() {
        guard !isRunning, isAvailable else { return }
        isRunning = true
        failures = 0
        begin()
    }

    func stop() {
        isRunning = false
        restart?.cancel()
        renew?.cancel()
        feed.use(nil)
        task?.cancel()
        task = nil
        generation += 1
    }

    private func begin() {
        guard isRunning, let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.contextualStrings = ["Parley", "Hey Parley"]
        request.addsPunctuation = false
        feed.use(request)
        generation += 1
        task = recognizer.recognitionTask(with: request, resultHandler: Self.handler(self, generation: generation))
        // On-device tasks may not time out; renew anyway so a long idle stretch doesn't grow one
        // huge transcript.
        renew?.cancel()
        renew = Task { [weak self] in
            try? await Task.sleep(for: .seconds(50))
            guard !Task.isCancelled else { return }
            self?.feed.use(nil)  // endAudio → a final result → `ended`
        }
    }

    private func heard(_ transcript: String, generation: Int) {
        guard isRunning, generation == self.generation, WakeWord.matches(transcript) else { return }
        stop()
        onWake?()
    }

    private func ended(failed: Bool, generation: Int) {
        guard isRunning, generation == self.generation else { return }
        feed.use(nil)
        task = nil
        failures = failed ? failures + 1 : 0
        let delay = failed ? min(5.0, 0.5 * Double(1 << min(failures, 4))) : 0.1
        restart?.cancel()
        restart = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.begin()
        }
    }

    /// The recognizer calls back on its queue (main by default); built outside the main actor
    /// so the closure isn't assumed to be main-actor isolated.
    private nonisolated static func handler(_ listener: WakeListener, generation: Int) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak listener] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let failed = error != nil
            Task { @MainActor in
                guard let listener else { return }
                if let text { listener.heard(text, generation: generation) }
                if final || failed { listener.ended(failed: failed && !final, generation: generation) }
            }
        }
    }
}
