import Foundation

// Pre-rendered Jarvis acknowledgement lines, one folder per intent
// (Resources/lines/<intent>/*.pcm, raw pcm_24000). Bundled as SPM resources via
// generate-line-clips.sh. If none are bundled, randomClipData returns nil and the
// caller falls back to the chime.
enum LineClips {
    static func all(for intent: Intent) -> [URL] {
        guard let base = Bundle.module.url(forResource: "lines", withExtension: nil) else { return [] }
        let dir = base.appendingPathComponent(intent.folder, isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { $0.pathExtension == "pcm" }.sorted { $0.path < $1.path }
    }

    static func randomClipData(for intent: Intent) -> Data? {
        guard let url = all(for: intent).randomElement() else { return nil }
        return try? Data(contentsOf: url)
    }
}
