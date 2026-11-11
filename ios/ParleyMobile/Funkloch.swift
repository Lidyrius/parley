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
