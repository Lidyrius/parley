import Foundation
import UserNotifications

// System notifications ("Parley — Voice-Modus aktiv" on skill start, etc.). Uses
// UNUserNotificationCenter so they're attributed to Parley; falls back to `osascript
// display notification` if authorization is denied or the center is unavailable (e.g. an
// unbundled dev run). Safe to call from anywhere.
@MainActor
enum Notifier {
    private static var requested = false

    static func requestAuth() {
        guard !requested else { return }
        requested = true
        center()?.requestAuthorization(options: [.alert, .sound]) { granted, err in
            if let err { Log.write("notif auth error: \(err.localizedDescription)") }
            else { Log.write("notif auth granted=\(granted)") }
        }
    }

    static func notify(title: String, body: String) {
        // In-app pill instead of a system notification, if the user chose it in Settings.
        if AppConfig.load().notifyInPill {
            NotificationPill.shared.present(title: title, message: body)
            return
        }
        guard let c = center() else { osa(title, body); return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        c.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { err in
            if let err { Log.write("notif add error: \(err.localizedDescription)"); osa(title, body) }
        }
    }

    // UNUserNotificationCenter.current() precondition-fails outside a bundle; guard it.
    private static func center() -> UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    nonisolated private static func osa(_ title: String, _ body: String) {
        let script = "display notification \"\(esc(body))\" with title \"\(esc(title))\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    nonisolated private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
