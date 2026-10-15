import Foundation

// Per-project spoken announcement ("Update zu X") played before the actual TTS sentence when
// another session is alive too — so you know which project is speaking. One fixed phrase per
// project, pre-rendered with Google TTS (session voice + language) and cached as
// Application Support/Parley/clips/announce/<slug>.pcm, so playback is instant. (The old
// 10-phrasing clips lived in Parley/projects/<slug> — a different path, so never reused.)
// Rendering happens lazily in the background on first need; until it's ready the
// announcement is simply skipped (never blocks a turn).
actor ProjectClips {
    static let shared = ProjectClips()

    private var rendering: Set<String> = []

    private static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parley/clips/announce", isDirectory: true)
    }

    private static func slug(_ s: String) -> String {
        let ok = s.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        return String(ok).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// The cached announcement clip for `label`, or nil if not rendered yet (in which case
    /// rendering is kicked off for next time). `label` is the spoken project name.
    func clipData(label: String, language: String, config: AppConfig) async -> Data? {
        let s = Self.slug(label)
        guard !s.isEmpty else { return nil }
        if let data = try? Data(contentsOf: Self.root.appendingPathComponent("\(s).pcm")) { return data }
        // Not cached → render in the BACKGROUND (never block the turn); the announcement
        // is skipped until ready. render() self-guards against concurrent renders.
        Task { [weak self] in await self?.render(label: label, slug: s, language: language, config: config) }
        return nil
    }

    private func render(label: String, slug: String, language: String, config: AppConfig) async {
        guard config.useGoogle, !rendering.contains(slug) else { return }
        rendering.insert(slug)
        defer { rendering.remove(slug) }
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        guard let pcm = await Self.synth(Self.phrase(name: label, language: language), config: config) else { return }
        try? pcm.write(to: Self.root.appendingPathComponent("\(slug).pcm"), options: .atomic)
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

    private static let templates: [String: String] = [
        "Deutsch": "Update zu {name}",
        "English": "Update on {name}",
        "Français": "Mise à jour sur {name}",
        "Español": "Actualización sobre {name}",
        "Italiano": "Aggiornamento su {name}",
        "Nederlands": "Update over {name}",
    ]
}
