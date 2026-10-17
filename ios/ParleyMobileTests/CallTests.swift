import Foundation
import Testing
@testable import ParleyMobile

struct CallTests {
    @Test func lookPerState() {
        #expect(CallLook(phase: .ringing, host: .idle).mood == .ringing)
        #expect(CallLook(phase: .dialing, host: .speaking).mood == .connecting)
        #expect(CallLook(phase: .connecting, host: .idle).mood == .connecting)
        let since = Date()
        #expect(CallLook(phase: .active(since: since), host: .speaking).mood == .speaking)
        #expect(CallLook(phase: .active(since: since), host: .listening).mood == .listening)
        #expect(CallLook(phase: .active(since: since), host: .idle).mood == .idle)

        #expect(CallLook(phase: .active(since: since), host: .speaking).status == "spricht")
        #expect(CallLook(phase: .active(since: since), host: .listening).status == "hört zu")
        #expect(CallLook(phase: .active(since: since), host: .idle).state == .idle)
        #expect(CallLook(phase: .dialing, host: .idle).status == "Verbinde…")
    }

    @Test(arguments: [CallLook.Mood.ringing, .connecting, .speaking, .listening, .idle])
    func waveformStaysInBounds(_ mood: CallLook.Mood) {
        for level in [0.0, 0.3, 1.0, 5.0] {
            for t in stride(from: 0.0, to: 4, by: 0.13) {
                for bar in 0..<41 {
                    let a = Waveform.amplitude(mood, bar: bar, of: 41, t: t, level: level)
                    #expect(a >= 0 && a <= 1, "\(mood) bar \(bar) t \(t) level \(level) → \(a)")
                }
            }
        }
    }

    @Test(arguments: [HostAudio.speaking, .listening, .idle])
    func demoLevelsAreUsable(_ state: HostAudio) {
        let levels = stride(from: 0.0, to: 3, by: 0.05).map { Demo.level(state, at: Date(timeIntervalSinceReferenceDate: $0)) }
        #expect(levels.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @MainActor
    @Test func demoCallFlow() {
        let model = AppModel(arguments: ["-demo", "-demoCall", "incoming"])
        let call = model.call
        #expect(call.phase == .ringing && call.showsScreen)
        #expect(call.label == "Tippfrei")
        call.answer()
        #expect(call.phase.isActive)
        call.setMuted(true)
        #expect(call.muted)
        call.setSpeaker(true)
        #expect(call.speaker)
        call.hostAudioChanged(.speaking, label: "Shirts")
        #expect(call.hostAudio == .speaking && call.label == "Shirts")
        call.hangUp()
        #expect(call.phase == .none && !call.showsScreen && !call.muted && call.label == nil)
    }

    @MainActor
    @Test(arguments: Demo.CallState.allCases)
    func demoCallStatesOpenTheScreen(_ state: Demo.CallState) {
        let model = AppModel(arguments: ["-demo", "-demoCall", state.rawValue])
        #expect(model.call.showsScreen)
        #expect(model.call.isBusy)
        #expect(!model.away)  // demo never reads the stored Unterwegs-Modus
    }

    @MainActor
    @Test func demoWithoutCallStaysOnTheOverview() {
        let model = AppModel(arguments: ["-demo"])
        #expect(!model.call.showsScreen && !model.call.isBusy)
    }
}
