import Foundation

// Media playback control via the private MediaRemote framework. On macOS 15.4+/26 the
// Now-Playing *info* getter is restricted, but the play-state query and the command
// sender still work — and, unlike the hardware media key, they give a REAL play-state
// (no false positives from a device that stays "running" while paused) and EXPLICIT
// pause/play (no toggle desync that would START already-paused media). No Accessibility
// needed.
//
// ponytail: private framework accessed via dlopen; if a future macOS removes these
// symbols, isPlaying() returns false and pause()/play() no-op — media control just
// stops working, nothing crashes.
final class MediaControl: @unchecked Sendable {
    static let shared = MediaControl()

    private typealias IsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias SendCmdFn   = @convention(c) (Int32, CFDictionary?) -> Bool

    private let isPlayingFn: IsPlayingFn?
    private let sendCmdFn: SendCmdFn?

    // MediaRemote command codes.
    private static let cmdPlay: Int32 = 0
    private static let cmdPause: Int32 = 1

    private init() {
        let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
        isPlayingFn = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying").map {
            unsafeBitCast($0, to: IsPlayingFn.self)
        }
        sendCmdFn = dlsym(h, "MRMediaRemoteSendCommand").map {
            unsafeBitCast($0, to: SendCmdFn.self)
        }
    }

    /// True only when media is ACTUALLY playing right now (async callback → Bool).
    func isPlaying() async -> Bool {
        guard let fn = isPlayingFn else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            fn(DispatchQueue.global()) { cont.resume(returning: $0) }
        }
    }

    func pause() { _ = sendCmdFn?(Self.cmdPause, nil) }   // explicit — no-op if already paused
    func play()  { _ = sendCmdFn?(Self.cmdPlay, nil) }    // explicit — only call to resume
}
