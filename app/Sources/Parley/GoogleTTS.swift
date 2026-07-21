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
