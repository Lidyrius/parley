import Foundation
@preconcurrency import AVFoundation

// Parley's voice and ears over a phone call (docs/IPHONE.md, protocol v2). Audio crosses the
// relay as raw PCM 16-bit LE mono 16 kHz, one binary frame per 20 ms (640 bytes), no header.
// Out: the 24 kHz TTS PCM is time-stretched to the speaking rate, resampled to 16 kHz, cut into
// frames and paced in real time. In: the phone's mic frames feed the same VAD/recording core
// as the Mac's mic (UtteranceRecorder).

enum PhoneAudioFormat {
    static let sampleRate = 16000
    static let frameSamples = 320          // 20 ms
    static let frameBytes = 640
    static let frameSeconds = 0.02
    static let ttsRate = Int(ElevenLabs.sampleRate)   // 24 kHz: Google + ElevenLabs PCM, cached clips
    // A phone that asks for it (`call start` with `"down":24000`) gets the voice at the TTS's own
    // 24 kHz — no resampling, the full band; older phones get 16 kHz. The mic stays 16 kHz.
    static let hiFiRate = ttsRate
}

// What the host is doing with the call audio — the `audio` frame (the phone listens for the
// wake word only while `idle`).
enum PhoneAudioState: String, Sendable { case speaking, listening, idle }

// The call as the audio code needs it; PhoneHub in the app, a fake in tests.
protocol CallLink: AnyObject, Sendable {
    var callGeneration: Int { get }                 // changes whenever a call starts or ends
    func isLive(_ generation: Int) -> Bool          // the call `generation` names is still connected
    func sendAudio(_ frame: Data)                   // one 640-byte frame to the phone
    func setAudioState(_ state: PhoneAudioState)
    func setAudioSink(_ sink: (@Sendable (Data) -> Void)?)   // where the phone's mic frames go
    var downRate: Int { get }                       // Parley's voice to the phone: 16 or 24 kHz
    var barged: Bool { get }                        // Sir talked over Parley: stop the line now
    // v8 (docs/IPHONE.md → "Funkloch"): the phone takes a whole line before it plays it
    // (PhoneClip), and the call waits out a dead zone instead of ending.
    var clips: Bool { get }
    var stalled: Bool { get }                       // nothing from the phone right now: the clocks wait
    func sendControl(_ text: String)                // a text frame of the call (a clip's header / end)
    func setClipSink(_ sink: (@Sendable (ClipStatus) -> Void)?)   // what the phone says about its clips
    /// Parley listens after clip `id` (`frames` long). The link then sorts the phone's mic by
    /// itself, the moment the phone says "played": what it recorded while the clip still played
    /// is dropped, what came after is kept until the listener is there — after a dead zone all
    /// of it arrives in one burst, before anyone could start to listen.
    func listensAfter(clip id: Int, frames: Int)
}

extension CallLink {
    var downRate: Int { PhoneAudioFormat.sampleRate }
    var barged: Bool { false }
    var clips: Bool { false }
    var stalled: Bool { false }
    func sendControl(_ text: String) {}
    func setClipSink(_ sink: (@Sendable (ClipStatus) -> Void)?) {}
    func listensAfter(clip id: Int, frames: Int) {}
}

// MARK: - pure helpers

enum PCMFrames {
    /// Little-endian bytes of `samples`.
    static func bytes<C: Collection>(_ samples: C) -> Data where C.Element == Int16 {
        var d = Data(capacity: samples.count * 2)
        for s in samples {
            let u = UInt16(bitPattern: s)
            d.append(UInt8(u & 0xff))
            d.append(UInt8(u >> 8))
        }
        return d
    }

    /// Samples of little-endian PCM16 bytes (a trailing odd byte is ignored).
    static func samples(_ data: Data) -> [Int16] {
        let n = data.count / 2
        var out = [Int16](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<n { out[i] = Int16(bitPattern: UInt16(p[2 * i]) | UInt16(p[2 * i + 1]) << 8) }
        }
        return out
    }

    /// Whole 20 ms frames of `samples`, plus the rest (< 320 samples) for the next call.
    static func frames(_ samples: [Int16], size: Int = PhoneAudioFormat.frameSamples) -> (frames: [Data], rest: [Int16]) {
        let whole = samples.count / size
        let frames = (0..<whole).map { bytes(samples[($0 * size)..<(($0 + 1) * size)]) }
        return (frames, Array(samples[(whole * size)...]))
    }

    static func int16(_ floats: [Float]) -> [Int16] {
        floats.map { Int16((max(-1, min(1, $0)) * 32767).rounded()) }
    }

    static func floats(_ samples: [Int16]) -> [Float] { samples.map { Float($0) / 32768 } }
}

// Streaming rational resampler (polyphase windowed sinc, Blackman window). 24 kHz → 16 kHz is
// up 2 / down 3 with a 7.2 kHz low-pass, so nothing above the new Nyquist folds back into the
// voice. Chunked input gives the same output as one block; flush() drains the tail.
struct Resampler {
    let inRate: Int, outRate: Int
    private let up: Int, down: Int
    private let half: Int              // input samples on each side of the kernel centre
    private let h: [Float]             // kernel at the upsampled rate, 2 * half * up + 1 taps
    private var x: [Float] = []        // input from absolute index `base` on
    private var base = 0
    private var received = 0           // input samples so far
    private var k = 0                  // next output index

    init(from inRate: Int, to outRate: Int, half: Int = 16) {
        self.inRate = inRate
        self.outRate = outRate
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = gcd(inRate, outRate)
        let up = outRate / g
        self.up = up
        down = inRate / g
        self.half = half
        let n = 2 * half * up + 1
        let c = Double(n - 1) / 2
        let cutoff = 0.45 * Double(min(inRate, outRate)) / Double(inRate * up)   // cycles per upsampled sample
        h = (0..<n).map { i in
            let t = Double(i) - c
            let sinc = t == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * t) / (.pi * t)
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1)) + 0.08 * cos(4 * .pi * Double(i) / Double(n - 1))
            return Float(sinc * w * Double(up))   // ×up: zero-stuffing gain
        }
    }

    var isIdentity: Bool { up == down }

    mutating func process(_ input: [Float]) -> [Float] {
        if isIdentity { return input }
        x.append(contentsOf: input)
        received += input.count
        return run(flushing: false)
    }

    /// The tail: input beyond the end counts as silence.
    mutating func flush() -> [Float] {
        if isIdentity { return [] }
        return run(flushing: true)
    }

    private mutating func run(flushing: Bool) -> [Float] {
        var out: [Float] = []
        let c = half * up
        while true {
            let p = k * down                       // output k's position at the upsampled rate
            if flushing ? p >= received * up : p / up + half > received - 1 { break }
            let lo = Int((Double(p - c) / Double(up)).rounded(.up))
            let hi = p / up + half
            var acc: Float = 0
            var i = max(lo, base)
            while i <= hi, i - base < x.count {
                acc += h[p + c - i * up] * x[i - base]
                i += 1
            }
            out.append(acc)
            k += 1
        }
        // Input no later output needs any more.
        let keepFrom = (k * down) / up - half - 1
        if keepFrom > base {
            let drop = min(keepFrom - base, x.count)
            x.removeFirst(drop)
            base += drop
        }
        return out
    }
}

// When the frames of an utterance go out: real time plus `lead` of prebuffer at the phone.
// When the queue ran dry long enough for the phone to play everything sent (an underrun, e.g.
// streaming TTS slower than real time) the clock re-anchors, so a late chunk is not burst out.
struct FramePacer {
    static let frame = PhoneAudioFormat.frameSeconds
    let lead: TimeInterval
    private(set) var anchor: Date?
    private(set) var sinceAnchor = 0
    private(set) var total = 0

    init(lead: TimeInterval = 0.1) { self.lead = lead }

    var leadFrames: Int { Int((lead / Self.frame).rounded()) }

    /// How many of `available` queued frames to send now.
    mutating func due(available: Int, now: Date) -> Int {
        guard available > 0 else { return 0 }
        if let a = anchor, now > a.addingTimeInterval(Double(sinceAnchor) * Self.frame) { anchor = nil }
        if anchor == nil { anchor = now; sinceAnchor = 0 }
        let elapsed = now.timeIntervalSince(anchor!)
        let allowed = Int(((elapsed + lead) / Self.frame + 1e-6).rounded(.down)) + 1 - sinceAnchor
        let n = min(available, max(0, allowed))
        sinceAnchor += n
        total += n
        return n
    }

    /// When the phone has played everything sent so far (nil before the first frame).
    var playedOut: Date? { anchor.map { $0.addingTimeInterval(Double(sinceAnchor) * Self.frame) } }
}

// The speaking rate for the phone: AVAudioUnitTimePitch rendered offline (pitch kept, like the
// Mac's player). Streaming: each chunk renders input/rate frames; flush() renders the latency tail.
final class TimeStretch {
    let rate: Double
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private let format: AVAudioFormat
    private var owed = 0.0          // output frames due but not yet rendered (fractions carry)
    private static let block: AVAudioFrameCount = 4096

    init?(rate: Double, sampleRate: Double = Double(PhoneAudioFormat.ttsRate)) {
        self.rate = min(2.0, max(0.5, rate))
        guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        else { return nil }
        format = f
        pitch.rate = Float(self.rate)
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: f)
        engine.connect(pitch, to: engine.mainMixerNode, format: f)
        do {
            try engine.enableManualRenderingMode(.offline, format: f, maximumFrameCount: Self.block)
            try engine.start()
        } catch { return nil }
        player.play()
    }

    deinit { engine.stop() }

    func process(_ input: [Float]) -> [Float] {
        guard !input.isEmpty, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.count))
        else { return [] }
        buf.frameLength = AVAudioFrameCount(input.count)
        input.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: input.count) }
        player.scheduleBuffer(buf, completionHandler: nil)
        owed += Double(input.count) / rate
        let n = Int(owed)
        owed -= Double(n)
        return render(n)
    }

    /// The tail the unit still holds (its latency, ~0.1 s).
    func flush() -> [Float] { render(Int(0.12 * format.sampleRate)) }

    private func render(_ frames: Int) -> [Float] {
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: Self.block)
        else { return [] }
        var out: [Float] = []
        out.reserveCapacity(frames)
        var left = frames
        while left > 0 {
            let n = AVAudioFrameCount(min(left, Int(Self.block)))
            guard (try? engine.renderOffline(n, to: buf)) == .success, let ch = buf.floatChannelData else { break }
            out.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
            left -= Int(buf.frameLength)
            if buf.frameLength == 0 { break }
        }
        return out
    }
}

// MARK: - out: Parley's voice down the call

// One stretch of Parley's voice over a connected call: enqueue 24 kHz PCM (streamed or whole),
// then finish() — it appends the beep (or the silent finish marker), waits until the phone has
// played everything, and returns nil. When the call ends first it returns the speech the phone
// did not play yet (24 kHz), for the Mac's speaker; the beep is not part of it.
// ponytail: @unchecked Sendable — all state lives on `queue`.
final class PhoneVoice: PhoneSpeech, @unchecked Sendable {
    private let link: any CallLink
    private let generation: Int
    private let rate: Double
    private let queue: DispatchQueue
    private let now: @Sendable () -> Date
    private let stretch: TimeStretch?
    private let outRate: Int            // the call's down rate: 16 kHz, or 24 kHz as is
    private var resampler: Resampler?   // nil at 24 kHz
    private var frameSize: Int { outRate / 50 }
    private var carry = Data()          // odd byte between chunks
    private var speech = Data()         // all 24 kHz speech enqueued (the fallback plays its rest)
    private var pending: [Int16] = []   // samples (at outRate) short of a whole frame
    private var frames: [Data] = []
    private var head = 0                // next frame to send
    private var pacer = FramePacer(lead: 0.25)   // a quarter second ahead: mobile networks jitter
    private var timer: DispatchSourceTimer?
    private var closed = false
    private var interrupted = false
    private var cutShort = false        // barge-in: the rest of the line is dropped, not replayed
    private var restOffset = 0
    private var waiter: CheckedContinuation<Data?, Never>?
    static let margin: TimeInterval = 0.2    // network slack before "played"

    init(link: any CallLink, rate: Double, now: @escaping @Sendable () -> Date = { Date() },
         queue: DispatchQueue = DispatchQueue(label: "de.developaway.parley.phone-voice", qos: .userInteractive)) {
        self.link = link
        self.generation = link.callGeneration
        self.rate = min(2.0, max(0.5, rate))
        self.now = now
        self.queue = queue
        self.stretch = abs(self.rate - 1) < 0.01 ? nil : TimeStretch(rate: self.rate)
        outRate = link.downRate
        resampler = outRate == PhoneAudioFormat.ttsRate ? nil : Resampler(from: PhoneAudioFormat.ttsRate, to: outRate)
        link.setAudioState(.speaking)
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: 0.01, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    deinit { timer?.cancel() }

    /// 24 kHz PCM16 LE mono, any chunk size.
    func enqueue(_ pcm: Data) {
        queue.async {
            self.speech.append(pcm)
            guard !self.interrupted, !self.cutShort else { return }
            self.carry.append(pcm)
            let even = self.carry.count & ~1
            guard even > 0 else { return }
            let samples = PCMFrames.samples(self.carry.prefix(even))
            self.carry.removeFirst(even)
            self.push(PCMFrames.floats(samples), stretched: false)
        }
    }

    /// Plays out what is queued plus the beep (`beep`) or a 20 ms silent marker. nil = all
    /// played; else the speech the phone never played (the call ended).
    func finish(beep: Bool) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            queue.async {
                if !self.interrupted {
                    if self.cutShort { self.closed = true; self.waiter = cont; self.tick(); return }
            let tone = beep ? Tones.beep(sampleRate: Double(PhoneAudioFormat.ttsRate))
                                    : [Float](repeating: 0, count: PhoneAudioFormat.ttsRate / 50)
                    self.push(tone, stretched: false)
                    var tail = self.stretch?.flush() ?? []
                    if self.resampler != nil { tail = self.resampler!.process(tail) + self.resampler!.flush() }
                    self.pending += PCMFrames.int16(tail)
                    let size = self.frameSize
                    self.pending += [Int16](repeating: 0, count: (size - self.pending.count % size) % size)   // last frame whole
                    self.cut()
                }
                self.closed = true
                self.waiter = cont
                self.tick()
            }
        }
    }

    // MARK: on `queue`

    private func push(_ floats: [Float], stretched: Bool) {
        let timed = stretch.map { $0.process(floats) } ?? floats
        pending += PCMFrames.int16(resampler != nil ? resampler!.process(timed) : timed)
        cut()
    }

    private func cut() {
        let (f, rest) = PCMFrames.frames(pending, size: frameSize)
        frames += f
        pending = rest
    }

    private func tick() {
        if !interrupted, !link.isLive(generation) { interrupt() }
        if !interrupted, !cutShort, link.barged {
            // Sir talks over Parley: stop sending at once; nothing of it plays on the Mac.
            cutShort = true
            frames.removeAll()
            head = 0
        }
        if !interrupted, !cutShort {
            let n = pacer.due(available: frames.count - head, now: now())
            for _ in 0..<n {
                link.sendAudio(frames[head])
                head += 1
            }
            if head > 256 { frames.removeFirst(head); head = 0 }
        }
        guard closed, let waiter else { return }
        if cutShort {
            resume(waiter, nil)
        } else if interrupted {
            let from = min(restOffset, speech.count) & ~1
            resume(waiter, speech.subdata(in: from..<speech.count))
        } else if head >= frames.count, now() >= (pacer.playedOut ?? .distantPast).addingTimeInterval(Self.margin) {
            resume(waiter, nil)
        }
    }

    private func resume(_ cont: CheckedContinuation<Data?, Never>, _ value: Data?) {
        waiter = nil
        timer?.cancel()
        timer = nil
        cont.resume(returning: value)
    }

    // The call ended: stop sending; the speech not yet heard starts at what was sent minus the
    // frames still in the phone's prebuffer, mapped back to the 24 kHz input (rate, out rate).
    private func interrupt() {
        interrupted = true
        let heardOut = max(0, pacer.total - pacer.leadFrames) * frameSize
        let heard24k = Double(heardOut) * Double(PhoneAudioFormat.ttsRate) / Double(outRate) * rate
        restOffset = Int(heard24k) * 2
        frames.removeAll()
        head = 0
    }
}

// MARK: - out, v8: the whole line first

/// Parley's voice down a call, either way: streamed in real time (PhoneVoice), or as a clip the
/// phone plays once it holds all of it (PhoneClip).
protocol PhoneSpeech: Sendable {
    func enqueue(_ pcm: Data)                 // 24 kHz PCM16 LE mono, any chunk size
    func finish(beep: Bool) async -> Data?    // nil = played; else the speech the phone never played
}

/// What the phone says about a clip: how many of its frames it holds, and whether it played it.
/// `id` 0: it knows of none. `mic` (v9, with `played`): its mic's number when the last frame played.
struct ClipStatus: Equatable, Sendable {
    var id: Int
    var have: Int
    var played: Bool
    var mic: UInt32? = nil
}

/// 24 kHz PCM in, the call's 20 ms frames out: the speaking rate, the call's own rate, whole frames.
/// ponytail: the same steps as PhoneVoice's push / cut / finish — fold them together when either changes.
final class LineRenderer {
    private let stretch: TimeStretch?
    private var resampler: Resampler?
    private let frameSize: Int
    private var carry = Data()          // odd byte between chunks
    private var pending: [Int16] = []   // samples short of a whole frame

    init(rate: Double, outRate: Int) {
        let r = min(2.0, max(0.5, rate))
        stretch = abs(r - 1) < 0.01 ? nil : TimeStretch(rate: r)
        resampler = outRate == PhoneAudioFormat.ttsRate ? nil : Resampler(from: PhoneAudioFormat.ttsRate, to: outRate)
        frameSize = outRate / 50
    }

    func add(_ pcm: Data) -> [Data] {
        carry.append(pcm)
        let even = carry.count & ~1
        guard even > 0 else { return [] }
        let samples = PCMFrames.samples(carry.prefix(even))
        carry.removeFirst(even)
        return push(PCMFrames.floats(samples))
    }

    /// The line's end: the beep (or a 20 ms silent marker), the stretcher's tail, the last frame whole.
    func end(beep: Bool) -> [Data] {
        let tone = beep ? Tones.beep(sampleRate: Double(PhoneAudioFormat.ttsRate))
                        : [Float](repeating: 0, count: PhoneAudioFormat.ttsRate / 50)
        var out = push(tone)
        var tail = stretch?.flush() ?? []
        if resampler != nil { tail = resampler!.process(tail) + resampler!.flush() }
        pending += PCMFrames.int16(tail)
        pending += [Int16](repeating: 0, count: (frameSize - pending.count % frameSize) % frameSize)
        out += cut()
        return out
    }

    private func push(_ floats: [Float]) -> [Data] {
        let timed = stretch.map { $0.process(floats) } ?? floats
        pending += PCMFrames.int16(resampler != nil ? resampler!.process(timed) : timed)
        return cut()
    }

    private func cut() -> [Data] {
        let (f, rest) = PCMFrames.frames(pending, size: frameSize)
        pending = rest
        return f
    }
}

// One stretch of Parley's voice for a phone that takes clips (v8): every frame of the line goes
// out as fast as the line carries it, and the phone plays it only once it holds all of it — a
// dead zone in the middle of a line no longer cuts it. After a break the phone says how far it
// got and the rest follows from there. finish() returns nil once the phone played the clip (or
// Sir talked over it); when the call ends first, the speech for the Mac's speaker — unless the
// phone already held all of it (then it played, with or without a line to say so).
// ponytail: @unchecked Sendable — all state lives on `queue`.
final class PhoneClip: PhoneSpeech, @unchecked Sendable {
    private static let counter = NSLock()
    nonisolated(unsafe) private static var last = 0
    static func nextID() -> Int { counter.withLock { last += 1; return last } }

    let id: Int
    private let link: any CallLink
    private let generation: Int
    private let queue: DispatchQueue
    private let renderer: LineRenderer
    private var speech = Data()         // all 24 kHz speech enqueued (the fallback plays it)
    private var frames: [Data] = []
    private var total: Int?             // every frame is there (finish)
    private var listen = false
    private var sent = 0                // next frame to hand to the link
    private var opened = false          // this run's header went out
    private var closed = false          // … and its end
    private var have = 0                // what the phone holds, as it last said
    private var timer: DispatchSourceTimer?
    private var waiter: CheckedContinuation<Data?, Never>?
    private var done = false
    private var waited = 0.0            // seconds since finish with the phone on the line
    private var lastTick = Date()
    private let now: @Sendable () -> Date
    /// The phone is on the line and never says "played": this long after the clip's own length
    /// the turn goes on (a phone that lost its way must not hold it for good).
    static let patience: TimeInterval = 20

    init(link: any CallLink, rate: Double, id: Int = PhoneClip.nextID(), now: @escaping @Sendable () -> Date = { Date() },
         queue: DispatchQueue = DispatchQueue(label: "de.developaway.parley.phone-clip", qos: .userInteractive)) {
        self.id = id
        self.now = now
        self.link = link
        self.generation = link.callGeneration
        self.queue = queue
        renderer = LineRenderer(rate: rate, outRate: link.downRate)
        link.setAudioState(.speaking)
        link.setClipSink { [weak self] status in self?.queue.async { self?.heard(status) } }
    }

    func enqueue(_ pcm: Data) {
        queue.async {
            self.speech.append(pcm)
            self.frames += self.renderer.add(pcm)
            self.send()   // a streamed synthesis is on its way while it still renders
        }
    }

    func finish(beep: Bool) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            queue.async {
                self.frames += self.renderer.end(beep: beep)
                self.total = self.frames.count
                self.listen = beep
                self.waiter = cont
                self.lastTick = self.now()
                if beep { self.link.listensAfter(clip: self.id, frames: self.frames.count) }
                self.send()
                let t = DispatchSource.makeTimerSource(queue: self.queue)
                t.schedule(deadline: .now(), repeating: 0.05)
                t.setEventHandler { [weak self] in self?.tick() }
                t.resume()
                self.timer = t
            }
        }
    }

    // MARK: on `queue`

    private func send() {
        guard !done, link.isLive(generation) else { return }
        if !opened, sent < frames.count || total != nil {
            link.sendControl(RelayFrame.clip(id: id, from: sent))
            opened = true
        }
        while sent < frames.count {
            link.sendAudio(frames[sent])
            sent += 1
        }
        if let total, !closed {
            link.sendControl(RelayFrame.clipEnd(id: id, frames: total, listen: listen))
            closed = true
        }
    }

    // The phone's word: played → done; fewer frames than there are (a break in the line), or
    // another clip (it never heard of this one) → again from where it stands.
    private func heard(_ s: ClipStatus) {
        guard !done else { return }
        if s.id == id {
            have = s.have
            if s.played { return resolve(nil) }
            guard let total, s.have < total else { return }
        } else {
            have = 0
        }
        Log.write("phone: clip \(id) — the phone holds \(have) of \(total.map(String.init) ?? "?") frames, sending the rest")
        sent = min(have, frames.count)
        opened = false
        closed = false
        send()
    }

    private func tick() {
        guard let total, !done else { return }
        if !link.isLive(generation) { return resolve(have >= total ? nil : speech) }
        if link.barged { return resolve(nil) }   // Sir talks over Parley: the phone went quiet itself
        let t = now()
        if !link.stalled { waited += t.timeIntervalSince(lastTick) }   // a dead zone doesn't count
        lastTick = t
        if waited > Double(total) * PhoneAudioFormat.frameSeconds + Self.patience {
            Log.write("phone: clip \(id) — no word from the phone that it played; going on")
            resolve(nil)
        }
    }

    private func resolve(_ rest: Data?) {
        guard !done, let w = waiter else { return }
        done = true
        waiter = nil
        timer?.cancel()
        timer = nil
        link.setClipSink(nil)
        w.resume(returning: rest)
    }
}

// MARK: - in: the phone's mic

// One reply over a connected call: the phone's 16 kHz frames run through UtteranceRecorder
// (the Mac mic's VAD, beep grace and no-speech timeout). A wall-clock watchdog covers frames
// that stop arriving; the call ending yields what was captured and whether speech was heard.
// ponytail: @unchecked Sendable — all state lives on `queue`.
final class PhoneListener: @unchecked Sendable {
    enum Outcome: Equatable {
        case finished(Data)                    // WAV (empty samples on no-speech)
        case callEnded(Data, spoke: Bool)      // the call ended while listening
    }

    static let maxSeconds = UtteranceRecorder.maxSeconds

    private let link: any CallLink
    private let generation: Int
    private let queue: DispatchQueue
    private let now: @Sendable () -> Date
    private var recorder = UtteranceRecorder()
    private var started = Date()
    private var lastCheck = Date()
    private var timer: DispatchSourceTimer?
    private var waiter: CheckedContinuation<Outcome, Never>?
    private var onLevel: (@Sendable (Float) -> Void)?

    init(link: any CallLink, now: @escaping @Sendable () -> Date = { Date() },
         queue: DispatchQueue = DispatchQueue(label: "de.developaway.parley.phone-listen", qos: .userInteractive)) {
        self.link = link
        self.generation = link.callGeneration
        self.now = now
        self.queue = queue
    }

    /// `preroll`: mic frames from just before (barge-in: Sir already started talking).
    func record(preroll: [Data] = [], onLevel: (@Sendable (Float) -> Void)? = nil) async -> Outcome {
        await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
            queue.async {
                self.waiter = cont
                self.onLevel = onLevel
                self.recorder.reset()
                for frame in preroll { _ = self.recorder.feed(PCMFrames.samples(frame)) }
                self.started = self.now()
                self.lastCheck = self.started
                guard self.link.isLive(self.generation) else { self.end(.callEnded(Data(), spoke: false)); return }
                self.link.setAudioState(.listening)
                self.link.setAudioSink { [weak self] frame in self?.feed(frame) }
                let t = DispatchSource.makeTimerSource(queue: self.queue)
                t.schedule(deadline: .now() + 0.1, repeating: 0.1)
                t.setEventHandler { [weak self] in self?.check() }
                t.resume()
                self.timer = t
            }
        }
    }

    /// One frame from the phone (any thread).
    func feed(_ frame: Data) {
        queue.async {
            guard self.waiter != nil else { return }
            let (db, step) = self.recorder.feed(PCMFrames.samples(frame))
            let level = max(0, min(1, (db + 55) / 45))
            LiveStatus.push(level)
            self.onLevel?(level)
            if case .ended(let reason) = step { self.end(.finished(self.recorder.wav(endReason: reason))) }
        }
    }

    // Internal for tests: the watchdog tick.
    func check() {
        guard waiter != nil else { return }
        if !link.isLive(generation) {
            let spoke = recorder.heardSpeech
            end(.callEnded(recorder.wav(endReason: spoke ? "call-ended" : "no-speech"), spoke: spoke))
            return
        }
        // v8: nothing comes from the phone (a dead zone) — its mic is kept there and follows once
        // the line is back; until then the clocks stand still.
        let t = now()
        if link.stalled { started = started.addingTimeInterval(t.timeIntervalSince(lastCheck)) }
        lastCheck = t
        guard !link.stalled else { return }
        let elapsed = t.timeIntervalSince(started)
        // Frames stopped (or never came): the recorder's own no-speech timeout can't fire.
        if !recorder.heardSpeech, elapsed >= UtteranceRecorder.noSpeechTimeout + 1 {
            end(.finished(recorder.wav(endReason: "no-speech")))
        } else if elapsed >= Self.maxSeconds {
            end(.finished(recorder.wav(endReason: "max-cap")))
        }
    }

    private func end(_ outcome: Outcome) {
        guard let w = waiter else { return }
        waiter = nil
        timer?.cancel()
        timer = nil
        link.setAudioSink(nil)
        Log.write("phone: listen done (\(Self.describe(outcome)), \(String(format: "%.1f", recorder.duration)) s)")
        w.resume(returning: outcome)
    }

    private static func describe(_ o: Outcome) -> String {
        switch o {
        case .finished(let wav): "finished, \(wav.count) bytes"
        case .callEnded(_, let spoke): "call ended, spoke=\(spoke)"
        }
    }
}
