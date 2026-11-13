import Foundation

// Protocol v8, "Funkloch" (docs/IPHONE.md): a call that gets through a dead zone.
// Down: a line of Parley's voice arrives as a clip and plays only once all of it is here — the
// network may go in the middle of it. Up: the mic is numbered and kept until the host has it;
// after a break it is sent again from where the host stands.

/// One line of Parley's voice, taken whole before it plays.
struct ClipBuffer: Equatable {
    private(set) var id = 0                  // 0: no clip yet
    private(set) var frames: [Data] = []
    private(set) var total: Int?             // known once its end came
    private(set) var listen = false          // Parley listens after it
    private(set) var released = false        // handed to the player (it plays, or has played)
    private var taking = false               // the binary frames coming now belong to it …
    private var skipping = false             // … but are not wanted (it plays already, or they don't fit)

    var have: Int { frames.count }

    /// `{"t":"clip","id","from"}`: its frames follow, from frame `from` on.
    mutating func start(id: Int, from: Int) {
        if id != self.id {
            self = ClipBuffer()
            self.id = id
        }
        taking = true
        // It plays already (the host sent it again without need), or the frames would leave a
        // hole: not taken — the end's answer tells the host where this phone stands.
        skipping = released || from > frames.count
        if !skipping, from < frames.count { frames.removeSubrange(from...) }
    }

    /// A binary frame from the host. False: it is no clip's (an older host streams) — play it as it comes.
    mutating func add(_ frame: Data) -> Bool {
        guard taking else { return false }
        if !skipping { frames.append(frame) }
        return true
    }

    /// `{"t":"clip","id","frames","play","listen"}`: that was all of it. The frames to play, once,
    /// when every one is here — else nil (the caller says how many it has; the rest follows).
    mutating func end(id: Int, frames count: Int, listen: Bool) -> [Data]? {
        taking = false
        skipping = false
        guard id == self.id else { return nil }
        total = count
        self.listen = listen
        guard !released, frames.count == count else { return nil }
        released = true
        return frames
    }
}

/// How far a clip's playback got. v8: it plays once all of it is here. v9 (the host's `sessions`
/// say `"call":9`): it starts while it still arrives — once `lead` frames are here and they come
/// at least `pace` times as fast as they play — so Parley speaks the moment Sir answers. Should
/// the player run dry before the rest came (a dead zone), it waits for all of it and goes on
/// from memory, as a v8 clip does from its first frame.
struct ClipPlayback: Equatable {
    static let lead = 25                     // frames (0.5 s) in hand before the first one plays
    static let pace = 2.0                    // … arriving at least this much faster than real time
    static let frameSeconds = 0.02

    private(set) var started = false         // frames went to the player
    private(set) var ranDry = false          // … and it ran out before the rest came
    private var cut = false                  // Sir talked over it: nothing more of it plays
    private var base = 0                     // frames played before the player last (re)started
    private var fedAt = 0                    // the player's count of played frames when it was fed from `base`
    private var fed = 0                      // frames handed to it since

    /// A frame of the clip came, or its end: the frames that go to the player now.
    /// `early`: the host speaks v9. `seconds`: since the clip's first word from the host.
    /// `played`: the player's count of frames played.
    mutating func feed(_ clip: ClipBuffer, early: Bool, seconds: Double, played: Int) -> ArraySlice<Data> {
        guard !cut else { return [] }
        if !clip.released {
            guard early, !ranDry else { return [] }
            guard started || clip.have >= Self.lead && Double(clip.have) * Self.frameSeconds >= Self.pace * seconds else { return [] }
        }
        if !started {
            started = true
            fedAt = played
        }
        let rest = clip.frames.dropFirst(base + fed)
        fed += rest.count
        return rest
    }

    /// The player starts anew (a route change dropped what was scheduled): on from the frame it stood at.
    mutating func restart(played: Int) {
        base += max(0, min(fed, played - fedAt))
        fedAt = played
        fed = 0
    }

    /// Everything handed over came out of the speaker. True: that was the whole clip. Else it
    /// ran dry in the middle — from here it waits for the rest.
    mutating func playedOut(_ clip: ClipBuffer, played: Int) -> Bool {
        guard started, played - fedAt >= fed else { return false }
        if clip.released, base + fed >= clip.have { return true }
        ranDry = true
        return false
    }

    mutating func cutShort() { cut = true }
}

/// The call's mic on its way to the host. v7: every frame as it is. v8 (`numbered`): four bytes
/// in front number it; a frame is kept until the host says it has it (`acked`); after a break
/// (`hold`) nothing goes out until the host said where it stands — then everything after that,
/// in order, and on from there. Nothing Sir says in a dead zone is lost (up to three minutes).
/// The mic's thread pushes, the main actor acks: all under one lock, sends included, so the
/// order on the line is the order of the numbers.
final class MicLedger: @unchecked Sendable {
    static let keep = 9000                   // 3 min of 20 ms frames (5.8 MB)
    static let patience = 150                // frames (3 s) without the host's word after a break: go on anyway

    private let lock = NSLock()
    private let send: @Sendable (Data) -> Void
    private var numbered = false
    private var seq: UInt32 = 0              // the last number given (the first frame is 1)
    private var kept: [(seq: UInt32, frame: Data)] = []
    private var holding = false
    private var held = 0                     // frames pushed while holding

    init(send: @escaping @Sendable (Data) -> Void) { self.send = send }

    /// A call begins: `numbered` when the host speaks v8.
    func begin(numbered: Bool) {
        lock.withLock {
            self.numbered = numbered
            seq = 0
            kept.removeAll(keepingCapacity: true)
            holding = false
            held = 0
        }
    }

    var isNumbered: Bool { lock.withLock { numbered } }
    /// The number of the newest frame (0: none yet, or a v7 call).
    var last: UInt32 { lock.withLock { seq } }
    var waiting: Int { lock.withLock { kept.count } }

    /// One 20 ms mic frame (640 bytes), from the mic's thread.
    func push(_ pcm: Data) {
        lock.withLock {
            guard numbered else { send(pcm); return }
            seq &+= 1
            var frame = Data(capacity: pcm.count + 4)
            withUnsafeBytes(of: seq.littleEndian) { frame.append(contentsOf: $0) }
            frame.append(pcm)
            kept.append((seq, frame))
            if kept.count > Self.keep { kept.removeFirst(kept.count - Self.keep) }
            guard holding else { send(frame); return }
            held += 1
            if held >= Self.patience { flush(after: nil) }   // the host stays silent: don't keep the mic back
        }
    }

    /// The line broke (or a new socket opened): keep everything back until the host said where it stands.
    func hold() {
        lock.withLock {
            guard numbered else { return }
            holding = true
            held = 0
        }
    }

    /// `{"t":"mic","got":n}`: the host has everything up to `n`.
    func acked(_ n: UInt32) {
        lock.withLock {
            guard numbered else { return }
            kept.removeAll { $0.seq <= n }
            if holding { flush(after: n) }
        }
    }

    // Under the lock: everything kept (after `n`) goes out in order; live from here on.
    private func flush(after n: UInt32?) {
        holding = false
        held = 0
        for k in kept where n.map({ k.seq > $0 }) ?? true { send(k.frame) }
    }
}
