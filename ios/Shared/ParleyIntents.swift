import AppIntents

// The actions behind Siri, the controls (Control Center, Lock Screen, Action Button) and the Live
// Activity's buttons. Compiled into app and widget extension; `LiveActivityIntent` makes the
// system run them in the app's process (in the background, without opening it), where
// `ParleyActions` has the relay and CallKit — the extension's `ParleyActions` is never called.

/// "Hey Siri, Parley anrufen", the control, the Island's button: the same CallKit call as the
/// app's button — hands-free, on the Lock Screen and in the car.
/// App Store rule (ITMS-90626): intent descriptions must not name Apple products (iPhone, Mac,
/// CarPlay, …) — say "hier", "am Rechner", "im Auto".
struct CallParleyIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Parley anrufen" }
    static var description: IntentDescription { IntentDescription("Startet einen Anruf mit Parley – freihändig, auch im Auto.") }
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        try await ParleyActions.call()
        return .result()
    }
}

/// Unterwegs on/off: updates ring this iPhone instead of being voiced on the Mac.
struct SetAwayIntent: SetValueIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "Unterwegs" }
    static var description: IntentDescription { IntentDescription("Updates klingeln hier als Anruf, statt am Rechner gesprochen zu werden.") }

    @Parameter(title: "Unterwegs")
    var value: Bool

    func perform() async throws -> some IntentResult {
        await ParleyActions.setAway(value)
        return .result()
    }
}

/// Stumm on/off: a notification instead of a call. On implies Unterwegs (it only means anything
/// there).
struct SetSilentIntent: SetValueIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "Stumm" }
    static var description: IntentDescription { IntentDescription("Unterwegs kommt statt eines Anrufs eine Mitteilung.") }

    @Parameter(title: "Stumm")
    var value: Bool

    func perform() async throws -> some IntentResult {
        await ParleyActions.setSilent(value)
        return .result()
    }
}

/// A predicted answer, tapped in the Live Activity (Stumm): goes to that session as typed text.
struct ReplyIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Parley antworten" }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Session") var session: String
    @Parameter(title: "Antwort") var text: String

    init() {}
    init(session: String, text: String) {
        self.session = session
        self.text = text
    }

    func perform() async throws -> some IntentResult {
        await ParleyActions.reply(session: session, text: text)
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
