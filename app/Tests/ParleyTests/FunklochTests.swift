import XCTest
@testable import Parley

// Protocol v8, "Funkloch": a line reaches the phone as a clip it plays once it holds all of it,
// the phone's mic is numbered and follows after a dead zone, and the call waits one out.
final class FunklochTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_760_000_000) }

    /// A v8 phone as the clip sees it: what went down the line, and its word back.
    private final class ClipLink: CallLink, @unchecked Sendable {
        private let lock = NSLock()
        private var _out: [String] = []          // "clip …" headers as sent, "f" per frame
        private var _frames: [Data] = []
        private var _sink: (@Sendable (ClipStatus) -> Void)?
        private var _live = true
        private var _stalled = false
        private var _barged = false
        var down = PhoneAudioFormat.hiFiRate

        var out: [String] { lock.withLock { _out } }
        var frames: [Data] { lock.withLock { _frames } }
        var live: Bool { get { lock.withLock { _live } } set { lock.withLock { _live = newValue } } }
        var isStalled: Bool { get { lock.withLock { _stalled } } set { lock.withLock { _stalled = newValue } } }
        var isBarged: Bool { get { lock.withLock { _barged } } set { lock.withLock { _barged = newValue } } }
        func say(_ s: ClipStatus) { lock.withLock { _sink }?(s) }
        var listening: Bool { lock.withLock { _sink != nil } }

        var callGeneration: Int { 1 }
        func isLive(_ generation: Int) -> Bool { live }
        func sendAudio(_ frame: Data) { lock.withLock { _frames.append(frame); _out.append("f") } }
        func setAudioState(_ state: PhoneAudioState) {}
        func setAudioSink(_ sink: (@Sendable (Data) -> Void)?) {}
        var downRate: Int { down }
        var barged: Bool { isBarged }
        var clips: Bool { true }
        var stalled: Bool { isStalled }
        func sendControl(_ text: String) { lock.withLock { _out.append(text) } }
        func setClipSink(_ sink: (@Sendable (ClipStatus) -> Void)?) { lock.withLock { _sink = sink } }
        private var _after: [[Int]] = []
        var listensAfter: [[Int]] { lock.withLock { _after } }
        func listensAfter(clip id: Int, frames: Int) { lock.withLock { _after.append([id, frames]) } }
    }

    private func pcm(_ seconds: Double) -> Data { PCMFrames.bytes(PCMFrames.int16(sine(440, rate: 24000, seconds: seconds))) }

    private func until(_ what: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 where !what() { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(what(), file: file, line: line)
    }

    // MARK: - the clip

    func testTheWholeLineGoesOutAtOnceAndIsDoneWhenThePhonePlayedIt() async {
        let link = ClipLink()
        let clip = PhoneClip(link: link, rate: 1, id: 7)
        clip.enqueue(pcm(2))
        let start = Date()
        async let rest = clip.finish(beep: true)
        // 2 s speech + 0.18 s beep at 24 kHz = 109 frames of 960 bytes — all there long before 2 s passed.
        await until(link.out.last == RelayFrame.clipEnd(id: 7, frames: 109, listen: true))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(link.out.first, RelayFrame.clip(id: 7, from: 0))
        XCTAssertEqual(link.frames.count, 109)
        XCTAssertTrue(link.frames.allSatisfy { $0.count == 960 })
        XCTAssertEqual(link.listensAfter, [[7, 109]])                // Parley listens after it: the link sorts the mic
        link.say(ClipStatus(id: 7, have: 109, played: false))        // it holds all of it: nothing to do
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(link.frames.count, 109)
        link.say(ClipStatus(id: 7, have: 109, played: true))
        let played = await rest
        XCTAssertNil(played)
        XCTAssertFalse(link.listening)
    }

    func testAfterABreakTheRestFollowsFromWhereThePhoneStands() async {
        let link = ClipLink()
        let clip = PhoneClip(link: link, rate: 1, id: 3)
        clip.enqueue(pcm(1))
        async let rest = clip.finish(beep: false)                    // 1 s + 20 ms marker = 51 frames
        await until(link.frames.count == 51)
        link.say(ClipStatus(id: 3, have: 20, played: false))         // the line broke at frame 20
        await until(link.frames.count == 51 + 31)
        let again = link.out.dropFirst(53)                           // header + 51 frames + end went before
        XCTAssertEqual(again.first, RelayFrame.clip(id: 3, from: 20))
        XCTAssertEqual(again.last, RelayFrame.clipEnd(id: 3, frames: 51, listen: false))
        XCTAssertEqual(Array(link.frames[51...]), Array(link.frames[20..<51]))   // the very frames it lacks
        link.say(ClipStatus(id: 2, have: 40, played: true))          // it never heard of this clip at all
        await until(link.frames.count == 51 + 31 + 51)
        XCTAssertTrue(link.out.contains(RelayFrame.clip(id: 3, from: 0)))
        link.say(ClipStatus(id: 3, have: 51, played: true))
        let played = await rest
        XCTAssertNil(played)
    }

    func testTheCallEndingHandsTheSpeechBackUnlessThePhoneHeldItAll() async {
        let link = ClipLink()
        let speech = pcm(1)
        let clip = PhoneClip(link: link, rate: 1, id: 1)
        clip.enqueue(speech)
        async let rest = clip.finish(beep: true)
        await until(link.frames.count == 59)
        link.say(ClipStatus(id: 1, have: 30, played: false))
        link.live = false                                            // … and the call is gone
        let unplayed = await rest
        XCTAssertEqual(unplayed, speech)                             // for the Mac's speaker

        let whole = ClipLink()
        let second = PhoneClip(link: whole, rate: 1, id: 2)
        second.enqueue(speech)
        async let none = second.finish(beep: true)
        await until(whole.frames.count == 59)
        whole.say(ClipStatus(id: 2, have: 59, played: false))        // it held all of it: it played, line or no line
        try? await Task.sleep(nanoseconds: 80_000_000)
        whole.live = false
        let nothing = await none
        XCTAssertNil(nothing)
    }

    func testBargeInEndsTheClipAndAPhoneThatSaysNothingDoesNotHoldTheTurn() async {
        let link = ClipLink()
        let clip = PhoneClip(link: link, rate: 1, id: 1)
        clip.enqueue(pcm(1))
        async let rest = clip.finish(beep: true)
        await until(link.frames.count == 59)
        link.isBarged = true
        let barged = await rest
        XCTAssertNil(barged)

        let clock = Clock()
        let mute = ClipLink()
        let silent = PhoneClip(link: mute, rate: 1, id: 2, now: { clock.t })
        silent.enqueue(pcm(1))
        async let gone = silent.finish(beep: true)
        await until(mute.frames.count == 59)
        mute.isStalled = true
        clock.t += 120                                               // a dead zone: its time doesn't count
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(mute.listening)
        mute.isStalled = false
        try? await Task.sleep(nanoseconds: 150_000_000)
        clock.t += 59 * 0.02 + PhoneClip.patience + 1                // on the line and no word: go on
        let on = await gone
        XCTAssertNil(on)
    }

    // MARK: - the frames

    func testFramesAndWhatThePhoneSays() {
        XCTAssertEqual(RelayFrame.sessions("{}", at: Date(timeIntervalSince1970: 1)), #"{"t":"sessions","at":1000,"call":9}"#)
        XCTAssertEqual(RelayFrame.parse(#"{"t":"call","state":"start","down":24000,"v":8}"#), .call(true, down: 24000, clips: true))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"call","state":"start","down":24000}"#), .call(true, down: 24000, clips: false))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"call","state":"idle"}"#), .callIdle)
        XCTAssertEqual(RelayFrame.parse(#"{"t":"clip","id":4,"have":12,"played":true}"#), .clip(ClipStatus(id: 4, have: 12, played: true)))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"clip","id":0,"have":0}"#), .clip(ClipStatus(id: 0, have: 0, played: false)))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"clip","id":4,"have":12,"played":true,"mic":77}"#), .clip(ClipStatus(id: 4, have: 12, played: true, mic: 77)))
        XCTAssertNil(RelayFrame.parse(#"{"t":"clip","id":"x"}"#))
        XCTAssertEqual(RelayFrame.clip(id: 4, from: 12), #"{"t":"clip","id":4,"from":12}"#)
        XCTAssertEqual(RelayFrame.clipEnd(id: 4, frames: 50, listen: true), #"{"t":"clip","id":4,"frames":50,"play":true,"listen":true}"#)
        XCTAssertEqual(RelayFrame.micGot(9), #"{"t":"mic","got":9}"#)
    }

    // Optionen → "Funkloch-Schutz" off: the host says nothing of v8 and takes every call as a plain one.
    func testTheWayBackToPlainCalls() {
        RelayFrame.offersClips = false
        defer { RelayFrame.offersClips = true }
        XCTAssertEqual(RelayFrame.sessions("{}", at: Date(timeIntervalSince1970: 1)), #"{"t":"sessions","at":1000}"#)
        XCTAssertEqual(RelayFrame.parse(#"{"t":"call","state":"start","down":24000,"v":8}"#), .call(true, down: 24000, clips: false))
    }

    // MARK: - the hub: a numbered mic, and a call that waits

    private func numbered(_ seq: UInt32, _ fill: UInt8 = 1) -> Data {
        Data([UInt8(seq & 0xff), UInt8(seq >> 8 & 0xff), UInt8(seq >> 16 & 0xff), UInt8(seq >> 24)]) + Data(repeating: fill, count: 640)
    }

    private final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var _texts: [String] = [], _heard: [Data] = [], _logs: [String] = []
        func text(_ s: String) { lock.withLock { _texts.append(s) } }
        func hear(_ d: Data) { lock.withLock { _heard.append(d) } }
        func log(_ s: String) { lock.withLock { _logs.append(s) } }
        var texts: [String] { lock.withLock { _texts } }
        var heard: [Data] { lock.withLock { _heard } }
        var logs: [String] { lock.withLock { _logs } }
    }

    private func hub(_ clock: Clock, _ wire: Wire) -> PhoneHub {
        let hub = PhoneHub(store: .memory(), log: { wire.log($0) }, now: { clock.t })
        hub.attach(text: { wire.text($0) }, audio: { _ in })
        return hub
    }

    func testANumberedMicArrivesOnceInOrderAndIsAcknowledged() {
        let clock = Clock(), wire = Wire()
        let hub = hub(clock, wire)
        hub.handle(.call(true, down: 24000, clips: true))
        XCTAssertTrue(hub.clips)
        hub.setAudioSink { wire.hear($0) }
        hub.audioIn(numbered(1))
        hub.audioIn(numbered(2, 2))
        hub.audioIn(numbered(2, 9))                                  // sent again after a break: not twice
        hub.audioIn(numbered(1, 9))
        hub.audioIn(numbered(5, 5))                                  // a gap (the phone dropped old ones): taken
        XCTAssertEqual(wire.heard.map(\.count), [640, 640, 640])
        XCTAssertEqual(wire.heard.map { $0.first }, [1, 2, 5])
        hub.checkAlive()
        XCTAssertEqual(wire.texts.last, RelayFrame.micGot(5))
        let n = wire.texts.count
        hub.checkAlive()
        XCTAssertEqual(wire.texts.count, n)                           // nothing new: no word

        final class Said: @unchecked Sendable { var list: [ClipStatus] = [] }
        let said = Said()
        hub.setClipSink { said.list.append($0) }
        hub.handle(.clip(ClipStatus(id: 3, have: 10, played: false)))  // e.g. after a break: where the mic stands, too
        XCTAssertEqual(said.list, [ClipStatus(id: 3, have: 10, played: false)])
        XCTAssertEqual(wire.texts.last, RelayFrame.micGot(5))
        XCTAssertEqual(wire.texts.count, n + 1)
    }

    func testWhatComesBeforeTheListenerIsThereIsKeptForItAndWhatWasRecordedDuringTheClipIsNot() {
        let clock = Clock(), wire = Wire()
        let hub = hub(clock, wire)
        hub.handle(.call(true, down: 24000, clips: true))
        for n in 1...10 { hub.audioIn(numbered(UInt32(n), UInt8(n))) }
        XCTAssertEqual(hub.micHeard, 10)
        hub.listensAfter(clip: 5, frames: 4)                          // a clip of 4 frames, and Parley listens after it
        hub.handle(.clip(ClipStatus(id: 5, have: 4, played: false)))  // the phone holds it at mic frame 10: it plays 11…14
        hub.handle(.clip(ClipStatus(id: 5, have: 4, played: true)))   // (after a dead zone) played — the clip was over at 14
        XCTAssertEqual(wire.texts.suffix(2), [RelayFrame.micGot(10), RelayFrame.micGot(10)])   // … and now the phone may send
        for n in 11...20 { hub.audioIn(numbered(UInt32(n), UInt8(n))) }   // all it kept, in one burst — nobody listens yet
        XCTAssertTrue(wire.heard.isEmpty)
        hub.setAudioSink { wire.hear($0) }                            // the listener arrives a moment later
        XCTAssertEqual(wire.heard.map { $0.first }, [15, 16, 17, 18, 19, 20])   // his answer, from its first frame
        hub.audioIn(numbered(21, 21))
        XCTAssertEqual(wire.heard.last?.first, 21)                    // and live from there
        hub.setAudioSink(nil)
        hub.audioIn(numbered(22, 22))
        hub.setAudioSink { wire.hear($0) }                            // another listening, no clip before it: nothing old
        XCTAssertEqual(wire.heard.count, 7)
    }

    // v9: the phone began the clip while it still arrived, so "it holds all of it" is no longer
    // where it starts — it says itself at which mic frame the clip was over.
    func testAPhoneThatPlayedEarlySaysWhereTheClipEnded() {
        let clock = Clock(), wire = Wire()
        let hub = hub(clock, wire)
        hub.handle(.call(true, down: 24000, clips: true))
        for n in 1...10 { hub.audioIn(numbered(UInt32(n), UInt8(n))) }
        hub.listensAfter(clip: 5, frames: 4)
        hub.handle(.clip(ClipStatus(id: 5, have: 4, played: false)))            // whole at mic frame 10 — three frames of it had played
        hub.handle(.clip(ClipStatus(id: 5, have: 4, played: true, mic: 11)))   // over at 11, not at 14
        for n in 11...15 { hub.audioIn(numbered(UInt32(n), UInt8(n))) }
        hub.setAudioSink { wire.hear($0) }
        XCTAssertEqual(wire.heard.map { $0.first }, [12, 13, 14, 15])          // his answer from its first frame
    }

    // v9, the phone's side (ClipPlayback in ios/ParleyMobile/Funkloch.swift): a clip starts while
    // it still arrives, and a dead zone in its middle makes it wait for the rest — no stutter.
    func testAClipStartsWhileItArrivesAndWaitsForTheRestOnceItRanDry() {
        func frame(_ n: Int) -> Data { Data([UInt8(n)]) }
        var clip = ClipBuffer(), play = ClipPlayback()
        clip.start(id: 1, from: 0)
        for n in 0..<24 { _ = clip.add(frame(n)) }
        XCTAssertTrue(play.feed(clip, early: true, seconds: 0.05, played: 100).isEmpty)        // not half a second of it yet
        _ = clip.add(frame(24))
        XCTAssertTrue(play.feed(clip, early: false, seconds: 0.05, played: 100).isEmpty)       // a v8 host: only the whole clip
        XCTAssertTrue(play.feed(clip, early: true, seconds: 0.4, played: 100).isEmpty)         // 0.5 s in 0.4 s: too slow a line
        XCTAssertEqual(play.feed(clip, early: true, seconds: 0.05, played: 100).count, 25)     // it speaks
        _ = clip.add(frame(25))
        XCTAssertEqual(Array(play.feed(clip, early: true, seconds: 9, played: 103)), [frame(25)])   // and goes on
        XCTAssertFalse(play.playedOut(clip, played: 120))                                      // 20 of 26 came out
        XCTAssertFalse(play.playedOut(clip, played: 126))                                      // all 26 — but that is not the clip
        XCTAssertTrue(play.ranDry)
        _ = clip.add(frame(26))
        XCTAssertTrue(play.feed(clip, early: true, seconds: 9, played: 126).isEmpty)           // it waits for the rest
        _ = clip.add(frame(27))
        XCTAssertNotNil(clip.end(id: 1, frames: 28, listen: true))
        XCTAssertEqual(Array(play.feed(clip, early: true, seconds: 9, played: 126)), [frame(26), frame(27)])
        XCTAssertFalse(play.playedOut(clip, played: 127))
        XCTAssertTrue(play.playedOut(clip, played: 128))                                       // its last frame played

        var again = ClipPlayback()                                                             // the whole clip at once (v8, or a fast line)
        XCTAssertEqual(again.feed(clip, early: false, seconds: 0, played: 10).count, 28)
        again.restart(played: 15)                                                              // a route change after five frames
        XCTAssertEqual(again.feed(clip, early: false, seconds: 0, played: 15).first, frame(5))
        again.cutShort()                                                                       // Sir talks over it
        again.restart(played: 15)
        XCTAssertTrue(again.feed(clip, early: false, seconds: 0, played: 15).isEmpty)
    }

    func testACountThatStartsOverIsANewCall() {
        let clock = Clock(), wire = Wire()
        let hub = hub(clock, wire)
        hub.handle(.call(true, down: 24000, clips: true))
        hub.setAudioSink { wire.hear($0) }
        for n in 1...300 { hub.audioIn(numbered(UInt32(n))) }
        hub.handle(.call(true, down: 24000, clips: true))             // a new call — its predecessor's end got lost
        hub.audioIn(numbered(1, 7))                                   // counted from 1 again: not "sent twice"
        hub.audioIn(numbered(2, 7))
        XCTAssertEqual(wire.heard.count, 302)
        XCTAssertEqual(hub.micHeard, 2)
        hub.audioIn(numbered(250, 9))                                 // (a straggler of the old numbering is taken too: harmless)
        hub.checkAlive()
        XCTAssertEqual(wire.texts.last, RelayFrame.micGot(250))
    }

    func testAnOlderPhonesPlainFramesStillPass() {
        let clock = Clock(), wire = Wire()
        let hub = hub(clock, wire)
        hub.handle(.call(true))
        XCTAssertFalse(hub.clips)
        hub.setAudioSink { wire.hear($0) }
        hub.audioIn(Data(repeating: 3, count: 640))
        XCTAssertEqual(wire.heard, [Data(repeating: 3, count: 640)])
        hub.checkAlive()
        XCTAssertFalse(wire.texts.contains { $0.contains(#""t":"mic""#) })
    }

    func testTheCallWaitsOutADeadZone() {
        let clock = Clock(), wire = Wire()
        let hub = hub(clock, wire)
        hub.handle(.call(true, down: 24000, clips: true))
        hub.audioIn(numbered(1))
        clock.t += 2
        XCTAssertFalse(hub.stalled)
        clock.t += 8                                                  // ten seconds of nothing: an older call would be over
        hub.checkAlive()
        XCTAssertTrue(hub.callActive)
        XCTAssertTrue(hub.stalled)
        XCTAssertTrue(wire.logs.contains { $0.contains("dead zone") })
        clock.t += 100
        hub.audioIn(numbered(2))                                      // the phone is back with what it kept
        XCTAssertFalse(hub.stalled)
        XCTAssertTrue(wire.logs.contains { $0.contains("is back after") })
        clock.t += PhoneHub.funkloch + 1
        hub.checkAlive()
        XCTAssertFalse(hub.callActive)                                // three minutes of nothing: over

        let old = self.hub(clock, wire)
        old.handle(.call(true))
        old.audioIn(Data(count: 640))
        clock.t += PhoneHub.silentCall + 1
        old.checkAlive()
        XCTAssertFalse(old.callActive)                                // an older phone: as before
    }

    func testAPhoneThatIsInNoCallEndsOurs() {
        let clock = Clock(), wire = Wire()
        let hub = hub(clock, wire)
        hub.handle(.callIdle)                                         // no call here either: nothing
        XCTAssertFalse(hub.takeDeclined())
        hub.handle(.call(true, down: 24000, clips: true))
        hub.handle(.callIdle)                                         // its hang-up got lost in a dead zone
        XCTAssertFalse(hub.callActive)
        XCTAssertFalse(hub.takeDeclined())
    }

    // MARK: - listening through a dead zone

    func testAListeningsClocksStandStillWhileThePhoneIsGone() async throws {
        final class Link: CallLink, @unchecked Sendable {
            let lock = NSLock()
            var sink: (@Sendable (Data) -> Void)?
            var gone = false
            var callGeneration: Int { 1 }
            func isLive(_ generation: Int) -> Bool { true }
            func sendAudio(_ frame: Data) {}
            func setAudioState(_ state: PhoneAudioState) {}
            func setAudioSink(_ s: (@Sendable (Data) -> Void)?) { lock.withLock { sink = s } }
            var clips: Bool { true }
            var stalled: Bool { lock.withLock { gone } }
        }
        let clock = Clock()
        let link = Link()
        let listener = PhoneListener(link: link, now: { clock.t })
        let task = Task { await listener.record() }
        while link.lock.withLock({ link.sink }) == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        link.lock.withLock { link.gone = true }                       // into the forest before a word arrived
        try await Task.sleep(nanoseconds: 250_000_000)
        clock.t += 60                                                 // a minute: no "no speech", no end
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNotNil(link.lock.withLock { link.sink })
        link.lock.withLock { link.gone = false }
        let voice = PCMFrames.frames(PCMFrames.int16(sine(300, rate: 16000, seconds: 1.5, amp: 0.3))).frames
        let quiet = PCMFrames.frames([Int16](repeating: 0, count: 16000 * 3)).frames
        for f in voice + quiet { listener.feed(f) }                   // what the phone kept, in one burst
        let outcome = await task.value
        guard case .finished(let wav) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertGreaterThan(wav.count, 44 + 16000 * 2)               // his words are in it
    }
}
