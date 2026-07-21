import Foundation

// Entry point. Handles a few headless CLI modes used by the terminal onboarding
// (scripts/onboard-tui.sh) before falling through to the normal SwiftUI menu-bar app.
@main
enum ParleyMain {
    static func main() {
        let args = CommandLine.arguments

        if args.contains("--list-mics") {
            let arr = AudioDevices.inputDevices().map { ["uid": $0.uid, "name": $0.name] }
            if let d = try? JSONSerialization.data(withJSONObject: arr),
               let s = String(data: d, encoding: .utf8) { print(s) }
            return
        }

        if let i = args.firstIndex(of: "--set-mic"), i + 1 < args.count {
            print(AudioDevices.setDefaultInput(uid: args[i + 1]) ? "ok" : "failed")
            return
        }

        if args.contains("--mark-onboarded") {
            UserDefaults.standard.set(true, forKey: "parley.onboardingComplete")
            return
        }

        ParleyApp.main()
    }
}
