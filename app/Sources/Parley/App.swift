import SwiftUI
import AppKit

struct ParleyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = AppController.shared

    var body: some Scene {
        MenuBarExtra("Parley", systemImage: "waveform") {
            MenuBarView(controller: controller)
                .task { controller.start() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no dock icon. LSUIElement in Info.plist covers bundled
        // launches; this covers `swift run` / bare-executable launches.
        NSApp.setActivationPolicy(.accessory)
        // Start the control server at launch — NOT from the menu view's .task, which
        // (with menuBarExtraStyle(.window)) only runs when the popover is first opened.
        MainActor.assumeIsolated {
            AppController.shared.start()
            OnboardingPresenter.shared.showIfNeeded()   // first-run setup
        }
    }
}
