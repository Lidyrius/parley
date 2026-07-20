import Foundation

// FIFO queue of finished Claude turns. The app speaks them one at a time; only
// one turn is "active" (being spoken + awaiting a voice reply) at any moment.
// Routing to the right Claude session is by tmux_pane, carried in each payload.
//
// ponytail: not thread-safe on its own; the server drives it from one serial
// queue. Per-pane locks only if that ever changes.
final class TurnQueue {
    private(set) var pending: [TurnPayload] = []
    private(set) var active: TurnPayload?

    var isActive: Bool { active != nil }
    var pendingCount: Int { pending.count }

    func enqueue(_ turn: TurnPayload) {
        pending.append(turn)
    }

    /// If nothing is active, promote the head of the queue to active and return
    /// it so the caller can start speaking. Returns nil when busy or empty.
    @discardableResult
    func activateNext() -> TurnPayload? {
        guard active == nil, !pending.isEmpty else { return nil }
        active = pending.removeFirst()
        return active
    }

    /// Mark the active turn done. Returns the next turn if one is waiting (already
    /// promoted to active), so a drain loop can chain without a separate call.
    @discardableResult
    func complete() -> TurnPayload? {
        active = nil
        return activateNext()
    }
}
