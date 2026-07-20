import SwiftUI
import AppKit

@main
struct VloudeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Vloude", systemImage: "waveform") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no dock icon, no main window. LSUIElement in Info.plist
        // covers bundled launches; this covers `swift run` / bare-executable launches.
        NSApp.setActivationPolicy(.accessory)
    }
}
