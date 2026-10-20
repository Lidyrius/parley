import Foundation
import Observation
import UIKit

/// What the relay tells the rest of the app (the call, the away/push state).
enum RelayEvent {
    case opened                     // a socket opened (hello sent): resend per-connection state
    case closed
    case frame(Frame)               // every decoded frame except `sessions`
    case audio(Data)                // a binary frame: call audio from the host
}

/// The phone's side of the relay protocol: one WebSocket to the room, kept alive and redialled.
@MainActor @Observable
final class Relay {
    enum Link: Equatable { case idle, connecting, connected }
    enum Failure: Equatable { case unauthorized, unknownRoom, unreachable }

    private(set) var link: Link = .idle
    /// Why the last attempt failed; cleared once a socket opens.
    private(set) var failure: Failure?
    /// From `peer`; nil until the relay said.
    private(set) var hostOnline: Bool?
    private(set) var snapshot: Snapshot?
    /// Host clock minus phone clock (ms): timers count on the host's clock, as the mod's do.
    private(set) var skew: Double = 0
    private(set) var isDemo = false

    @ObservationIgnored private var pairing: Pairing?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var lastHeard = Date.distantPast
    @ObservationIgnored private var bestSkew: Double?
    @ObservationIgnored var onEvent: (RelayEvent) -> Void = { _ in }
    /// The mic thread's way to the open socket.
    let audioOut = AudioOut()

    /// The host seals its frames (v5) but this pairing has no key (paired before): pair again.
    private(set) var outdatedPairing = false
    @ObservationIgnored private var seal: RelaySeal?

    var status: ConnectionStatus {
        if isDemo { return .connected }
        return outdatedPairing ? .rejected : Self.status(link: link, hostOnline: hostOnline, failure: failure)
    }

    var canSend: Bool { isDemo || (link == .connected && hostOnline == true) }

    func hostNow(_ date: Date) -> Double { date.ms + skew }

    // MARK: - Lifecycle

    /// Sets the room to dial; `reconnect()` dials it.
    func use(_ pairing: Pairing) {
        disconnect()
        self.pairing = pairing
        seal = pairing.key.flatMap { RelaySeal(key: $0) }
        outdatedPairing = false
        snapshot = nil
        failure = nil
    }

    /// Dials right away, dropping any backoff (new pairing, back in the foreground, pull to refresh).
    func reconnect() {
        guard let pairing, !isDemo else { return }
        loop?.cancel()
        link = .connecting
        loop = Task { await run(pairing) }
    }

    func disconnect() {
        loop?.cancel()
        loop = nil
        socket = nil
        audioOut.use(nil)
        let wasOpen = link == .connected
        link = .idle
        hostOnline = nil
        if wasOpen { onEvent(.closed) }
    }

    func forget() {
        disconnect()
        pairing = nil
        seal = nil
        outdatedPairing = false
        snapshot = nil
        failure = nil
    }

    /// `only`: a share's room — that one session, nothing else (no widget).
    func startDemo(now: Date = .now, only: String? = nil) {
        isDemo = true
        link = .connected
        hostOnline = true
        if case .sessions(var s)? = Frame.decode(Demo.frame(now: now)) {
            if let only { s = Snapshot(sessions: s.sessions.filter { $0.id == only }) } else { WidgetFeed.publish(s) }
            snapshot = s
        }
    }

    /// "Fortsetzen": same as `POST /resume` on the host.
    func resume(_ id: String) {
        send(Outgoing.resume(id: id))
    }

    /// A text message to the host, if a socket is open (dropped otherwise: everything the phone
    /// sends is either a user action or state that is sent again on the next open).
    func send(_ text: String) {
        guard !isDemo, link == .connected, let ws = socket, let out = sealed(text) else { return }
        ws.send(.string(out)) { _ in }
    }

    /// End-to-end (docs/IPHONE.md → v5): sealed with the pairing's key; nil = not sent (never in
    /// the clear once there is a key).
    private func sealed(_ text: String) -> String? {
        guard let seal else { return text }
        return seal.text(text, at: .now)
    }

    // MARK: - Connection

    /// Redials with capped backoff (1 s → 30 s); a socket that was open starts over at 1 s.
    private func run(_ pairing: Pairing) async {
        var delay = 1.0
        while !Task.isCancelled {
            if await connectOnce(pairing) { delay = 1 }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 30)
        }
    }

    /// One socket until it drops. True when it was open.
    private func connectOnce(_ pairing: Pairing) async -> Bool {
        var request = URLRequest(url: pairing.socketURL)
        request.setValue("Bearer \(pairing.secret)", forHTTPHeaderField: "Authorization")
        let ws = URLSession.shared.webSocketTask(with: request)
        socket = ws
        link = .connecting
        bestSkew = nil
        ws.resume()

        var opened = false
        await withTaskCancellationHandler {
            do {
                // A send waits for the handshake, so a delivered hello means the socket is open.
                try await ws.send(.string(sealed(Outgoing.hello(device: UIDevice.current.name)) ?? "ping"))
                opened = true
                link = .connected
                failure = nil
                lastHeard = .now
                audioOut.use(ws, seal: seal)
                onEvent(.opened)
                let pinger = Task { await keepAlive(ws) }
                defer { pinger.cancel() }
                while true { apply(try await ws.receive()) }
            } catch {
                if !opened, !Task.isCancelled { failure = Self.failure(of: ws) }
            }
        } onCancel: {
            ws.cancel(with: .goingAway, reason: nil)
        }
        ws.cancel(with: .goingAway, reason: nil)
        if socket === ws, !Task.isCancelled {
            socket = nil
            audioOut.use(nil)
            link = .connecting  // the loop dials again after its backoff
            hostOnline = nil
            if opened { onEvent(.closed) }
        }
        return opened
    }

    /// `ping` every 25 s keeps NAT and the relay happy; silence for 60 s means a half-open
    /// socket (e.g. after a network change), which only a fresh dial fixes.
    private func keepAlive(_ ws: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled else { return }
            if Date.now.timeIntervalSince(lastHeard) > 60 {
                ws.cancel(with: .goingAway, reason: nil)
                return
            }
            try? await ws.send(.string("ping"))
        }
    }

    private func apply(_ message: URLSessionWebSocketTask.Message) {
        lastHeard = .now
        let text: String
        switch message {
        case .data(let data):
            guard let seal else { onEvent(.audio(data)); return }
            if let audio = seal.open(binary: data)?.data { onEvent(.audio(audio)) }
            return
        case .string(let t): text = t
        @unknown default: return
        }
        guard text != "pong", let frame = Frame.decode(opened(text) ?? "") else { return }
        switch frame {
        case .sessions(let s):
            if let at = s.at, let next = Self.skew(sample: at - Date.now.ms, best: bestSkew) {
                bestSkew = next
                if next != skew { skew = next }
            }
            snapshot = s
            WidgetFeed.publish(s)
            return
        case .peer(let host):
            hostOnline = host
        case .audio, .ring, .history, .image, .caption, .slides, .palette, .snapshotOpened,
             .shareLink, .joinRequest, .shareMove, .shareEnd, .notice, .ask, .askEnd, .other:
            break
        }
        onEvent(.frame(frame))
    }

    /// A frame from the relay, opened: with a key only sealed frames count — but the relay's own
    /// `peer`. Without one, a sealed frame means the host has moved on to v5: pair again.
    private func opened(_ text: String) -> String? {
        guard let seal else {
            if Self.isSealed(text) { outdatedPairing = true; return nil }
            return text
        }
        if let json = seal.open(text: text)?.json { return json }
        if case .peer? = Frame.decode(text) { return text }
        return nil
    }

    nonisolated static func isSealed(_ text: String) -> Bool {
        ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])?["e"] is String
    }

    private static func failure(of ws: URLSessionWebSocketTask) -> Failure {
        switch (ws.response as? HTTPURLResponse)?.statusCode {
        case 401?, 403?: .unauthorized
        case 404?: .unknownRoom
        default: .unreachable
        }
    }

    // MARK: - Pure rules (unit-tested)

    nonisolated static func status(link: Link, hostOnline: Bool?, failure: Failure?) -> ConnectionStatus {
        if link == .connected {
            switch hostOnline {
            case true?: return .connected
            case false?: return .hostOffline
            case nil: return .connecting
            }
        }
        switch failure {
        case .unauthorized?: return .rejected
        case .unknownRoom?: return .unknownRoom
        case .unreachable?: return .unreachable
        case nil: return .connecting
        }
    }

    /// Latency and the relay's replayed (older) frame only make `at` look early, so the largest
    /// sample per connection is the best skew estimate. Off by minutes means a stale frame.
    nonisolated static func skew(sample: Double, best: Double?) -> Double? {
        guard abs(sample) < 120_000 else { return best }
        return max(best ?? sample, sample)
    }
}

/// Sends call audio from the mic's thread straight to the open socket, without a hop through
/// the main actor for every 20 ms frame. Sends keep their order.
final class AudioOut: @unchecked Sendable {
    private let socket = Locked<(ws: URLSessionWebSocketTask, seal: RelaySeal?)?>(nil)

    func use(_ ws: URLSessionWebSocketTask?, seal: RelaySeal? = nil) { socket.value = ws.map { ($0, seal) } }

    func send(_ frame: Data) {
        guard let (ws, seal) = socket.value else { return }
        guard let out = seal == nil ? frame : seal?.binary(frame, at: .now) else { return }
        ws.send(.data(out)) { _ in }
    }
}
