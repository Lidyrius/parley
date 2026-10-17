import AppIntents

/// "Hey Siri, Parley anrufen": starts the same CallKit call as the button. It runs without
/// opening the app, so it works hands-free, on the lock screen and in CarPlay (CallKit routes
/// the call to the car).
struct CallParleyIntent: AppIntent {
    static var title: LocalizedStringResource { "Parley anrufen" }
    static var description: IntentDescription { IntentDescription("Startet einen Anruf mit Parley – freihändig, auch in CarPlay.") }
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        guard model.isPaired else { throw CallParleyError.notPaired }
        do {
            try await model.call.startOutgoing()
        } catch {
            throw CallParleyError.failed
        }
        return .result()
    }
}

enum CallParleyError: Error, CustomLocalizedStringResourceConvertible {
    case notPaired, failed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notPaired: "Parley ist noch nicht gekoppelt. Öffne Parley und scanne den QR-Code."
        case .failed: "Der Anruf bei Parley ließ sich nicht starten."
        }
    }
}

struct ParleyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CallParleyIntent(),
            phrases: [
                "\(.applicationName) anrufen",
                "Ruf \(.applicationName) an",
                "Rufe \(.applicationName) an",
                "Hey \(.applicationName)",
                "Mit \(.applicationName) sprechen",
                "Sprich mit \(.applicationName)",
            ],
            shortTitle: "Parley anrufen",
            systemImageName: "phone.fill"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .orange }
}
