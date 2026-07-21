import Foundation

// Resolves cached-clip directories, preferring clips rendered at install time (per the
// user's chosen language + voice) over the bundled defaults. This is what lets the app
// ship prebuilt (no Xcode) while still speaking cached lines in the user's own voice:
// generate-clips-google.sh writes into Application Support/Parley/clips, no rebuild.
enum ClipPaths {
    static var userBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parley/clips", isDirectory: true)
    }

    /// Directory holding the .pcm clips for `rel` ("ready" or "lines/<intent>").
    /// User-rendered dir wins if it has clips; else the bundled resource dir.
    static func dir(_ rel: String) -> URL? {
        let user = userBase.appendingPathComponent(rel, isDirectory: true)
        if hasPCM(user) { return user }
        let parts = rel.split(separator: "/").map(String.init)
        if parts.count == 1 {
            return Bundle.module.url(forResource: parts[0], withExtension: nil)
        }
        return Bundle.module.url(forResource: parts[1], withExtension: nil, subdirectory: parts[0])
    }

    static func pcmFiles(_ rel: String) -> [URL] {
        guard let dir = dir(rel),
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return items.filter { $0.pathExtension == "pcm" }.sorted { $0.path < $1.path }
    }

    private static func hasPCM(_ dir: URL) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return false }
        return items.contains { $0.pathExtension == "pcm" }
    }
}
