import SwiftUI
import WidgetKit

@main
struct ParleyWidgets: WidgetBundle {
    var body: some Widget {
        ParleyLiveActivity()
        CallControl()
        AwayControl()
        SilentControl()
    }
}

/// The intents run in the app's process (`LiveActivityIntent`); this copy only lets them compile
/// in the extension. Should the system ever run one here, the switches still land in the App
/// Group — the app picks them up when it next comes to the front.
enum ParleyActions {
    static func call() async throws {}
    static func setAway(_ on: Bool) async { SharedState.away = on }
    static func setSilent(_ on: Bool) async {
        if on { SharedState.away = true }
        SharedState.silent = on
    }
}
