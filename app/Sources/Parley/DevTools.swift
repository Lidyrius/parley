import Foundation
import AppKit

// Developer tools (menu-bar "Entwickler" submenu). Handy for testing the app end to end.
// The statistics (stats.json) are NEVER touched by any of these.
@MainActor
enum DevTools {
    private static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parley", isDirectory: true)
    }

    /// Fresh-install simulation: wipe credentials, cached clips and the onboarded flag so
    /// the onboarding flow runs again — but KEEP stats.json (and the log). Then reopen it.
    static func resetKeepingStats() {
        let fm = FileManager.default
        try? fm.removeItem(at: dir.appendingPathComponent("credentials.json"))
        try? fm.removeItem(at: dir.appendingPathComponent("clips"))
        try? fm.removeItem(at: dir.appendingPathComponent("projects"))   // legacy path, if any
        try? fm.removeItem(at: dir.appendingPathComponent("tutorial"))
        Log.write("devtools: reset (kept stats), reopening onboarding")
        OnboardingPresenter.shared.restart()   // discard any open window → fresh from welcome
    }

    static func showOnboarding() { OnboardingPresenter.shared.restart() }

    static func testNotification() {
        Notifier.notify(title: "Parley · Test", body: "So sieht eine Benachrichtigung aus, Sir.")
    }

    /// Show the recording pill for ~3 s with synthetic levels (no mic).
    static func testRecordingPill() {
        let hud = RecordingHUD()
        hud.show()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        var n = 0
        t.setEventHandler {
            MainActor.assumeIsolated {
                hud.push(Float.random(in: 0.2...0.9))
                n += 1
                if n > 90 { t.cancel(); hud.finish() }
            }
        }
        t.resume()
        demoTimer = t
    }
    private static var demoTimer: DispatchSourceTimer?

    /// Drop cached clips so they re-render (in the chosen voice/language) on next use.
    static func rerenderClips() {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("clips"))
        Log.write("devtools: cleared cached clips")
    }

    static func revealLog() {
        let log = dir.appendingPathComponent("debug.log")
        NSWorkspace.shared.selectFile(log.path, inFileViewerRootedAtPath: dir.path)
    }
}
