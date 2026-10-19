import Foundation

// Google Cloud Text-to-Speech (Chirp3 HD). Cheap (~free under 1M chars/month), good
// German neural voices. One-shot synthesize endpoint → base64 LINEAR16 (WAV) → PCM.
// API key sent via the X-Goog-Api-Key header (never in the URL).
enum GoogleTTS {
    static let endpoint = "https://texttospeech.googleapis.com/v1/text:synthesize"
    static let defaultVoice = "de-DE-Chirp3-HD-Alnilam"
    static let sampleRate = 24000

    static func request(text: String, apiKey: String, voice: String) -> URLRequest {
        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        // languageCode = first two segments of the voice name, e.g. "de-DE".
        let lang = voice.split(separator: "-").prefix(2).joined(separator: "-")
        let body: [String: Any] = [
            "input": ["text": text],
            "voice": ["languageCode": lang, "name": voice],
            "audioConfig": ["audioEncoding": "LINEAR16", "sampleRateHertz": sampleRate],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Extract raw 16-bit LE PCM from the JSON response (strips the WAV header if present).
    /// One line → 24 kHz PCM with the session voice; nil on any failure.
    // `timeout`: a hanging request (bad network) mustn't hold the turn — or a call — for the
    // system's 60 s; a short spoken line gives up sooner.
    static func synth(_ text: String, config: AppConfig, timeout: TimeInterval = 15) async -> Data? {
        var req = request(text: text, apiKey: config.googleKey, voice: config.googleVoice)
        req.timeoutInterval = timeout
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return pcm(from: data)
    }

    static func pcm(from data: Data) -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = obj["audioContent"] as? String,
              let audio = Data(base64Encoded: b64) else { return nil }
        if audio.count > 44, audio.prefix(4) == Data("RIFF".utf8) {
            return audio.subdata(in: 44..<audio.count)
        }
        return audio
    }
}

// Learned synthesis-latency model: EWMA of seconds-per-character, persisted across runs.
// Used to pause media just ~1s BEFORE the TTS is predicted to be ready instead of at turn
// start — YouTube keeps playing during most of the synthesis wait.
enum TTSTiming {
    private static let key = "parley.ttsSecPerChar"

    /// Predicted synthesis duration for a text of `chars` characters (clamped 0.3–8 s).
    static func predict(chars: Int) -> Double {
        let stored = UserDefaults.standard.double(forKey: key)
        let secPerChar = stored > 0 ? stored : 0.012   // ~3s for a 250-char line, pre-learning
        return min(8, max(0.3, secPerChar * Double(max(chars, 1))))
    }

    /// Feed an observed synthesis (chars → seconds); EWMA alpha 0.3.
    static func record(chars: Int, seconds: Double) {
        guard chars > 0, seconds > 0.05, seconds < 30 else { return }
        let sample = seconds / Double(chars)
        let old = UserDefaults.standard.double(forKey: key)
        UserDefaults.standard.set(old > 0 ? old * 0.7 + sample * 0.3 : sample, forKey: key)
    }
}
