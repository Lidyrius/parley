import SwiftUI
import AppKit

@main
struct VloudeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = AppController()

    var body: some Scene {
        MenuBarExtra("Vloude", systemImage: "waveform") {
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
    }
}
