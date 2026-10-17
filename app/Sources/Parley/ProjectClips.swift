import Foundation

// Per-project spoken lines, pre-rendered with Google TTS (session voice + language) and
// cached under Application Support/Parley/clips so playback is instant:
//   announce/<slug>.pcm     "Update zu X" — before a turn when another session is alive too
//                           (the old 10-phrasing clips lived in Parley/projects/<slug> — a
//                           different path, so never reused)
//   resume/<slug>-<n>.pcm   3 variants of "Ich habe die Arbeit an X wieder aufgenommen…" —
//                           opens the POST /resume voice dialog
//   greet/greet-<n>.pcm     3 variants of "Ja, Sir, wie kann ich helfen?" — the answer to the
//                           phone's wake word (not per project; rendered at launch)
// Everything for a project is rendered in the background as soon as its label first shows
// up (prerender). A missing announcement is simply skipped (never blocks a turn); a missing
// resume line is synthesized live and cached.
actor ProjectClips {
    static let shared = ProjectClips()

    private var rendering: Set<String> = []

    private static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parley/clips", isDirectory: true)
    }
    private static func announceFile(_ slug: String) -> URL { root.appendingPathComponent("announce/\(slug).pcm") }
    private static func resumeFile(_ slug: String, _ n: Int) -> URL { root.appendingPathComponent("resume/\(slug)-\(n).pcm") }
    private static func greetFile(_ n: Int) -> URL { root.appendingPathComponent("greet/greet-\(n).pcm") }
    private var greeting = false

    private static func slug(_ s: String) -> String {
        let ok = s.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        return String(ok).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// The cached announcement clip for `label`, or nil if not rendered yet (in which case
    /// rendering is kicked off for next time). `label` is the spoken project name.
    func clipData(label: String, language: String, config: AppConfig) async -> Data? {
        let s = Self.slug(label)
        guard !s.isEmpty else { return nil }
        if let data = try? Data(contentsOf: Self.announceFile(s)) { return data }
        // Not cached → render in the BACKGROUND (never block the turn); the announcement
        // is skipped until ready. prerender() self-guards against concurrent renders.
        Task { [weak self] in await self?.prerender(label: label, config: config) }
        return nil
    }

    /// A random cached resume line for `label`; if none is rendered yet, one is synthesized
    /// live (and cached) and the rest render in the background. nil = no Google TTS.
    func resumeClip(label: String, config: AppConfig) async -> Data? {
        let s = Self.slug(label)
        guard !s.isEmpty else { return nil }
        let cached = (0..<3).compactMap { try? Data(contentsOf: Self.resumeFile(s, $0)) }
        if let data = cached.randomElement() { return data }
        guard config.useGoogle else { return nil }
        let n = Int.random(in: 0..<3)
        guard let pcm = await Self.synth(Self.resumePhrases(name: label, language: config.language)[n], config: config)
        else { return nil }
        Self.write(pcm, to: Self.resumeFile(s, n))
        Task { [weak self] in await self?.prerender(label: label, config: config) }
        return pcm
    }

    /// A random cached wake greeting; if none is rendered yet, one is synthesized live (and
    /// cached) and the rest render in the background. nil = no Google TTS.
    func greetClip(config: AppConfig) async -> Data? {
        let cached = (0..<3).compactMap { try? Data(contentsOf: Self.greetFile($0)) }
        if let data = cached.randomElement() { return data }
        guard config.useGoogle else { return nil }
        let n = Int.random(in: 0..<3)
        guard let pcm = await Self.synth(Self.greetPhrases(language: config.language)[n], config: config) else { return nil }
        Self.write(pcm, to: Self.greetFile(n))
        Task { [weak self] in await self?.prerenderGreetings(config: config) }
        return pcm
    }

    /// Render the missing wake greetings.
    func prerenderGreetings(config: AppConfig) async {
        guard config.useGoogle, !greeting else { return }
        greeting = true
        defer { greeting = false }
        let lines = Self.greetPhrases(language: config.language)
        for (n, text) in lines.enumerated() where !FileManager.default.fileExists(atPath: Self.greetFile(n).path) {
            guard let pcm = await Self.synth(text, config: config) else { continue }
            Self.write(pcm, to: Self.greetFile(n))
        }
    }

    /// Render whatever is missing for `label`: the announcement and the 3 resume lines.
    func prerender(label: String, config: AppConfig) async {
        let s = Self.slug(label)
        guard config.useGoogle, !s.isEmpty, !rendering.contains(s) else { return }
        rendering.insert(s)
        defer { rendering.remove(s) }
        let resume = Self.resumePhrases(name: label, language: config.language)
        let jobs = [(Self.announceFile(s), Self.phrase(name: label, language: config.language))]
            + resume.indices.map { (Self.resumeFile(s, $0), resume[$0]) }
        for (file, text) in jobs where !FileManager.default.fileExists(atPath: file.path) {
            guard let pcm = await Self.synth(text, config: config) else { continue }
            Self.write(pcm, to: file)
        }
    }

    private static func write(_ pcm: Data, to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? pcm.write(to: file, options: .atomic)
    }

    private static func synth(_ text: String, config: AppConfig) async -> Data? {
        let req = GoogleTTS.request(text: text, apiKey: config.googleKey, voice: config.googleVoice)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return GoogleTTS.pcm(from: data)
    }

    // {name} = the project's spoken label.
    static func phrase(name: String, language: String) -> String {
        (templates[language] ?? templates["Deutsch"]!).replacingOccurrences(of: "{name}", with: name)
    }

    static func resumePhrases(name: String, language: String) -> [String] {
        (resumeTemplates[language] ?? resumeTemplates["Deutsch"]!).map { $0.replacingOccurrences(of: "{name}", with: name) }
    }

    static func greetPhrases(language: String) -> [String] {
        greetTemplates[language] ?? greetTemplates["Deutsch"]!
    }

    private static let greetTemplates: [String: [String]] = [
        "Deutsch": [
            "Ja, Sir, wie kann ich helfen?",
            "Zu Diensten, Sir. Was darf ich für Sie tun?",
            "Ich höre, Sir. Was steht an?",
        ],
        "English": [
            "Yes, Sir, how can I help?",
            "At your service, Sir. What can I do for you?",
            "I'm listening, Sir. What's next?",
        ],
        "Français": [
            "Oui, Monsieur, que puis-je faire pour vous ?",
            "À votre service, Monsieur. Que dois-je faire ?",
            "Je vous écoute, Monsieur. Quelle est la suite ?",
        ],
        "Español": [
            "Sí, señor, ¿en qué puedo ayudarle?",
            "A su servicio, señor. ¿Qué puedo hacer por usted?",
            "Le escucho, señor. ¿Qué sigue?",
        ],
        "Italiano": [
            "Sì, signore, come posso aiutarla?",
            "Ai suoi ordini, signore. Cosa posso fare per lei?",
            "La ascolto, signore. Qual è il prossimo passo?",
        ],
        "Nederlands": [
            "Ja, meneer, waarmee kan ik helpen?",
            "Tot uw dienst, meneer. Wat kan ik voor u doen?",
            "Ik luister, meneer. Wat staat er op het programma?",
        ],
    ]

    private static let templates: [String: String] = [
        "Deutsch": "Update zu {name}",
        "English": "Update on {name}",
        "Français": "Mise à jour sur {name}",
        "Español": "Actualización sobre {name}",
        "Italiano": "Aggiornamento su {name}",
        "Nederlands": "Update over {name}",
    ]

    private static let resumeTemplates: [String: [String]] = [
        "Deutsch": [
            "Ich habe die Arbeit an {name} wieder aufgenommen. Wie kann ich Ihnen helfen, Sir?",
            "Zurück bei {name}, Sir. Was steht an?",
            "{name} ist wieder aktiv, Sir. Wie soll ich weitermachen?",
        ],
        "English": [
            "I've resumed work on {name}. How can I help, Sir?",
            "Back on {name}, Sir. What's next?",
            "{name} is active again, Sir. How shall I proceed?",
        ],
        "Français": [
            "J'ai repris le travail sur {name}. Que puis-je faire pour vous, Monsieur ?",
            "De retour sur {name}, Monsieur. Quelle est la suite ?",
            "{name} est de nouveau actif, Monsieur. Comment dois-je poursuivre ?",
        ],
        "Español": [
            "He retomado el trabajo en {name}. ¿En qué puedo ayudarle, señor?",
            "De vuelta en {name}, señor. ¿Qué sigue?",
            "{name} vuelve a estar activo, señor. ¿Cómo debo continuar?",
        ],
        "Italiano": [
            "Ho ripreso il lavoro su {name}. Come posso aiutarla, signore?",
            "Di nuovo su {name}, signore. Qual è il prossimo passo?",
            "{name} è di nuovo attivo, signore. Come devo procedere?",
        ],
        "Nederlands": [
            "Ik heb het werk aan {name} hervat. Waarmee kan ik u helpen, meneer?",
            "Terug bij {name}, meneer. Wat staat er op het programma?",
            "{name} is weer actief, meneer. Hoe zal ik verdergaan?",
        ],
    ]
}
