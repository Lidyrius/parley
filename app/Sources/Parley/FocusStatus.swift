import Foundation

// Best-effort macOS Focus / Do-Not-Disturb detection. The state lives in
// ~/Library/DoNotDisturb/DB/Assertions.json, which is TCC-protected: readable only if the
// app has Full Disk Access. When a Focus is active, `data[0].storeAssertionRecords` is
// non-empty. If we can't read it (no FDA), returns false — the manual mute toggle still
// works; DND just isn't auto-detected. ponytail: no public Focus API exists; this is the
// least-bad signal.
enum FocusStatus {
    static func doNotDisturbActive() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = (obj["data"] as? [[String: Any]])?.first?["storeAssertionRecords"] as? [Any]
        else { return false }
        return !records.isEmpty
    }
}
