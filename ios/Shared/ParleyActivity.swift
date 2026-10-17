import ActivityKit
import Foundation

/// The one Parley Live Activity (docs/LIVE-ACTIVITIES.md): every session at a glance in the
/// Dynamic Island, on the Lock Screen, the Watch and in CarPlay. The host starts, updates and ends
/// it with APNs `liveactivity` pushes; `ContentState` is the `content-state` it sends — keep it in
/// step with app/Sources/Parley/LiveActivity.swift and windows/LiveActivity.cs. Times are epoch
/// seconds (plain numbers: ActivityKit decodes pushes with the default JSON strategy).
struct ParleyAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var sessions: [Row] = []      // most urgent first (the host sorts), at most 4
        var alive = 0                 // sessions not stopped
        var line: String?             // Parley's latest spoken line…
        var from: String?             // …and whose session it was
        var ask: Ask?                 // Stumm: a question waiting for Sir, with answers to tap
    }

    /// A question Parley asked while Stumm is on: answered with a tap (the predicted answers)
    /// or in the app.
    struct Ask: Codable, Hashable, Sendable {
        var id: String                // the session
        var label: String
        var text: String              // Parley's line
        var options: [String] = []    // at most 3
    }

    struct Row: Codable, Hashable, Sendable, Identifiable {
        var id: String
        var label: String
        var state: String             // the host's session state (unknown → idle)
        var since: Double             // in this state since
        var until: Double?            // paused until
        var callback: Double?         // Parley rings again then; 0 = waits for Sir's call back
    }
}

extension ParleyAttributes.Row {
    /// What a row means for Sir, in the order that matters to him.
    enum Kind: Equatable, Sendable {
        case callBack                 // waits for Sir's call back
        case ringsAt(Date)            // put off: Parley rings again then
        case live                     // speaking / listening / transcribing
        case queued                   // wants to talk
        case paused(Date)             // "Warte X Minuten"
        case working(Date)            // since
        case background(Date)         // agents or jobs running, since
        case parked, idle, stopped
    }

    var kind: Kind {
        if let c = callback { return c <= 0 ? .callBack : .ringsAt(Date(timeIntervalSince1970: c)) }
        let at = Date(timeIntervalSince1970: since)
        switch state {
        case "speaking", "listening", "transcribing": return .live
        case "queued": return .queued
        case "waiting": return until.map { .paused(Date(timeIntervalSince1970: $0)) } ?? .working(at)
        case "working": return .working(at)
        case "background": return .background(at)
        case "parked": return .parked
        case "stopped": return .stopped
        default: return .idle
        }
    }

    /// The state in a few words (the timer shows beside it).
    var title: String {
        switch kind {
        case .callBack: "wartet auf Rückruf"
        case .ringsAt: "ruft wieder an"
        case .live: state == "listening" ? "hört zu" : "spricht"
        case .queued: "möchte sprechen"
        case .paused: "pausiert"
        case .working: "arbeitet"
        case .background: "im Hintergrund"
        case .parked: "geparkt"
        case .idle: "bereit"
        case .stopped: "gestoppt"
        }
    }

    var role: StateColors.Role {
        switch kind {
        case .callBack, .ringsAt, .live: .accent
        case .queued, .paused: .waiting
        case .working: .working
        case .background: .purple
        case .parked, .stopped: .stopped
        case .idle: .idle
        }
    }

    /// Sir is wanted: a call back or Parley wanting to talk.
    var wantsSir: Bool {
        switch kind {
        case .callBack, .ringsAt, .live, .queued: true
        default: false
        }
    }
}

extension ParleyAttributes.ContentState {
    /// The row the compact Island shows: the first (most urgent).
    var top: ParleyAttributes.Row? { sessions.first }

    /// `from` of an answer Sir just tapped (shown as sent until the host's next update).
    static let you = "Du"

    /// The rest, shown as names only.
    var others: ArraySlice<ParleyAttributes.Row> { sessions.dropFirst() }

    /// Demo content for previews and the simulator (`-demoActivity`).
    static func demo(now: Date = Date()) -> Self {
        let t = now.timeIntervalSince1970
        return Self(sessions: [
            .init(id: "b", label: "Website", state: "idle", since: t - 600, callback: 0),
            .init(id: "a", label: "Shirts", state: "working", since: t - 138),
            .init(id: "c", label: "Tippfrei", state: "background", since: t - 1240),
            .init(id: "d", label: "Zentrale", state: "idle", since: t - 3000),
        ], alive: 4, line: "Die Tests sind grün, Sir. Soll ich deployen?", from: "Shirts")
    }

    /// `-demoActivity ask`: Stumm with a question waiting.
    static func demoAsk(now: Date = Date()) -> Self {
        var s = demo(now: now)
        s.ask = .init(id: "a", label: "Shirts", text: "Die Tests sind grün, Sir. Soll ich auf Produktion deployen?",
                      options: ["Ja, deployen", "Erst Staging", "Warte noch"])
        return s
    }
}

/// The palette's state colours for the extension (Island, Lock Screen, controls): the app writes
/// the chosen palette's into the App Group whenever it changes. 0xRRGGBB, light and dark.
struct StateColors: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case accent, waiting, working, purple, idle, stopped }

    var accent: [UInt32] = [0xD97757, 0xD97757]
    var waiting: [UInt32] = [0xD9A43B, 0xD9A43B]
    var working: [UInt32] = [0x5B8DEF, 0x5B8DEF]
    var purple: [UInt32] = [0x9B87F5, 0x9B87F5]
    var idle: [UInt32] = [0x4EBA65, 0x4EBA65]
    var stopped: [UInt32] = [0x8B8A85, 0x8B8A85]

    func hex(_ role: Role, dark: Bool) -> UInt32 {
        let pair = switch role {
        case .accent: accent
        case .waiting: waiting
        case .working: working
        case .purple: purple
        case .idle: idle
        case .stopped: stopped
        }
        return (dark ? pair.last : pair.first) ?? 0x8B8A85
    }
}

/// What app and extension share through the App Group: the Unterwegs / Stumm switches (the
/// controls show and set them) and the state colours.
enum SharedState {
    static let group = "group.de.developaway.parley"
    nonisolated(unsafe) static let defaults = UserDefaults(suiteName: group) ?? .standard

    static var away: Bool {
        get { defaults.bool(forKey: "awayMode") }
        set { defaults.set(newValue, forKey: "awayMode") }
    }

    static var silent: Bool {
        get { defaults.bool(forKey: "silentMode") }
        set { defaults.set(newValue, forKey: "silentMode") }
    }

    static var colors: StateColors {
        get { defaults.data(forKey: "stateColors").flatMap { try? JSONDecoder().decode(StateColors.self, from: $0) } ?? StateColors() }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "stateColors") }
    }

    /// The controls' kinds (reloaded when the app changes a switch).
    static let callKind = "de.developaway.parley.call"
    static let awayKind = "de.developaway.parley.away"
    static let silentKind = "de.developaway.parley.silent"
}
