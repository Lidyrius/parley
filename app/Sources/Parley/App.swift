import SwiftUI
import AppKit

struct ParleyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = AppController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: controller)
                .task { controller.start() }
        } label: {
            Image(nsImage: AppIconChoice.menuBarImage)
                .accessibilityLabel("Parley")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started from inside a Claude Code session (a terminal, `open -a`), Parley inherits that
        // session's CLAUDE_CODE_* variables and would pass them on to every session it starts.
        for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix("CLAUDE_CODE_") { unsetenv(key) }
        // Menu-bar only: no dock icon. LSUIElement in Info.plist covers bundled
        // launches; this covers `swift run` / bare-executable launches.
        NSApp.setActivationPolicy(.accessory)
        // Start the control server at launch — NOT from the menu view's .task, which
        // (with menuBarExtraStyle(.window)) only runs when the popover is first opened.
        MainActor.assumeIsolated {
            if let dir = ProcessInfo.processInfo.environment["PARLEY_ONBOARDING_SNAPSHOTS"] {
                OnboardingPresenter.shared.snapshots(to: dir)
                return
            }
            AppController.shared.start()
            OnboardingPresenter.shared.showIfNeeded()   // first-run visual onboarding
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppController.shared.stopRelay() }
    }
}
