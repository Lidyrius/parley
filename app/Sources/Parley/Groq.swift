import Foundation

// Groq Whisper STT. We capture mic audio, encode to 16 kHz mono 16-bit WAV, and
// POST it as multipart. Only the WAV encoder and request builder are unit-tested;
// the live call needs a key (smoke test).

enum WAV {
    /// 16-bit PCM mono WAV file bytes for the given samples at `sampleRate`.
    static func encode(int16 samples: [Int16], sampleRate: Int = 16000) -> Data {
        let channels = 1, bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = samples.count * 2
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataSize))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(byteRate)); u16(UInt16(blockAlign)); u16(UInt16(bitsPerSample))
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataSize))
        for s in samples { u16(UInt16(bitPattern: s)) }
        return d
    }

    /// The samples of a WAV made by `encode` (its 44-byte header skipped).
    static func samples(_ wav: Data) -> [Int16] {
        var out = [Int16]()
        out.reserveCapacity(max(0, wav.count - 44) / 2)
        wav.withUnsafeBytes { raw in
            var i = 44
            while i + 1 < raw.count {
                out.append(Int16(bitPattern: UInt16(raw[i]) | UInt16(raw[i + 1]) << 8))
                i += 2
            }
        }
        return out
    }
}

/// A long recording goes to Whisper in pieces: each request stays small (Groq takes 25 MB — 13
/// minutes of this WAV — and a big upload over a weak line times out), and a piece that fails
/// costs that piece, not everything Sir said. Cut where it is quietest, not in the middle of a word.
enum Chunker {
    static let maxSeconds = 120.0      // one piece at most (plus `tail`)
    static let searchSeconds = 20.0    // the cut lies in the last stretch of a piece …
    static let window = 0.2            // … at its quietest 0.2 s
    static let tail = 2.0              // no piece shorter than this is left over

    static func split(_ s: [Int16], rate: Int = 16000, max: Double = maxSeconds, search: Double = searchSeconds) -> [Range<Int>] {
        let maxN = Int(max * Double(rate)), searchN = Int(search * Double(rate))
        let win = Swift.max(1, Int(window * Double(rate))), tailN = Int(tail * Double(rate))
        var out: [Range<Int>] = []
        var from = 0
        while s.count - from > maxN + tailN {
            var best = from + maxN, quietest = Float.infinity
            var w = from + maxN - searchN
            while w + win <= from + maxN {
                var energy: Float = 0
                for i in w..<(w + win) { let v = Float(s[i]); energy += v * v }
                if energy < quietest { quietest = energy; best = w + win / 2 }
                w += win
            }
            out.append(from..<best)
            from = best
        }
        out.append(from..<s.count)
        return out
    }
}

/// Recording → text: piece by piece (Chunker), each tried again when the line or Groq stumbles.
/// What came through is kept — a piece that failed for good leaves a note in its place, so the
/// session sees that something is missing instead of losing the whole reply.
enum Transcriber {
    static let attempts = 3
    static let pauses: [Double] = [1, 3]          // before the 2nd and 3rd try
    static let timeout: TimeInterval = 30         // per request (a piece is ≤ 4 MB)

    struct Outcome: Equatable {
        var text: String?       // nil = nothing came through (not configured, no line, refused)
        var parts = 1
        var failed = 0
        var status = 0          // the last failure's HTTP status (-1: no connection)
    }

    static func gap(seconds: Int) -> String {
        "[Parley: Hier fehlen etwa \(seconds) Sekunden der Aufnahme — die Transkription ist fehlgeschlagen.]"
    }

    /// `send`: one request → (HTTP status, body); nil = no connection.
    static func run(wav: Data, apiKey: String, send: @Sendable (URLRequest) async -> (Int, Data)?,
                    pause: @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) async -> Outcome {
        let samples = WAV.samples(wav)
        let parts = Chunker.split(samples)
        var out = Outcome(parts: parts.count)
        var texts: [String] = []
        var heard = ""
        for range in parts {
            let piece = parts.count == 1 ? wav : WAV.encode(int16: Array(samples[range]))
            // Whisper keeps names and the thread across the cut when it sees how the last piece ended.
            var req = Groq.transcriptionRequest(wav: piece, apiKey: apiKey, boundary: "parleyBoundary",
                                                prompt: heard.isEmpty ? nil : String(heard.suffix(200)))
            req.timeoutInterval = timeout
            var text: String?
            for attempt in 0..<attempts {
                if attempt > 0 { await pause(pauses[min(attempt - 1, pauses.count - 1)]) }
                guard let (status, body) = await send(req) else { out.status = -1; continue }
                if status == 200 {
                    text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    break
                }
                out.status = status
                Log.write("stt: HTTP \(status): \(String(data: body.prefix(300), encoding: .utf8) ?? "")")
                guard status >= 500 || status == 429 || status == 408 else { break }   // refused: trying again won't help
            }
            guard let text else {
                out.failed += 1
                texts.append(gap(seconds: Int((Double(range.count) / 16000).rounded())))
                continue
            }
            let clean = Groq.cleanTranscript(text)
            if clean.isEmpty && !text.isEmpty { Log.write("stt: dropped Whisper hallucination \"\(text)\"") }
            if !clean.isEmpty { texts.append(clean); heard = clean }
        }
        out.text = out.failed == parts.count ? nil : texts.joined(separator: " ")
        return out
    }
}

/// A recording Whisper did not (fully) take is kept, so nothing Sir said is gone for good:
/// Application Support/Parley/failed-recordings/, the newest ten.
enum FailedRecordings {
    static let dir = Reminders.file.deletingLastPathComponent().appendingPathComponent("failed-recordings", isDirectory: true)

    @discardableResult
    static func keep(_ wav: Data, in dir: URL = dir, at now: Date = Date(), keeping: Int = 10) -> URL? {
        let fm = FileManager.default
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let file = dir.appendingPathComponent(f.string(from: now) + ".wav")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try wav.write(to: file, options: .atomic)
        } catch { return nil }
        let all = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in all.dropFirst(keeping) { try? fm.removeItem(at: old) }
        return file
    }
}

enum Groq {
    static let model = "whisper-large-v3-turbo"
    static let endpoint = "https://api.groq.com/openai/v1/audio/transcriptions"

    static func transcriptionRequest(wav: Data, apiKey: String, boundary: String, prompt: String? = nil) -> URLRequest {
        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = multipartBody(wav: wav, boundary: boundary, prompt: prompt)
        return req
    }

    static func multipartBody(wav: Data, boundary: String, prompt: String? = nil) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        field("model", model)
        field("response_format", "text")
        if let prompt, !prompt.isEmpty { field("prompt", prompt) }   // how the piece before ended
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"reply.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    // Whisper invents these on silence / background noise (YouTube-subtitle training data).
    // Compared after lowercasing and collapsing punctuation + whitespace.
    // ponytail: whole-transcript exact match; repeats ("Thank you. Thank you.") slip through.
    static let hallucinations: Set<String> = [
        "you", "thank you", "thank you very much", "thanks for watching",
        "thank you for watching", "thanks for watching and see you next time", "please subscribe",
        "danke", "vielen dank", "danke fürs zuschauen", "vielen dank fürs zuschauen",
        "untertitel der amara org community", "untertitel im auftrag des zdf",
        "untertitelung im auftrag des zdf", "untertitel im auftrag des zdf für funk 2017",
        "untertitelung des zdf für funk 2017",
    ]

    /// The transcript, or "" when it's only a known Whisper hallucination (or no words at all),
    /// so silence takes the normal "no reply" path instead of being injected as speech.
    static func cleanTranscript(_ text: String) -> String {
        let norm = text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
        return norm.isEmpty || hallucinations.contains(norm) ? "" : text
    }
}
