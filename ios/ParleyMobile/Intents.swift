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

    /// A Focus came on (its filter's values) or went off (the defaults: both off).
    static func focus(away: Bool, silent: Bool) async {
        AppModel.shared.away = away
        AppModel.shared.silent = away && silent
        await AppModel.shared.syncSwitches()
    }

    static func setSilent(_ on: Bool) async {
        if on { AppModel.shared.away = true }
        AppModel.shared.silent = on
        await AppModel.shared.syncSwitches()
    }
}

/// Settings → Focus → (e.g. Driving) → Focus filters → Parley: Unterwegs (and Stumm) while that
/// Focus is on. When it goes off, iOS runs the filter with its defaults — both off — so Parley is
/// back at the desk by itself. No Apple product names in its texts (App Store rule ITMS-90626).
struct ParleyFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource { "Parley" }
    static var description: IntentDescription? { IntentDescription("Unterwegs und Stumm passend zu diesem Fokus.") }

    @Parameter(title: "Unterwegs", default: false) var away: Bool
    @Parameter(title: "Stumm", default: false) var silent: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Parley", subtitle: away ? (silent ? "Unterwegs, stumm" : "Unterwegs") : "Am Rechner")
    }

    func perform() async throws -> some IntentResult {
        await ParleyActions.focus(away: away, silent: silent)
        return .result()
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
