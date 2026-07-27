import Foundation

// One pre-rendered spoken line per tutorial step, cached in Application Support/Parley/
// tutorial/<lang>. Rendered once (all steps) so the tutorial plays instantly. German +
// English authored; other languages fall back to German audio.
enum TutorialStep: Int, CaseIterable {
    case principle, stop, wait, projects, questions, finish

    var expect: Expect {
        switch self { case .stop: return .stop; case .wait: return .wait; default: return .none }
    }
    enum Expect { case none, stop, wait }

    func title(_ lang: String) -> String {
        let en = lang == "English"
        switch self {
        case .principle: return en ? "How it works"      : "So funktioniert's"
        case .stop:      return en ? "Say “Stop”"          : "Sag „Stopp“"
        case .wait:      return en ? "Ask me to wait"      : "Lass mich warten"
        case .projects:  return en ? "Parallel projects"   : "Parallele Projekte"
        case .questions: return en ? "Just ask"            : "Einfach fragen"
        case .finish:    return en ? "You're all set"      : "Fertig!"
        }
    }

    var symbol: String {
        switch self {
        case .principle: return "waveform"
        case .stop:      return "hand.raised.fill"
        case .wait:      return "clock.fill"
        case .projects:  return "rectangle.stack.fill"
        case .questions: return "questionmark.circle.fill"
        case .finish:    return "checkmark.seal.fill"
        }
    }

    /// The spoken line — contains the phonetic "Clode" so TTS says "Claude" correctly.
    func line(_ lang: String) -> String {
        lang == "English" ? Self.en[rawValue] : Self.de[rawValue]
    }

    /// Same line for on-screen display: spelled "Claude", not the phonetic "Clode".
    func displayLine(_ lang: String) -> String {
        line(lang).replacingOccurrences(of: "Clode", with: "Claude")
    }

    // Written to be HEARD as a flowing, friendly conversation (du-form). "Clode Code" is
    // the phonetic spelling of "Claude Code" so the voice says it correctly.
    private static let de = [
        "Willkommen bei Parley. Am Ende jeder Antwort spreche ich dir die Zusammenfassung vor, und du antwortest einfach mit deiner Stimme — ganz freihändig.",
        "Sag einfach Stopp, dann halte ich sofort an und die Sitzung pausiert. Probier es gleich — sag jetzt Stopp.",
        "Du kannst mir auch sagen: warte zehn Minuten. Dann lege ich eine Pause ein und melde mich von selbst wieder. Probier es ruhig aus.",
        "Läuft nebenbei ein anderes Projekt, sag mir einfach von hier aus: nimm das Projekt Soundso wieder auf. Das klappt aus jeder Sitzung.",
        "Und wenn du etwas wissen willst, frag einfach — ich antworte dir sofort.",
        "Das war's. Starte jetzt eine neue Clode-Code-Sitzung und tippe Parley Voice, dann bin ich für dich da.",
    ]
    private static let en = [
        "Welcome to Parley. At the end of every turn I speak you the summary, and you just reply with your voice — completely hands-free.",
        "Just say Stop and I halt at once and the session pauses. Try it now — say Stop.",
        "You can also tell me: wait ten minutes. Then I take a break and report back on my own. Give it a try.",
        "If another project is running, just tell me from here: resume the such-and-such project. It works from any session.",
        "And whenever you want to know something, just ask — I answer right away.",
        "That's it. Now start a new Clode Code session and type Parley Voice, and I'm here for you.",
    ]
}

actor TutorialClips {
    static let shared = TutorialClips()
    static let version = 2        // bump when the tutorial changes → shown again

    private var rendering = false

    private static func dir(_ lang: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parley/tutorial/\(lang == "English" ? "en" : "de")", isDirectory: true)
    }

    /// Cached PCM for a step, rendering all steps first if needed (returns nil if not ready).
    /// Keyed by voice so a voice change re-renders. key/voice come from the onboarding
    /// selection (not yet-saved config).
    func clip(_ step: TutorialStep, lang: String, key: String, voice: String) async -> Data? {
        let file = Self.dir(voice).appendingPathComponent("step_\(step.rawValue).pcm")
        if let d = try? Data(contentsOf: file) { return d }
        await render(lang: lang, key: key, voice: voice)
        return try? Data(contentsOf: file)
    }

    func render(lang: String, key: String, voice: String) async {
        guard !key.isEmpty, !rendering else { return }
        rendering = true
        defer { rendering = false }
        let d = Self.dir(voice)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        for step in TutorialStep.allCases {
            let file = d.appendingPathComponent("step_\(step.rawValue).pcm")
            if FileManager.default.fileExists(atPath: file.path) { continue }
            let req = GoogleTTS.request(text: step.line(lang), apiKey: key, voice: voice)
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200, let pcm = GoogleTTS.pcm(from: data) else { continue }
            try? pcm.write(to: file)
        }
    }
}
