import Foundation
import Testing
@testable import ParleyMobile

struct CallTests {
    @Test func lookPerState() {
        #expect(CallLook(phase: .ringing, host: .idle).mood == .ringing)
        #expect(CallLook(phase: .dialing, host: .speaking).mood == .connecting)
        #expect(CallLook(phase: .connecting, host: .idle).mood == .connecting)
        // Just connected, the host hasn't spoken yet: no flash of the idle green.
        #expect(CallLook(phase: .active(since: .now), host: .idle, awaitingHost: true).mood == .connecting)
        #expect(CallLook(phase: .active(since: .now), host: .speaking, awaitingHost: true).mood == .speaking)
        #expect(CallLook(phase: .active(since: .now), host: .idle).mood == .idle)
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
        call.hostAudioChanged(.speaking, label: "Zentrale")   // same state, new speaker
        #expect(call.label == "Zentrale")
        call.hostAudioChanged(.listening, label: nil)          // no label → keeps the last one
        #expect(call.label == "Zentrale")
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

/// Protocol v8, "Funkloch": a clip plays once all of it is here; the mic is numbered, kept and
/// sent again after a break (Funkloch.swift).
struct FunklochTests {
    private func frame(_ n: UInt8) -> Data { Data(repeating: n, count: 960) }

    @Test func aClipPlaysOnlyOnceAllOfItIsHere() {
        var clip = ClipBuffer()
        var taken = clip.add(frame(9))
        #expect(!taken)                                                // no clip open: an older host streams
        clip.start(id: 4, from: 0)
        for n in 0..<3 { taken = clip.add(frame(UInt8(n))); #expect(taken) }
        #expect(clip.have == 3 && !clip.released)
        var out = clip.end(id: 4, frames: 5, listen: true)
        #expect(out == nil)                                            // the line broke: two are missing
        #expect(clip.have == 3 && clip.total == 5)
        taken = clip.add(frame(9))
        #expect(!taken)                                                // between clips: not held back
        clip.start(id: 4, from: 3)                                     // the rest, from where this phone stands
        _ = clip.add(frame(3)); _ = clip.add(frame(4))
        out = clip.end(id: 4, frames: 5, listen: true)
        #expect(out == (0..<5).map { frame(UInt8($0)) })
        #expect(clip.released && clip.listen)
        clip.start(id: 4, from: 0)                                     // sent again without need: it plays already
        taken = clip.add(frame(7))
        #expect(taken)
        out = clip.end(id: 4, frames: 5, listen: true)
        #expect(out == nil)                                            // … not a second time
        #expect(clip.frames == (0..<5).map { frame(UInt8($0)) })
    }

    @Test func aClipSentAgainFromEarlierOrWithAHoleIsPutRight() {
        var clip = ClipBuffer()
        clip.start(id: 1, from: 0)
        for n in 0..<4 { _ = clip.add(frame(UInt8(n))) }
        clip.start(id: 1, from: 2)                                     // the host starts over at frame 2
        _ = clip.add(frame(12)); _ = clip.add(frame(13))
        var out = clip.end(id: 1, frames: 4, listen: false)
        #expect(out == [frame(0), frame(1), frame(12), frame(13)])

        var hole = ClipBuffer()
        hole.start(id: 2, from: 6)                                     // frames 0…5 never came: these would not fit
        _ = hole.add(frame(6))
        out = hole.end(id: 2, frames: 7, listen: false)
        #expect(out == nil)
        #expect(hole.have == 0)                                        // "I have none" — the host starts at 0
        hole.start(id: 3, from: 0)                                     // another clip: the old one is gone
        #expect(hole.id == 3 && hole.have == 0 && hole.total == nil)
        out = hole.end(id: 9, frames: 0, listen: false)
        #expect(out == nil)                                            // an end that isn't its own
    }

    private final class Line: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [Data] = []
        func send(_ d: Data) { lock.withLock { list.append(d) } }
        var sent: [Data] { lock.withLock { list } }
        var numbers: [UInt32] { sent.map { $0.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian } } }
    }
    private let pcm = Data(repeating: 5, count: 640)

    @Test func anOlderHostGetsTheMicAsItIs() {
        let line = Line()
        let mic = MicLedger(send: line.send)
        mic.begin(numbered: false)
        mic.push(pcm)
        mic.hold()
        mic.push(pcm)
        #expect(line.sent == [pcm, pcm])
        #expect(mic.waiting == 0)
    }

    @Test func theMicIsNumberedKeptAndSentAgainAfterABreak() {
        let line = Line()
        let mic = MicLedger(send: line.send)
        mic.begin(numbered: true)
        for _ in 0..<5 { mic.push(pcm) }
        #expect(line.numbers == [1, 2, 3, 4, 5])
        #expect(line.sent.allSatisfy { $0.count == 644 && $0.dropFirst(4) == pcm })
        mic.acked(3)                                                   // the host has 1…3
        #expect(mic.waiting == 2)

        mic.hold()                                                     // the forest: nothing goes out …
        for _ in 0..<50 { mic.push(pcm) }                              // … Sir talks for a second
        #expect(line.sent.count == 5)
        #expect(mic.waiting == 52)
        mic.acked(4)                                                   // back: the host says it has 1…4
        #expect(line.numbers.dropFirst(5).elementsEqual(5...55))       // 5 (lost on the way) and all he said, in order
        mic.push(pcm)
        #expect(line.numbers.last == 56)                               // and live again
        mic.acked(56)
        #expect(mic.waiting == 0)
    }

    @Test func aSilentHostDoesNotHoldTheMicBackAndAThreeMinuteGapIsKept() {
        let line = Line()
        let mic = MicLedger(send: line.send)
        mic.begin(numbered: true)
        mic.hold()
        for _ in 0..<(MicLedger.patience - 1) { mic.push(pcm) }
        #expect(line.sent.isEmpty)
        mic.push(pcm)                                                  // three seconds without its word: go on
        #expect(line.numbers.elementsEqual(1...UInt32(MicLedger.patience)))

        mic.begin(numbered: true)                                      // a new call starts at 1 again
        mic.hold()
        for _ in 0..<(MicLedger.keep + 500) { mic.push(pcm) }
        #expect(mic.waiting == MicLedger.keep)                         // the newest three minutes
    }

    @Test func framesOfTheProtocol() {
        #expect(Outgoing.call(started: true) == #"{"down":24000,"state":"start","t":"call"}"#)
        #expect(Outgoing.call(started: true, clips: true) == #"{"down":24000,"state":"start","t":"call","v":8}"#)
        #expect(Outgoing.callIdle == #"{"state":"idle","t":"call"}"#)
        #expect(Outgoing.clip(id: 4, have: 12, played: true) == #"{"have":12,"id":4,"played":true,"t":"clip"}"#)
        // v9: where the clip ended, in the mic's own count.
        #expect(Outgoing.clip(id: 4, have: 12, played: true, mic: 77) == #"{"have":12,"id":4,"mic":77,"played":true,"t":"clip"}"#)
        #expect(Frame.decode(#"{"t":"clip","id":4,"from":12}"#) == .clipStart(id: 4, from: 12))
        #expect(Frame.decode(#"{"t":"clip","id":4,"frames":50,"play":true,"listen":true}"#) == .clipEnd(id: 4, frames: 50, listen: true))
        #expect(Frame.decode(#"{"t":"mic","got":9}"#) == .micGot(9))
        #expect(Frame.decode(#"{"t":"clip","id":0,"from":0}"#) == .other("clip"))
        guard case .sessions(let s)? = Frame.decode(#"{"t":"sessions","at":1000,"call":8,"sessions":[]}"#) else { Issue.record("no sessions"); return }
        #expect(s.callVersion == 8)
        guard case .sessions(let old)? = Frame.decode(#"{"t":"sessions","at":1000,"sessions":[]}"#) else { Issue.record("no sessions"); return }
        #expect(old.callVersion == 0)                                  // an older host: as before
    }
}

/// Überwachungsmodus in the app: the Zentrale's card and the switch.
struct ZentraleCardTests {
    @Test func threeButtonsAndTheOneThatMattersNow() {
        // Nothing asked for: the history, a message, and the call — which is the thing to do.
        var row = ZentraleButton.row(action: nil, inCall: false)
        #expect(row.buttons == [.history, .message, .call(inCall: false)])
        #expect(row.primary == .call(inCall: false))
        #expect(row.buttons.map(\.title) == ["Verlauf", "Nachricht", "Anrufen"])
        // Parked: "Fortsetzen" is what its state asks for.
        row = ZentraleButton.row(action: .resume, inCall: false)
        #expect(row.buttons == [.history, .action(.resume), .call(inCall: false)])
        #expect(row.primary == .action(.resume))
        // Its call was not taken: "Rückrufen" is the call — no second call button beside it.
        row = ZentraleButton.row(action: .callBack(now: false), inCall: false)
        #expect(row.buttons.map(\.title) == ["Verlauf", "Rückrufen", "Nachricht"])
        #expect(row.primary == .action(.callBack(now: false)))
        // In a call the third one leads back to it.
        row = ZentraleButton.row(action: nil, inCall: true)
        #expect(row.buttons.last?.title == "Zum Anruf")
        for action in [SessionAction?.none, .resume, .callBack(now: true), .callBack(now: false)] {
            for inCall in [false, true] {
                let r = ZentraleButton.row(action: action, inCall: inCall)
                #expect(r.buttons.count == 3 && Set(r.buttons.map(\.id)).count == 3 && r.buttons.contains(r.primary))
            }
        }
    }

    @Test func theSwitchAndWhatTheHostSaysBack() {
        #expect(Outgoing.supervisor(false) == #"{"on":false,"t":"supervisor"}"#)
        #expect(Outgoing.supervisor(true) == #"{"on":true,"t":"supervisor"}"#)
        guard case .sessions(let s)? = Frame.decode(#"{"t":"sessions","at":1,"call":8,"supervisor":true,"missed":3,"sessions":[{"id":"z","label":"Zentrale","zentrale":true,"callback":0}]}"#)
        else { Issue.record("no sessions"); return }
        #expect(s.supervisor && s.missed == 3 && s.callVersion == 8)
        #expect(SessionAction(s.sessions[0]) == .callBack(now: false))   // the card offers "Rückrufen"
        guard case .sessions(let old)? = Frame.decode(#"{"t":"sessions","at":1,"sessions":[]}"#) else { Issue.record("no sessions"); return }
        #expect(!old.supervisor && old.missed == 0)
    }
}
