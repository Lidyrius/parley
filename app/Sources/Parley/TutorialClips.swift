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

    /// The spoken (and displayed) line.
    func line(_ lang: String) -> String {
        lang == "English" ? Self.en[rawValue] : Self.de[rawValue]
    }

    private static let de = [
        "Willkommen, Sir. Am Ende jeder Antwort spreche ich die Zusammenfassung — Sie antworten einfach per Stimme.",
        "Sagen Sie „Stopp“, höre ich sofort auf und die Sitzung pausiert. Probieren Sie es: sagen Sie jetzt „Stopp“.",
        "Sagen Sie zum Beispiel „warte zehn Minuten“ — ich pausiere und melde mich von selbst zurück. Probieren Sie es.",
        "Läuft ein weiteres Projekt parallel, sagen Sie von hier aus einfach: „nimm das Projekt Soundso wieder auf“.",
        "Und wenn Sie etwas wissen möchten, stellen Sie einfach eine Frage — ich antworte sofort.",
        "Fertig, Sir. Starten Sie jetzt eine neue Claude-Code-Sitzung und tippen Sie Parley Voice — dann bin ich für Sie da.",
    ]
    private static let en = [
        "Welcome, Sir. At the end of every turn I speak the summary — you just reply by voice.",
        "Say “Stop” and I halt at once and the session pauses. Try it: say “Stop” now.",
        "Say, for example, “wait ten minutes” — I pause and report back on my own. Give it a try.",
        "If another project runs in parallel, just say from here: “resume the such-and-such project”.",
        "And whenever you want to know something, simply ask — I answer right away.",
        "All set, Sir. Now start a new Claude Code session and type Parley Voice — then I'm at your service.",
    ]
}

actor TutorialClips {
    static let shared = TutorialClips()
    static let version = 1        // bump when the tutorial changes → shown again

    private var rendering = false

    private static func dir(_ lang: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parley/tutorial/\(lang == "English" ? "en" : "de")", isDirectory: true)
    }

    /// Cached PCM for a step, rendering all steps first if needed (returns nil if not ready).
    func clip(_ step: TutorialStep, lang: String, config: AppConfig) async -> Data? {
        let file = Self.dir(lang).appendingPathComponent("step_\(step.rawValue).pcm")
        if let d = try? Data(contentsOf: file) { return d }
        await render(lang: lang, config: config)
        return try? Data(contentsOf: file)
    }

    func render(lang: String, config: AppConfig) async {
        guard config.useGoogle, !rendering else { return }
        rendering = true
        defer { rendering = false }
        let d = Self.dir(lang)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        for step in TutorialStep.allCases {
            let file = d.appendingPathComponent("step_\(step.rawValue).pcm")
            if FileManager.default.fileExists(atPath: file.path) { continue }
            let req = GoogleTTS.request(text: step.line(lang), apiKey: config.googleKey, voice: config.googleVoice)
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200, let pcm = GoogleTTS.pcm(from: data) else { continue }
            try? pcm.write(to: file)
        }
    }
}
