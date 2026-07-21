import Foundation

// Explicit media pause/resume via the private MediaRemote framework's command sender.
// On macOS 15.4+/26 the Now-Playing *play-state* getter is restricted for third-party
// apps (always returns false), so we detect "is playing" via CoreAudio instead
// (AudioDevices.isDefaultOutputActive) and use MediaRemote only to CONTROL playback with
// EXPLICIT pause/play commands — never the toggle key, which would start already-paused
// media. Needs no Accessibility.
//
// ponytail: private framework via dlopen; if a future macOS drops the symbol, pause()/
// play() no-op — media control just stops working, nothing crashes.
final class MediaControl: @unchecked Sendable {
    static let shared = MediaControl()

    private typealias SendCmdFn = @convention(c) (Int32, CFDictionary?) -> Bool
    private let sendCmdFn: SendCmdFn?

    private static let cmdPlay: Int32 = 0
    private static let cmdPause: Int32 = 1

    private init() {
        let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
        sendCmdFn = dlsym(h, "MRMediaRemoteSendCommand").map { unsafeBitCast($0, to: SendCmdFn.self) }
    }

    func pause() { _ = sendCmdFn?(Self.cmdPause, nil) }   // explicit — no-op if already paused
    func play()  { _ = sendCmdFn?(Self.cmdPlay, nil) }    // explicit — only call to resume
}
