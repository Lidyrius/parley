import Foundation

// Timestamped debug log to ~/Library/Application Support/Vloude/debug.log (and NSLog).
// Lets us trace the turn pipeline step-by-step when something hangs or drops.
enum Log {
    private static let queue = DispatchQueue(label: "de.developaway.vloude.log")

    private static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vloude", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("debug.log")
    }()

    static func write(_ msg: String) {
        NSLog("Vloude: \(msg)")
        let stamp = stamp()
        queue.async {
            let line = "\(stamp) \(msg)\n"
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    private static func stamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
