import Foundation
import WidgetKit

/// Keeps the widgets current: each overview from the host becomes a `WidgetSnapshot` in the App
/// Group, and the widgets reload — only when what they show changed (WidgetKit budgets reloads).
@MainActor
enum WidgetFeed {
    private static var last: WidgetSnapshot?

    static func publish(_ s: Snapshot, now: Date = .now) { store(snapshot(s, now: now)) }

    /// The host's silent push (`widget`): the app was woken just to keep the widgets current.
    static func received(_ payload: Any, now: Date = .now) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let push = try? JSONDecoder().decode(WidgetPush.self, from: data) else { return false }
        store(push.snapshot(at: now))
        return true
    }

    static func store(_ snap: WidgetSnapshot) {
        var compare = snap
        compare.at = last?.at ?? snap.at   // the time alone is no change
        guard compare != last else { return }
        last = snap
        SharedState.snapshot = snap
        WidgetCenter.shared.reloadTimelines(ofKind: SharedState.widgetKind)
    }

    /// The host's overview (times in epoch ms) as the widgets show it.
    nonisolated static func snapshot(_ s: Snapshot, now: Date) -> WidgetSnapshot {
        let live = s.sessions.filter { $0.state != .stopped }
        let rows = live.map { x in
            ParleyAttributes.Row(id: x.id, label: x.name, state: x.state.rawValue, since: x.since / 1000,
                                 until: x.until.map { $0 / 1000 }, callback: x.callback.map { $0 / 1000 })
        }.sorted(by: ParleyAttributes.Row.urgentFirst)
        let byId = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let spoken = rows.first { !(byId[$0.id]?.stats?.lastLine ?? "").isEmpty }
        func limit(_ kind: String) -> Double? { s.today?.rateLimits.first { $0.kind == kind }?.percentUsed }
        return WidgetSnapshot(at: now, sessions: rows, line: spoken.flatMap { byId[$0.id]?.stats?.lastLine }, from: spoken?.label,
                              cost: s.today?.costUsd, updates: s.today?.turns, limit: limit("five_hour"), week: limit("seven_day"))
    }
}
