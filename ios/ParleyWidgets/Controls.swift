import AppIntents
import SwiftUI
import WidgetKit

// Controls (iOS 18): Control Center, the Lock Screen's bottom corners and the Action Button.
// Their intents run in the app's process (Shared/ParleyIntents.swift); the switches' values come
// from the App Group, which the app keeps current and reloads the controls from.

struct CallControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: SharedState.callKind) {
            ControlWidgetButton(action: CallParleyIntent()) {
                Label("Parley anrufen", systemImage: "phone.fill")
                    .controlWidgetActionHint("Parley anrufen")
            }
            .tint(Paint.color(.accent, SharedState.colors, dark: true))
        }
        .displayName("Parley anrufen")
        .description("Ein Druck, und du sprichst mit Parley – auch über den Action Button.")
    }
}

struct AwayControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: SharedState.awayKind, provider: AwayValue()) { on in
            ControlWidgetToggle("Unterwegs", isOn: on, action: SetAwayIntent()) { on in
                Label(on ? "iPhone klingelt" : "Mac spricht", systemImage: on ? "figure.walk" : "desktopcomputer")
            }
            .tint(Paint.color(.accent, SharedState.colors, dark: true))
        }
        .displayName("Parley unterwegs")
        .description("Updates klingeln hier als Anruf, statt am Rechner gesprochen zu werden.")
    }
}

struct SilentControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: SharedState.silentKind, provider: SilentValue()) { on in
            ControlWidgetToggle("Parley stumm", isOn: on, action: SetSilentIntent()) { on in
                Label(on ? "Mitteilung statt Anruf" : "Anrufe", systemImage: on ? "bell.slash.fill" : "bell.fill")
            }
            .tint(Paint.color(.waiting, SharedState.colors, dark: true))
        }
        .displayName("Parley stumm")
        .description("Unterwegs kommt statt eines Anrufs eine Mitteilung. Schaltet Unterwegs mit ein.")
    }
}

struct AwayValue: ControlValueProvider {
    var previewValue: Bool { true }
    func currentValue() async throws -> Bool { SharedState.away }
}

struct SilentValue: ControlValueProvider {
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool { SharedState.away && SharedState.silent }
}
