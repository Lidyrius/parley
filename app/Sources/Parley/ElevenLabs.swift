import Foundation

// ElevenLabs TTS. We request raw PCM (pcm_24000) from the streaming endpoint and
// play it via AVAudioEngine. Only request construction is unit-tested; the network
// call and playback need a live key / audio device (smoke test).
enum ElevenLabs {
    static let model = "eleven_flash_v2_5"
    static let outputFormat = "pcm_24000"
    static let sampleRate = 24000.0

    // The user's personal cloned voice ("Jarvis"). Preselected during onboarding when
    // the account has access to it; otherwise onboarding falls back to a premade voice.
    static let jarvisVoiceID = "JyoJov3tFx6ucWOiDwTM"
    static let fallbackVoiceID = "JBFqnCBsd6RMkjVDRZzb"   // "George" premade

    struct Config {
        var apiKey: String
        var voiceID: String
    }

    struct Voice: Identifiable, Decodable, Hashable {
        let voice_id: String
        let name: String
        let category: String?
        let preview_url: String?
        var id: String { voice_id }
    }

    static func voicesRequest(apiKey: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        return req
    }

    static func decodeVoices(_ data: Data) -> [Voice] {
        struct Resp: Decodable { let voices: [Voice] }
        return (try? JSONDecoder().decode(Resp.self, from: data))?.voices ?? []
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
