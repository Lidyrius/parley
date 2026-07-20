import Foundation

// Random pre-rendered "Ich bin bereit" clip for the /ready greeting. Clips are raw
// pcm_24000 files bundled as SPM resources (generate-ready-clips.sh). If none are
// bundled (no API key at build time), pick() returns nil and /ready stays silent.
enum ReadyClips {
    /// All bundled .pcm clip URLs.
    static func all() -> [URL] {
        guard let dir = Bundle.module.url(forResource: "ready", withExtension: nil),
              let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { $0.pathExtension == "pcm" }.sorted { $0.path < $1.path }
    }

    /// Pick a random clip from the given list (pure — testable). nil if empty.
    static func pick(from files: [URL]) -> URL? {
        files.randomElement()
    }

    static func randomClipData() -> Data? {
        guard let url = pick(from: all()) else { return nil }
        return try? Data(contentsOf: url)
    }
}
