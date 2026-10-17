import AppIntents
import UIKit
import WidgetKit

/// What the intents (Shared/ParleyIntents.swift) do — in the app's process.
@MainActor
enum ParleyActions {
    static func call() async throws {
        let model = AppModel.shared
        guard model.isPaired else { throw CallParleyError.notPaired }
        do {
            try await model.call.startOutgoing()
        } catch {
            throw CallParleyError.failed
        }
    }

    static func setAway(_ on: Bool) async {
        AppModel.shared.away = on
        await AppModel.shared.syncSwitches()
    }

    /// A tapped answer: to the host (dialling the relay in the background), and the activity
    /// shows it at once — the host's next update confirms.
    static func reply(session: String, text: String) async {
        let model = AppModel.shared
        await model.withRelay { model.say(text, to: session) }
        await model.activity.answered(text)
    }

    static func setSilent(_ on: Bool) async {
        if on { AppModel.shared.away = true }
        AppModel.shared.silent = on
        await AppModel.shared.syncSwitches()
    }
}

struct ParleyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CallParleyIntent(),
            // Phrases without "anrufen" first: "Ruf Parley an" alone goes to the Phone app (a contact
            // named Parley). The app name also matches its INAlternativeAppNames ("Parlay", …) —
            // what Siri hears in German. English phrases: en.lproj/AppShortcuts.strings.
            phrases: [
                "Sprich mit \(.applicationName)",
                "Mit \(.applicationName) sprechen",
                "Verbinde mich mit \(.applicationName)",
                "Starte einen \(.applicationName) Anruf",
                "\(.applicationName) Anruf starten",
                "Hey \(.applicationName)",
                "\(.applicationName) anrufen",
                "Ruf \(.applicationName) an",
            ],
            shortTitle: "Parley anrufen",
            systemImageName: "phone.fill"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .orange }
}
