import Foundation
import Observation
import UIKit

/// The phone's side of relay protocol v1: one WebSocket to the room, kept alive and redialled.
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

    var status: ConnectionStatus {
        isDemo ? .connected : Self.status(link: link, hostOnline: hostOnline, failure: failure)
    }

    var canSend: Bool { isDemo || (link == .connected && hostOnline == true) }

    func hostNow(_ date: Date) -> Double { date.ms + skew }

    // MARK: - Lifecycle

    /// Sets the room to dial; `reconnect()` dials it.
    func use(_ pairing: Pairing) {
        disconnect()
        self.pairing = pairing
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
        link = .idle
        hostOnline = nil
    }

    func forget() {
        disconnect()
        pairing = nil
        snapshot = nil
        failure = nil
    }

    func startDemo(now: Date = .now) {
        isDemo = true
        link = .connected
        hostOnline = true
        if case .sessions(let s)? = Frame.decode(Demo.frame(now: now)) { snapshot = s }
    }

    /// "Fortsetzen": same as `POST /resume` on the host.
    func resume(_ id: String) {
        guard !isDemo, link == .connected, let ws = socket else { return }
        Task { try? await ws.send(.string(Outgoing.resume(id: id))) }
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
                try await ws.send(.string(Outgoing.hello(device: UIDevice.current.name)))
                opened = true
                link = .connected
                failure = nil
                lastHeard = .now
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
            link = .connecting  // the loop dials again after its backoff
            hostOnline = nil
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
        guard case .string(let text) = message, let frame = Frame.decode(text) else { return }
        switch frame {
        case .sessions(let s):
            if let at = s.at, let next = Self.skew(sample: at - Date.now.ms, best: bestSkew) {
                bestSkew = next
                if next != skew { skew = next }
            }
            snapshot = s
        case .peer(let host):
            hostOnline = host
        case .other:
            break
        }
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
