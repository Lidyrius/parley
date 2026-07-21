import Foundation

// Per-project spoken announcements ("Ich habe ein Update für das Projekt X") played before
// the actual TTS sentence when more than one project runs in parallel — so you know which
// project is speaking. 10 phrasings per project are pre-rendered with Google TTS (session
// voice + language) and cached in Application Support/Parley/projects/<slug>, so playback is
// instant and varied. Rendering happens lazily in the background on first need; until it's
// ready the announcement is simply skipped (never blocks a turn).
actor ProjectClips {
    static let shared = ProjectClips()

    private var rendering: Set<String> = []

    private static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parley/projects", isDirectory: true)
    }

    private static func slug(_ s: String) -> String {
        let ok = s.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        return String(ok).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// A random cached announcement clip for `label`, or nil if none rendered yet (in which
    /// case rendering is kicked off for next time). `label` is the spoken project name.
    func clipData(label: String, language: String, config: AppConfig) async -> Data? {
        let s = Self.slug(label)
        guard !s.isEmpty else { return nil }
        let dir = Self.root.appendingPathComponent(s, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "pcm" } ?? []
        if let f = files.randomElement() { return try? Data(contentsOf: f) }
        await render(label: label, slug: s, language: language, config: config)
        return nil
    }

    private func render(label: String, slug: String, language: String, config: AppConfig) async {
        guard config.useGoogle, !rendering.contains(slug) else { return }
        rendering.insert(slug)
        defer { rendering.remove(slug) }
        let dir = Self.root.appendingPathComponent(slug, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, phrase) in Self.phrases(name: label, language: language).enumerated() {
            guard let pcm = await Self.synth(phrase, config: config) else { continue }
            try? pcm.write(to: dir.appendingPathComponent(String(format: "ann_%02d.pcm", i)))
        }
    }

    private static func synth(_ text: String, config: AppConfig) async -> Data? {
        let req = GoogleTTS.request(text: text, apiKey: config.googleKey, voice: config.googleVoice)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return GoogleTTS.pcm(from: data)
    }

    // {name} = the project's spoken label.
    private static func phrases(name: String, language: String) -> [String] {
        (templates[language] ?? templates["Deutsch"]!).map { $0.replacingOccurrences(of: "{name}", with: name) }
    }

    private static let templates: [String: [String]] = [
        "Deutsch": [
            "Ich habe ein Update für das Projekt {name}.",
            "Neuigkeiten aus dem Projekt {name}.",
            "Kurze Meldung zum Projekt {name}.",
            "Update für {name}.",
            "Zum Projekt {name}.",
            "Neues aus dem Projekt {name}.",
            "Eine Rückmeldung zu {name}.",
            "Betrifft das Projekt {name}.",
            "Hier ist {name}.",
            "Zum Stand von {name}.",
        ],
        "English": [
            "I have an update on the {name} project.",
            "News from the {name} project.",
            "A quick note on {name}.",
            "Update for {name}.",
            "Regarding the {name} project.",
            "Something new on {name}.",
            "Feedback on {name}.",
            "This concerns the {name} project.",
            "This is {name}.",
            "On the status of {name}.",
        ],
        "Français": [
            "J'ai une mise à jour pour le projet {name}.",
            "Des nouvelles du projet {name}.",
            "Un mot rapide sur {name}.",
            "Mise à jour pour {name}.",
            "Concernant le projet {name}.",
            "Du nouveau sur {name}.",
            "Un retour sur {name}.",
            "Cela concerne le projet {name}.",
            "Ici {name}.",
            "Sur l'état de {name}.",
        ],
        "Español": [
            "Tengo una actualización del proyecto {name}.",
            "Novedades del proyecto {name}.",
            "Una nota rápida sobre {name}.",
            "Actualización de {name}.",
            "Sobre el proyecto {name}.",
            "Algo nuevo en {name}.",
            "Comentarios sobre {name}.",
            "Esto concierne al proyecto {name}.",
            "Aquí {name}.",
            "Sobre el estado de {name}.",
        ],
        "Italiano": [
            "Ho un aggiornamento per il progetto {name}.",
            "Novità dal progetto {name}.",
            "Una breve nota su {name}.",
            "Aggiornamento per {name}.",
            "Riguardo al progetto {name}.",
            "Qualcosa di nuovo su {name}.",
            "Un riscontro su {name}.",
            "Riguarda il progetto {name}.",
            "Qui {name}.",
            "Sullo stato di {name}.",
        ],
        "Nederlands": [
            "Ik heb een update voor het project {name}.",
            "Nieuws uit het project {name}.",
            "Een korte melding over {name}.",
            "Update voor {name}.",
            "Over het project {name}.",
            "Iets nieuws over {name}.",
            "Een terugkoppeling over {name}.",
            "Dit betreft het project {name}.",
            "Hier is {name}.",
            "Over de status van {name}.",
        ],
    ]
}
