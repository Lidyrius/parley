import Foundation
import AVFoundation

// Plays a short sample of a Chirp3-HD voice while the user picks one in onboarding.
//
// Full quality: on selection we synth the sample live with the user's own key (lossless
// LINEAR16 — identical to how the app will actually speak) and cache it, so a second click
// is instant. The bundled low-quality MP3 (Resources/voice-previews/<voice>.mp3) is only an
// offline / no-key fallback. One friendly sentence per language, no Jarvis.
@MainActor
enum VoicePreview {
    private static var player: AVAudioPlayer?
    private static var token = 0   // guards against a stale fetch playing after the user moved on

    /// The friendly sample sentence for a language (same text the bundled clips use).
    static func sentence(for language: String) -> String {
        switch language {
        case "English":    return "Hi there! This is my voice. This is how I sound when I read to you."
        case "Français":   return "Bonjour ! Voici ma voix. Voilà comment je sonne quand je te fais la lecture."
        case "Español":    return "¡Hola! Esta es mi voz. Así sueno cuando te leo en voz alta."
        case "Italiano":   return "Ciao! Questa è la mia voce. Ecco come suono quando ti leggo qualcosa."
        case "Nederlands": return "Hoi! Dit is mijn stem. Zo klink ik als ik je iets voorlees."
        default:           return "Hallo! Das ist meine Stimme. So klinge ich, wenn ich dir vorlese."
        }
    }

    private static var hqDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parley/voice-previews-hq", isDirectory: true)
    }

    /// Play `voice`. Cached HQ wins; else synth HQ with `key` (onState toggles a spinner);
    /// with no key or on error, fall back to the instant bundled sample.
    static func play(voice: String, sentence: String, key: String, onState: @escaping (Bool) -> Void = { _ in }) {
        token += 1; let my = token
        let cached = hqDir.appendingPathComponent("\(voice).wav")
        if FileManager.default.fileExists(atPath: cached.path) { playFile(cached); return }
        if key.isEmpty { playBundled(voice); return }
        onState(true)
        Task {
            let pcm = await fetchPCM(voice: voice, sentence: sentence, key: key)
            onState(false)
            guard my == token else { return }   // user already picked another voice
            guard let pcm else { playBundled(voice); return }
            let wav = Self.wav(pcm)
            try? FileManager.default.createDirectory(at: hqDir, withIntermediateDirectories: true)
            try? wav.write(to: cached)
            playData(wav)
        }
    }

    static func stop() { player?.stop(); player = nil }

    private static func fetchPCM(voice: String, sentence: String, key: String) async -> Data? {
        let req = GoogleTTS.request(text: sentence, apiKey: key, voice: voice)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return GoogleTTS.pcm(from: data)
    }

    private static func playBundled(_ voice: String) {
        guard let url = Bundle.module.url(forResource: voice, withExtension: "mp3", subdirectory: "voice-previews") else { return }
        playFile(url)
    }
    private static func playFile(_ url: URL) {
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        player?.stop(); player = p; p.play()
    }
    private static func playData(_ data: Data) {
        guard let p = try? AVAudioPlayer(data: data) else { return }
        player?.stop(); player = p; p.play()
    }

    // Wrap raw 24 kHz mono 16-bit PCM in a 44-byte WAV header so AVAudioPlayer can play it.
    private static func wav(_ pcm: Data) -> Data {
        let sr: UInt32 = UInt32(GoogleTTS.sampleRate), ch: UInt16 = 1, bits: UInt16 = 16
        let byteRate = sr * UInt32(ch) * UInt32(bits / 8)
        let block = ch * (bits / 8)
        var d = Data()
        func le<T: FixedWidthInteger>(_ v: T) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(Data("RIFF".utf8)); le(UInt32(36 + pcm.count)); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); le(UInt32(16)); le(UInt16(1)); le(ch); le(sr); le(byteRate); le(block); le(bits)
        d.append(Data("data".utf8)); le(UInt32(pcm.count)); d.append(pcm)
        return d
    }
}
