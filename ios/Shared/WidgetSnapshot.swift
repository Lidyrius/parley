import Foundation

/// What the widgets show: every running session (most urgent first), today's figures and when
/// it was taken. The app writes it into the App Group whenever the host's overview arrives.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    var at: Date
    var sessions: [ParleyAttributes.Row] = []
    var line: String?                 // the most urgent session's last spoken line
    var from: String?
    var cost: Double?                 // today
    var updates: Int?
    var limit: Double?                // 5-h limit, % used
    var week: Double?                 // weekly limit, % used

    var alive: Int { sessions.count }
    var top: ParleyAttributes.Row? { sessions.first }

    /// Too old to pass for now: the widget says when it was taken.
    func isStale(at now: Date) -> Bool { now.timeIntervalSince(at) > 10 * 60 }

    static func demo(now: Date = Date()) -> Self {
        let state = ParleyAttributes.ContentState.demo(now: now)
        return Self(at: now, sessions: state.sessions + [
            .init(id: "e", label: "Angebote", state: "waiting", since: now.timeIntervalSince1970 - 60, until: now.timeIntervalSince1970 + 245),
        ], line: state.line, from: state.from, cost: 13.61, updates: 65, limit: 42, week: 18)
    }
}

extension ParleyAttributes.Row {
    /// The order that matters to Sir (as the host sorts the Live Activity): a call back owed, a
    /// ring to come, talking, wanting to talk, paused, working, background, parked, ready.
    var rank: Int {
        switch kind {
        case .callBack: 0
        case .ringsAt: 1
        case .live: 2
        case .queued: 3
        case .paused: 4
        case .working: 5
        case .background: 6
        case .parked: 7
        case .idle: 8
        case .stopped: 9
        }
    }

    static func urgentFirst(_ a: Self, _ b: Self) -> Bool { a.rank != b.rank ? a.rank < b.rank : a.since > b.since }
}

extension SharedState {
    static let widgetKind = "de.developaway.parley.sessions"

    static var snapshot: WidgetSnapshot? {
        get { defaults.data(forKey: "widgetSnapshot").flatMap { try? JSONDecoder().decode(WidgetSnapshot.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "widgetSnapshot") }
    }
}
