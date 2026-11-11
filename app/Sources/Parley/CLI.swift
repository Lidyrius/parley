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

        if let i = args.firstIndex(of: "--render-menu"), i + 1 < args.count {
            MainActor.assumeIsolated { MenuSnapshot.render(to: args[i + 1], dark: args.contains("dark"), supervisor: args.contains("supervisor")) }
            return
        }

        // `Parley --transcribe reply.wav`: a recording (16 kHz mono 16-bit WAV, 44-byte header)
        // through the app's own transcription — a long one in pieces (SMOKE_TEST.md, "A long reply").
        if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count {
            guard let wav = try? Data(contentsOf: URL(fileURLWithPath: args[i + 1])) else { print("no such file"); return }
            let key = AppConfig.load().groqKey
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                let out = await Transcriber.run(wav: wav, apiKey: key) { req in
                    guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
                    return ((resp as? HTTPURLResponse)?.statusCode ?? -1, data)
                }
                print("seconds: \((wav.count - 44) / 32000), pieces: \(out.parts), failed: \(out.failed), characters: \(out.text?.count ?? -1)")
                print(out.text ?? "(nothing came through)")
                done.signal()
            }
            done.wait()
            return
        }

        ParleyApp.main()
    }
}
