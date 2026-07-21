import Foundation

// Pre-rendered Jarvis acknowledgement lines, one folder per intent
// (Resources/lines/<intent>/*.pcm, raw pcm_24000). Bundled as SPM resources via
// generate-line-clips.sh. If none are bundled, randomClipData returns nil and the
// caller falls back to the chime.
enum LineClips {
    static func all(for intent: Intent) -> [URL] {
        ClipPaths.pcmFiles("lines/\(intent.folder)")
    }

    static func randomClipData(for intent: Intent) -> Data? {
        guard let url = all(for: intent).randomElement() else { return nil }
        return try? Data(contentsOf: url)
    }
}
