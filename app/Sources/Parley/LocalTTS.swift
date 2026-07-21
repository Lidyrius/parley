import Foundation
import AVFoundation

// On-device, zero-cost TTS via Apple's AVSpeechSynthesizer. Used when the "local voice"
// mode is on. Picks a calm German male voice, preferring higher-quality (premium/enhanced)
// system voices when the user has installed them (System Settings → Spoken Content).
final class LocalTTS: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    static let shared = LocalTTS()

    private let synth = AVSpeechSynthesizer()
    private var cont: CheckedContinuation<Void, Never>?

    override init() { super.init(); synth.delegate = self }

    func speak(_ text: String, voiceID: String?) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            self.cont = c
            let u = AVSpeechUtterance(string: text)
            u.voice = Self.resolveVoice(voiceID)
            u.rate = 0.48                       // a touch slower → calm
            u.pitchMultiplier = 0.98
            u.postUtteranceDelay = 0
            Log.write("local TTS voice=\(u.voice?.identifier ?? "default")")
            synth.speak(u)
        }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        cont?.resume(); cont = nil
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        cont?.resume(); cont = nil
    }

    // Pick the best available German male voice (or a specified identifier). The good
    // neural male voices (Markus/Yannick) must be downloaded by the user; the Eloquence
    // voices (Reed/Rocko/Eddy) are the retro fallback and aren't gender-tagged, so we
    // prefer known male names in quality order.
    static func resolveVoice(_ id: String?) -> AVSpeechSynthesisVoice? {
        if let id, !id.isEmpty, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        let de = germanVoices()
        let preferred = ["Markus", "Yannick", "Viktor", "Reed", "Rocko", "Eddy", "Grandpa"]
        for name in preferred {
            if let v = de.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) { return v }
        }
        if let male = de.first(where: { $0.gender == .male }) { return male }
        return de.max { rank($0) < rank($1) } ?? de.first
    }
    private static func rank(_ v: AVSpeechSynthesisVoice) -> Int {
        switch v.quality { case .premium: 3; case .enhanced: 2; default: 1 }
    }

    static func germanVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("de") }
    }
}
