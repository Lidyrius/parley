import XCTest
@testable import Parley

// Both ends of protocol v8 over one line with an outage: the host's own code (PhoneHub,
// PhoneClip) against the phone's own (PhoneSideFunkloch.swift is ios/ParleyMobile/Funkloch.swift,
// linked into this target) — what the two say to each other must fit, without a phone at hand.
final class FunklochLineTests: XCTestCase {
    /// The relay between them: while it is down, whatever is sent is gone.
    private final class Line: @unchecked Sendable {
        private let lock = NSLock()
        private var _up = true
        var up: Bool { get { lock.withLock { _up } } set { lock.withLock { _up = newValue } } }
        var toPhoneText: (@Sendable (String) -> Void)?
        var toPhoneAudio: (@Sendable (Data) -> Void)?
        var toHostText: (@Sendable (String) -> Void)?
        var toHostAudio: (@Sendable (Data) -> Void)?
        var dropAfterFrames: Int?            // the line dies after this many voice frames reached the phone
        private var delivered = 0
        func down(text: String) { if up { toPhoneText?(text) } }
        func down(audio: Data) {
            let pass = lock.withLock { () -> Bool in
                guard _up else { return false }
                delivered += 1
                if let n = dropAfterFrames, delivered > n { _up = false; return false }
                return true
            }
            if pass { toPhoneAudio?(audio) }
        }
        func up(text: String) { if up { toHostText?(text) } }
        func up(audio: Data) { if up { toHostAudio?(audio) } }
    }

    /// The phone's call, as far as the protocol goes (CallController does the same with real audio).
    private final class Phone: @unchecked Sendable {
        let lock = NSRecursiveLock()   // here the two ends answer each other on one thread
        var clip = ClipBuffer()
        var played: [Data] = []
        var playedClip = false
        var holdPlayed = false               // a test plays the clip "by hand" (a real phone takes its length)
        let line: Line
        lazy var mic = MicLedger(send: { [line] in line.up(audio: $0) })
        init(_ line: Line) { self.line = line }

        func text(_ s: String) {
            guard let f = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any], let t = f["t"] as? String else { return }
            lock.lock(); defer { lock.unlock() }
            if t == "mic", let got = f["got"] as? Int { mic.acked(UInt32(got)) }
            guard t == "clip", let id = f["id"] as? Int else { return }
            if let n = f["frames"] as? Int {
                if let all = clip.end(id: id, frames: n, listen: f["listen"] as? Bool ?? false) {
                    played += all                 // it plays, here: at once
                    playedClip = !holdPlayed
                }
                status()
            } else {
                if id != clip.id { playedClip = false }
                clip.start(id: id, from: f["from"] as? Int ?? 0)
            }
        }
        func audio(_ d: Data) { lock.withLock { if !clip.add(d) { played.append(d) } } }
        func status() { line.up(text: #"{"t":"clip","id":\#(clip.id),"have":\#(clip.have),"played":\#(playedClip)}"#) }
        /// Back on the line: say where the clip stands; the host answers with where the mic stands.
        func reconnected() { lock.withLock { mic.hold(); status() } }
    }

    private func world() -> (PhoneHub, Phone, Line) {
        let line = Line()
        let hub = PhoneHub(store: .memory(), log: { _ in })
        let phone = Phone(line)
        hub.attach(text: { line.down(text: $0) }, audio: { line.down(audio: $0) })
        line.toPhoneText = { phone.text($0) }
        line.toPhoneAudio = { phone.audio($0) }
        line.toHostText = { if let e = RelayFrame.parse($0) { hub.handle(e) } }
        line.toHostAudio = { hub.audioIn($0) }
        line.up(text: #"{"t":"call","state":"start","down":24000,"v":8}"#)
        phone.mic.begin(numbered: true)
        return (hub, phone, line)
    }

    private func until(_ what: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<600 where !what() { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(what(), file: file, line: line)
    }

    func testALineSurvivesADeadZoneInItsMiddle() async {
        let (hub, phone, line) = world()
        XCTAssertTrue(hub.clips)
        let speech = PCMFrames.bytes(PCMFrames.int16(sine(440, rate: 24000, seconds: 3)))
        let reference = LineRenderer(rate: 1, outRate: 24000)
        let frames = reference.add(speech) + reference.end(beep: true)     // what the phone must end up playing
        line.dropAfterFrames = 40                                           // into the forest after 0.8 s of the line
        let clip = PhoneClip(link: hub, rate: 1)
        clip.enqueue(speech)
        async let rest = clip.finish(beep: true)
        await until(!line.up)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(phone.lock.withLock { phone.clip.have }, 40)
        XCTAssertTrue(phone.lock.withLock { phone.played.isEmpty })        // nothing plays in pieces

        line.dropAfterFrames = nil
        line.up = true                                                      // out of the forest
        phone.reconnected()
        await until(phone.lock.withLock { phone.playedClip })
        let played = await rest
        XCTAssertNil(played)                                                // the host knows it played
        XCTAssertEqual(phone.lock.withLock { phone.played }, frames)       // every frame, once, in order
    }

    // The line drops while a (fully loaded) clip plays; Sir answers after its beep, still in the
    // forest. Back on the line his answer reaches a listener that starts only then — without the
    // seconds his phone recorded while the clip was still playing.
    func testAnAnswerGivenInADeadZoneAfterTheClipReachesTheListener() async {
        let (hub, phone, line) = world()
        final class Heard: @unchecked Sendable { let lock = NSLock(); var list: [UInt16] = [] }
        let heard = Heard()
        func say(_ range: ClosedRange<UInt16>) {
            for n in range { phone.mic.push(Data([UInt8(n & 0xff), UInt8(n >> 8)]) + Data(count: 638)) }
        }
        say(1...50)                                                         // the call runs for a second
        hub.checkAlive()
        // (This phone "plays" in an instant; a real one takes the clip's length — here: by hand.)
        let clip = PhoneClip(link: hub, rate: 1)
        clip.enqueue(PCMFrames.bytes(PCMFrames.int16(sine(440, rate: 24000, seconds: 1))))
        phone.lock.withLock { phone.holdPlayed = true }
        async let rest = clip.finish(beep: true)                            // 59 frames: 1 s + the beep
        await until(phone.lock.withLock { phone.clip.released })
        try? await Task.sleep(nanoseconds: 100_000_000)
        line.up = false                                                     // into the forest as it begins to play
        say(51...109)                                                       // the phone's mic while the clip plays (59 frames)
        say(110...300)                                                      // … and then Sir's answer
        line.up = true
        phone.lock.withLock { phone.holdPlayed = false; phone.playedClip = true }
        phone.reconnected()                                                 // "played", and the mic follows
        let played = await rest
        XCTAssertNil(played)
        hub.setAudioSink { d in heard.lock.withLock { heard.list.append(UInt16(d[d.startIndex]) | UInt16(d[d.startIndex + 1]) << 8) } }
        let got = heard.lock.withLock { heard.list }
        XCTAssertEqual(got.last, 300)
        XCTAssertEqual(got.first, 110)                                      // from the first frame after the clip
        XCTAssertEqual(got, Array(110...300))
    }

    func testWhatSirSaysInADeadZoneArrivesAfterwardsOnceAndInOrder() async {
        let (hub, phone, line) = world()
        final class Heard: @unchecked Sendable { let lock = NSLock(); var list: [UInt16] = [] }
        let heard = Heard()
        hub.setAudioSink { d in heard.lock.withLock { heard.list.append(UInt16(d[d.startIndex]) | UInt16(d[d.startIndex + 1]) << 8) } }
        func say(_ range: ClosedRange<UInt16>) {
            for n in range { phone.mic.push(Data([UInt8(n & 0xff), UInt8(n >> 8)]) + Data(count: 638)) }   // its number in its first sample
        }
        say(1...100)                                                        // on the line: live
        hub.checkAlive()                                                    // the host's word once a second
        XCTAssertEqual(phone.mic.waiting, 0)
        say(101...110)                                                      // (not acknowledged yet)
        line.up = false                                                     // the forest
        say(111...400)                                                      // Sir talks on for six seconds
        XCTAssertEqual(heard.lock.withLock { heard.list.count }, 110)
        line.up = true
        phone.reconnected()
        XCTAssertEqual(heard.lock.withLock { heard.list }, Array(1...400))  // all of it, once, in order
        say(401...410)
        XCTAssertEqual(heard.lock.withLock { heard.list.last }, 410)        // and live again
        hub.checkAlive()
        XCTAssertEqual(phone.mic.waiting, 0)
        XCTAssertTrue(hub.callActive)
    }
}
