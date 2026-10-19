import SwiftUI

// The overview's sessions (design C2, docs/design/screens/ios/01-uebersicht): a two-column grid
// of equally tall cards, or a list with one row per session. A card says its state only through
// symbol, colour and at most one action; tapping it opens a sheet with the details.

/// The one action a session offers on the overview.
enum SessionAction: Equatable {
    case callBack(now: Bool)   // its call was put off: "Rückrufen" (waits for you) / "Jetzt anrufen"
    case resume                // "Fortsetzen"

    init?(_ s: Session) {
        if let cb = s.callback { self = .callBack(now: cb != 0); return }
        guard s.canResume else { return nil }
        self = .resume
    }

    var title: String {
        switch self {
        case .callBack(let now): now ? "Jetzt anrufen" : "Rückrufen"
        case .resume: "Fortsetzen"
        }
    }
}

extension Fmt {
    /// The card's corner time: "0:13" (since), "4:07" (a pause: left), "vor 3 min" (stopped).
    static func cornerTime(_ s: Session, at: Double) -> String {
        if s.state == .waiting, let until = s.until { return clock(until - at) }
        if s.state == .stopped { return "vor \(max(1, Int(((at - s.since) / 60_000).rounded()))) min" }
        return clock(at - s.since)
    }

    /// The state as the card says it — a put-off call first: "wartet auf Rückruf", "ruft in 0:42 an".
    static func cardState(_ s: Session, at: Double) -> String {
        if let cb = s.callback { return cb == 0 ? "wartet auf Rückruf" : "ruft in \(clock(max(0, cb - at))) an" }
        if let name = s.asking { return "Rückfrage an \(name)" }
        return stateLabel(s)
    }
}

@MainActor
private func stateInk(_ s: Session) -> Color {
    if s.callback != nil { return SessionState.waiting.ink }
    return s.state == .stopped ? .secondary : s.state.ink
}

/// The callbacks a tile needs.
struct SessionActions {
    var open: (Session) -> Void            // the details sheet
    var resume: (String) -> Void
    var callBack: () -> Void
    var canSend: Bool

    @MainActor func perform(_ a: SessionAction, _ s: Session) {
        switch a {
        case .callBack: callBack()
        case .resume: resume(s.id)
        }
    }
}

/// A grid card: symbol + time, the last line (or a small waveform while it speaks), name, state,
/// and at most one action. All cards are equally tall.
struct SessionTile: View {
    let session: Session
    let skew: Double
    let actions: SessionActions
    // Tall enough for the fullest card (a two-line quote and an action): every card the same.
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 184
    @ScaledMetric(relativeTo: .headline) private var ring: CGFloat = 30

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let at = context.date.ms + skew
            VStack(alignment: .leading, spacing: 8) {
                Button { actions.open(session) } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top) {
                            RingView(session: session, skew: skew, size: ring)
                            Spacer(minLength: 4)
                            Text(Fmt.cornerTime(session, at: at))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Spacer(minLength: 8)
                        if session.isLive {
                            MiniWave(color: session.state.color).frame(height: 22).padding(.bottom, 6)
                        } else if let line = session.stats?.lastLine, !line.isEmpty {
                            Text("„\(line)“")
                                .font(.footnote)
                                .italic()
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .padding(.bottom, 6)
                        }
                        Text(session.name)
                            .font(.headline)
                            .foregroundStyle(session.state == .stopped ? .secondary : .primary)
                            .lineLimit(1)
                        Text(Fmt.cardState(session, at: at))
                            .font(.subheadline)
                            .foregroundStyle(stateInk(session))
                            .lineLimit(1)
                            .monospacedDigit()
                        SharedBadge(tags: session.shared)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(session.name), \(Fmt.cardState(session, at: at)), \(Fmt.cornerTime(session, at: at))")
                .accessibilityHint("Details öffnen")
                if let action = SessionAction(session) {
                    ActionButton(action: action, enabled: actions.canSend) { actions.perform(action, session) }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: .infinity, alignment: .topLeading)
        .background(CardBackground(live: session.voice))
    }
}

/// A list row: symbol, name and state, time; the last line in one line; an action only when needed.
struct SessionRow: View {
    let session: Session
    let skew: Double
    let actions: SessionActions
    @ScaledMetric(relativeTo: .headline) private var ring: CGFloat = 28

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let at = context.date.ms + skew
            HStack(alignment: .top, spacing: 12) {
                RingView(session: session, skew: skew, size: ring)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(session.name)
                            .font(.headline)
                            .foregroundStyle(session.state == .stopped ? .secondary : .primary)
                            .lineLimit(1)
                            .layoutPriority(1)
                        Text(Fmt.cardState(session, at: at))
                            .font(.subheadline)
                            .foregroundStyle(stateInk(session))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Fmt.cornerTime(session, at: at))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if session.isLive {
                        MiniWave(color: session.state.color).frame(width: 96, height: 16)
                    } else if let line = session.stats?.lastLine, !line.isEmpty {
                        Text("„\(line)“")
                            .font(.subheadline)
                            .italic()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    SharedBadge(tags: session.shared)
                    if let action = SessionAction(session) {
                        ActionButton(action: action, enabled: actions.canSend) { actions.perform(action, session) }
                            .padding(.top, 2)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(session.voice ? Theme.claude.opacity(0.08) : .clear)
            .contentShape(Rectangle())
            .onTapGesture { actions.open(session) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(session.name), \(Fmt.cardState(session, at: at)), \(Fmt.cornerTime(session, at: at))")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Details öffnen")
        }
    }
}

/// The card's one action: a small filled capsule in the accent.
private struct ActionButton: View {
    let action: SessionAction
    let enabled: Bool
    let perform: () -> Void
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            perform()
        } label: {
            Text(action.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.claude))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .sensoryFeedback(.impact(weight: .medium), trigger: taps)
    }
}

/// A card's surface: tinted and outlined in the accent while the session holds the voice.
struct CardBackground: View {
    var live = false
    var radius: CGFloat = 20

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(Theme.card)
            .overlay(shape.fill(Theme.claude.opacity(live ? 0.10 : 0)))
            .overlay(shape.strokeBorder(live ? Theme.claude.opacity(0.55) : Theme.stroke, lineWidth: 1))
    }
}

/// A small speech-like waveform for a speaking session (still under Reduce Motion).
struct MiniWave: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let bars = 15

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let w = geo.size.width / CGFloat(bars)
                HStack(alignment: .center, spacing: w * 0.45) {
                    ForEach(0..<bars, id: \.self) { i in
                        let phase = Double(i) * 0.9
                        let level = 0.25 + 0.75 * abs(sin(t * 5.3 + phase) * sin(t * 2.1 + phase * 0.6))
                        Capsule()
                            .fill(color)
                            .frame(width: w * 0.55, height: max(3, geo.size.height * level))
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Tapping a card: the session's details in a sheet — figures, the agent's task, what it said
/// last, and the way to its history or a message.
struct SessionSheet: View {
    let session: Session
    let skew: Double
    let openHistory: () -> Void
    let message: () -> Void
    var canShare = false            // v7: one of the owner's own sessions
    @Environment(\.dismiss) private var dismiss
    @State private var sharing = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let at = context.date.ms + skew
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 14) {
                        RingView(session: session, skew: skew, size: 46)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.name).font(.title2.bold()).lineLimit(1)
                            Text(Fmt.cardState(session, at: at) + " · " + Fmt.timer(session, at: at))
                                .font(.subheadline)
                                .foregroundStyle(stateInk(session))
                                .monospacedDigit()
                        }
                        Spacer(minLength: 8)
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.headline)
                                .foregroundStyle(Theme.claude)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(Theme.card))
                                .overlay(Circle().strokeBorder(Theme.stroke))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Schließen")
                    }
                    if !session.tasks.isEmpty {
                        Box(title: "Agent") {
                            Text(session.tasks.map(\.description).joined(separator: "\n"))
                                .font(.body)
                                .foregroundStyle(SessionState.background.ink)
                        }
                    }
                    if let st = session.stats {
                        let figures = Self.figures(st, at: at)
                        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                            ForEach(Array(stride(from: 0, to: figures.count, by: 2)), id: \.self) { i in
                                GridRow {
                                    figures[i]
                                    if i + 1 < figures.count { figures[i + 1] } else { Color.clear.gridCellUnsizedAxes(.vertical) }
                                }
                            }
                        }
                    }
                    if let line = session.stats?.lastLine, !line.isEmpty {
                        Box(title: "Zuletzt gesagt") {
                            Text("„\(line)“").font(.body).italic()
                        }
                    }
                    HStack(spacing: 12) {
                        Button(action: openHistory) {
                            Text("Verlauf öffnen")
                                .font(.headline)
                                .foregroundStyle(Theme.onAccent)
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .background(Capsule().fill(Theme.claude))
                        }
                        Button(action: message) {
                            Text("Nachricht")
                                .font(.headline)
                                .foregroundStyle(Theme.claude)
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .background(Capsule().fill(Theme.claude.opacity(0.14)))
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    if canShare {
                        Button { sharing = true } label: {
                            Label(session.shared.isEmpty ? "Teilen …" : "Geteilt mit \(session.shared.map(\.name).joined(separator: ", "))",
                                  systemImage: "person.2.badge.plus")
                                .font(.headline)
                                .foregroundStyle(Theme.claude)
                                .frame(maxWidth: .infinity, minHeight: 46)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
        }
        .background(Theme.background)
        .sheet(isPresented: $sharing) { ShareSessionView(session: session) }
        // Tall enough for the figures, the last line and both buttons; pull up for the rest.
        .presentationDetents([.fraction(0.74), .large])
        .presentationDragIndicator(.visible)
    }

    /// Laufzeit, Kosten, Updates · Antworten, Kontext (with its bar) — those the host reports.
    private static func figures(_ st: Stats, at: Double) -> [Figure] {
        var out: [Figure] = []
        if let started = st.startedAt { out.append(Figure(value: Fmt.span(at - started), label: "Laufzeit")) }
        if let cost = st.costUsd { out.append(Figure(value: Fmt.money(cost), label: "Kosten")) }
        out.append(Figure(value: "\(st.turns) · \(st.replies)", label: "Updates · Antworten"))
        if let ctx = st.contextPercent { out.append(Figure(value: Fmt.percent(ctx), label: "Kontext", bar: ctx / 100)) }
        return out
    }

    private struct Box<Content: View>: View {
        let title: String
        @ViewBuilder var content: () -> Content

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased()).font(.footnote).foregroundStyle(.secondary)
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CardBackground(radius: 18))
        }
    }

    private struct Figure: View {
        let value: String
        let label: String
        var bar: Double?

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(value).font(.title2.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                if let bar { ProgressBar(fraction: bar, color: SessionState.background.color) }
                Text(label).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(CardBackground(radius: 18))
        }
    }
}

/// A slim bar for a share (context, the limits).
struct ProgressBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// The animated ring per state (the mod's `ringSvg`, drawn natively).
struct RingView: View {
    let session: Session
    let skew: Double
    var size: CGFloat = 40
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let kind = RingKind(session)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !kind.isAnimated)) { context in
            Ring(kind: kind, color: session.state.color, size: size,
                 t: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate,
                 left: session.remaining(at: context.date.ms + skew) ?? 0)
        }
        .frame(width: size, height: size)
        .opacity(session.state == .stopped ? 0.7 : 1)
        .accessibilityHidden(true)
    }
}

/// Geometry in the mod's 40-unit viewBox: track r 15, stroke 3.
private struct Ring: View {
    let kind: RingKind
    let color: Color
    let size: CGFloat
    let t: Double       // seconds; 0 freezes the motion (Reduce Motion)
    let left: Double    // countdown fraction left

    private var u: CGFloat { size / 40 }

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: 3 * u).frame(width: 30 * u, height: 30 * u)
            switch kind {
            case .live:
                arc(1)
                // r 6 → 9 → 6 every 1.4 s.
                let r = 6 + 3 * (0.5 - 0.5 * cos(2 * .pi * t / 1.4))
                Circle().fill(color).frame(width: 2 * r * u, height: 2 * r * u)
            case .spin(let fraction, let period):
                arc(fraction).rotationEffect(.degrees(360 * cycle(period)))
            case .background:
                arc(1).opacity(0.35)
                Circle().fill(color).frame(width: 7 * u, height: 7 * u)
                    .position(x: size / 2, y: 5 * u)
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(360 * cycle(2.4)))
                Circle().fill(color).frame(width: 8 * u, height: 8 * u)
            case .countdown:
                arc(left)
            case .parked:
                HStack(spacing: 4 * u) {
                    RoundedRectangle(cornerRadius: 1.5 * u).fill(color).frame(width: 4 * u, height: 14 * u)
                    RoundedRectangle(cornerRadius: 1.5 * u).fill(color).frame(width: 4 * u, height: 14 * u)
                }
            case .idle:
                arc(1).opacity(0.45)
                Circle().fill(color).frame(width: 10 * u, height: 10 * u)
            case .stopped:
                RoundedRectangle(cornerRadius: 2 * u).fill(color).frame(width: 10 * u, height: 10 * u)
            }
        }
        .frame(width: size, height: size)
    }

    private func cycle(_ period: Double) -> Double { (t / period).truncatingRemainder(dividingBy: 1) }

    /// An arc from 12 o'clock, clockwise.
    private func arc(_ fraction: Double) -> some View {
        Circle()
            .trim(from: 0, to: fraction)
            .stroke(color, style: StrokeStyle(lineWidth: 3 * u, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: 30 * u, height: 30 * u)
    }
}

/// v7: "geteilt mit Max · Marketing" under a session that has guests.
struct SharedBadge: View {
    let tags: [ShareTag]

    var body: some View {
        if let first = tags.first {
            Label {
                Text(tags.count == 1 ? "geteilt mit \(first.name)\(first.role.isEmpty ? "" : " · \(first.role)")"
                                     : "geteilt mit \(tags.map(\.name).joined(separator: ", "))")
                    .lineLimit(1)
            } icon: {
                Image(systemName: "person.2.fill")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(SessionState.idle.ink)
        }
    }
}
