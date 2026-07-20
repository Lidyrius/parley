import Foundation

// ElevenLabs TTS. We request raw PCM (pcm_24000) from the streaming endpoint and
// play it via AVAudioEngine. Only request construction is unit-tested; the network
// call and playback need a live key / audio device (smoke test).
enum ElevenLabs {
    static let model = "eleven_flash_v2_5"
    static let outputFormat = "pcm_24000"
    static let sampleRate = 24000.0

    struct Config {
        var apiKey: String
        var voiceID: String
    }

    static func streamRequest(text: String, config: Config) -> URLRequest {
        var comps = URLComponents(string:
            "https://api.elevenlabs.io/v1/text-to-speech/\(config.voiceID)/stream")!
        comps.queryItems = [URLQueryItem(name: "output_format", value: outputFormat)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue(config.apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/pcm", forHTTPHeaderField: "Accept")
        let body: [String: Any] = ["text": text, "model_id": model]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }
}
