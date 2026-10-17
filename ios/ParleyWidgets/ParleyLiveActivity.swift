import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The Parley Live Activity: the Dynamic Island (compact, minimal, expanded), the Lock Screen and
/// — as the small family — the Apple Watch Smart Stack and CarPlay. Timers count by themselves;
/// the host pushes only when a state changes.
///
/// Layout (expanded and Lock Screen, 160 pt at most): a header (orb, "Parley", how many run, the
/// round call button), then one thing large — Parley's question with answers to tap, or the most
/// urgent session with its timer — and the other sessions as a quiet row of names.
struct ParleyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ParleyAttributes.self) { context in
            LockScreenView(state: context.state, stale: context.isStale)
                .widgetURL(Link.session(context.state.ask?.id ?? context.state.top?.id))
        } dynamicIsland: { context in
            let state = context.state
            let colors = SharedState.colors
            let tint = Paint.color(state.ask != nil ? .accent : state.top?.role ?? .idle, colors, dark: true)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading, priority: 1) {
                    Title(state: state, tint: tint, stale: false, short: true)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CallButton(state: state, colors: colors, dark: true)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Detail(state: state, colors: colors, dark: true)
                        .padding(.horizontal, 6)
                        .padding(.top, state.ask == nil ? 6 : 2)
                }
            } compactLeading: {
                Orb(color: tint, size: 22)
            } compactTrailing: {
                Badge(state: state, colors: colors)
            } minimal: {
                Orb(color: tint, size: 22)
            }
            .keylineTint(tint)
            .widgetURL(Link.session(state.ask?.id ?? state.top?.id))
        }
        .supplementalActivityFamilies([.small])
    }
}

// MARK: - Lock Screen, Watch, CarPlay

private struct LockScreenView: View {
    let state: ParleyAttributes.ContentState
    let stale: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.activityFamily) private var family

    var body: some View {
        let colors = SharedState.colors
        let dark = scheme == .dark
        if family == .small {
            Small(state: state, colors: colors, dark: dark)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Title(state: state, tint: Paint.color(state.ask != nil ? .accent : state.top?.role ?? .idle, colors, dark: dark),
                          stale: stale)
                    Spacer()
                    CallButton(state: state, colors: colors, dark: dark)
                }
                Detail(state: state, colors: colors, dark: dark)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .opacity(stale ? 0.6 : 1)
        }
    }
}

/// Watch Smart Stack and CarPlay: the question, or the most urgent session.
private struct Small: View {
    let state: ParleyAttributes.ContentState
    let colors: StateColors
    let dark: Bool

    var body: some View {
        HStack(spacing: 10) {
            Orb(color: Paint.color(state.ask != nil ? .accent : state.top?.role ?? .idle, colors, dark: dark), size: 28)
            VStack(alignment: .leading, spacing: 2) {
                if let ask = state.ask {
                    Text(ask.label).font(.headline).lineLimit(1)
                    Text(ask.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else if let top = state.top {
                    Text(top.label).font(.headline).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(top.title)
                        Clock(row: top)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                } else {
                    Text("Parley").font(.headline)
                    Text(Copy.alive(state.alive)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }
}

// MARK: - Parts

/// Orb, "Parley", and how many sessions run (or that the Mac went quiet).
private struct Title: View {
    let state: ParleyAttributes.ContentState
    let tint: Color
    let stale: Bool
    var short = false   // the Island's narrow corner

    var body: some View {
        HStack(spacing: 10) {
            Orb(color: tint, size: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text("Parley").font(.headline)
                if let ask = state.ask, !stale {
                    // A question waits: whose it is, in the accent.
                    Label(ask.label, systemImage: "bubble.left.fill")
                        .labelStyle(Tight())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                } else {
                    Text(stale ? "Mac nicht erreichbar" : short ? "\(state.alive) aktiv" : Copy.alive(state.alive))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
        }
    }
}

/// Icon and title, close together.
private struct Tight: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.font(.caption2); configuration.title }
    }
}

/// The call, one tap away: round, beside the title.
private struct CallButton: View {
    let state: ParleyAttributes.ContentState
    let colors: StateColors
    let dark: Bool

    var body: some View {
        Button(intent: CallParleyIntent()) {
            Image(systemName: Copy.callSymbol(state.top))
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Paint.color(.accent, colors, dark: dark)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Paint.onColor(.accent, colors, dark: dark))
        .accessibilityLabel(Text(Copy.callTitle(state.top)))
    }
}

/// One thing large: Parley's question (with answers to tap), else the most urgent session.
/// Below it the others, as names.
private struct Detail: View {
    let state: ParleyAttributes.ContentState
    let colors: StateColors
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let ask = state.ask {
                Question(ask: ask, colors: colors, dark: dark)
            } else if let top = state.top {
                Hero(row: top, line: state.from == top.label ? state.line : nil, color: Paint.color(top.role, colors, dark: dark))
                if state.from == ParleyAttributes.ContentState.you, let sent = state.line {
                    // Just tapped: the answer, confirmed until the host's next update.
                    Label("„\(sent)“ gesendet", systemImage: "checkmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !state.others.isEmpty { Others(rows: state.others, colors: colors, dark: dark) }
            } else {
                Text("Keine Session aktiv").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// The most urgent session: its name and state, the timer large, its last line beneath.
private struct Hero: View {
    let row: ParleyAttributes.Row
    let line: String?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.label).font(.title3.weight(.semibold)).lineLimit(1)
                    Text(row.title).font(.subheadline).foregroundStyle(color).lineLimit(1)
                }
                Spacer(minLength: 8)
                Clock(row: row)
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(color)
            }
            if let line, !line.isEmpty {
                Text("„\(line)“")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Parley's question while Stumm is on, and the predicted answers as buttons.
private struct Question: View {
    let ask: ParleyAttributes.Ask
    let colors: StateColors
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ask.text).font(.subheadline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if !ask.options.isEmpty {
                HStack(spacing: 8) {
                    ForEach(ask.options.prefix(3), id: \.self) { option in
                        Button(intent: ReplyIntent(session: ask.id, text: option)) {
                            Text(option)
                                .font(.footnote.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                                .background(Capsule().fill(Paint.color(.accent, colors, dark: dark).opacity(0.22)))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Paint.color(.accent, colors, dark: dark))
                    }
                }
            }
        }
    }
}

/// The other sessions: a dot in their colour and the name — the details live in the app.
private struct Others: View {
    let rows: ArraySlice<ParleyAttributes.Row>
    let colors: StateColors
    let dark: Bool

    var body: some View {
        HStack(spacing: 14) {
            ForEach(rows.prefix(3)) { row in
                HStack(spacing: 5) {
                    Circle().fill(Paint.color(row.role, colors, dark: dark)).frame(width: 7, height: 7)
                    Text(row.label).lineLimit(1)
                }
                .accessibilityLabel("\(row.label), \(row.title)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// The compact Island's right side: what is needed now, in a glance.
private struct Badge: View {
    let state: ParleyAttributes.ContentState
    let colors: StateColors

    var body: some View {
        let top = state.top
        let color = Paint.color(state.ask != nil ? .accent : top?.role ?? .idle, colors, dark: true)
        Group {
            if state.ask != nil {
                Image(systemName: "bubble.left.fill")
            } else {
                switch top?.kind {
                case .callBack?:
                    Image(systemName: "phone.arrow.up.right.fill")
                case .live?:
                    Image(systemName: "waveform")
                case .queued?:
                    Image(systemName: "bell.fill")
                case .ringsAt?, .paused?, .working?, .background?:
                    Clock(row: top!).font(.callout.monospacedDigit().weight(.semibold))
                default:
                    Text("\(state.alive)").font(.callout.monospacedDigit().weight(.semibold))
                }
            }
        }
        .foregroundStyle(color)
        .frame(maxWidth: 52)
        .accessibilityLabel(state.ask.map { "\($0.label) fragt" } ?? top.map { "\($0.label), \($0.title)" } ?? Copy.alive(state.alive))
    }
}

/// A row's timer, counted by the system: up since a state began, down to a pause's end or the
/// next ring. Nothing for states without a time.
private struct Clock: View {
    let row: ParleyAttributes.Row

    var body: some View {
        switch row.kind {
        case .working(let since), .background(let since):
            Text(timerInterval: since...Date.distantFuture, countsDown: false)
                .multilineTextAlignment(.trailing)
        case .paused(let end), .ringsAt(let end):
            Text(timerInterval: Date()...max(Date(), end), countsDown: true)
                .multilineTextAlignment(.trailing)
        default:
            EmptyView()
        }
    }
}

/// Parley's orb, still: a glow, the core and one orbit — the island can't animate it.
struct Orb: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [color.opacity(0.55), color.opacity(0.12), .clear],
                                     center: .center, startRadius: 0, endRadius: size / 2))
            Ellipse()
                .stroke(color.opacity(0.85), lineWidth: max(1, size * 0.06))
                .frame(width: size * 0.86, height: size * 0.34)
                .rotationEffect(.degrees(-24))
            Circle()
                .fill(RadialGradient(colors: [.white, color], center: .center, startRadius: 0, endRadius: size * 0.2))
                .frame(width: size * 0.4, height: size * 0.4)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Words, colours, links

enum Copy {
    static func alive(_ n: Int) -> String { n == 1 ? "1 Session aktiv" : "\(n) Sessions aktiv" }

    static func callSymbol(_ top: ParleyAttributes.Row?) -> String {
        if case .callBack? = top?.kind { return "phone.arrow.up.right.fill" }
        return "phone.fill"
    }

    static func callTitle(_ top: ParleyAttributes.Row?) -> LocalizedStringKey {
        switch top?.kind {
        case .callBack?: "Zurückrufen"
        case .ringsAt?: "Jetzt anrufen"
        default: "Parley anrufen"
        }
    }
}

enum Paint {
    static func color(_ role: StateColors.Role, _ colors: StateColors, dark: Bool) -> Color {
        Color(rgb: colors.hex(role, dark: dark))
    }

    /// Black or white on that colour (WCAG luminance), as the app's buttons do.
    static func onColor(_ role: StateColors.Role, _ colors: StateColors, dark: Bool) -> Color {
        let c = colors.hex(role, dark: dark)
        func lin(_ v: UInt32) -> Double {
            let x = Double(v & 0xFF) / 255
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        let l = 0.2126 * lin(c >> 16) + 0.7152 * lin(c >> 8) + 0.0722 * lin(c)
        return l > 0.5 ? .black : .white
    }
}

enum Link {
    /// Tapping the activity opens the session it is about.
    static func session(_ id: String?) -> URL? {
        guard let id, var c = URLComponents(string: "parley://session") else { return nil }
        c.queryItems = [URLQueryItem(name: "id", value: id)]
        return c.url
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

#Preview("Island", as: .dynamicIsland(.expanded), using: ParleyAttributes()) {
    ParleyLiveActivity()
} contentStates: {
    ParleyAttributes.ContentState.demo()
    ParleyAttributes.ContentState.demoAsk()
}

#Preview("Lock Screen", as: .content, using: ParleyAttributes()) {
    ParleyLiveActivity()
} contentStates: {
    ParleyAttributes.ContentState.demo()
    ParleyAttributes.ContentState.demoAsk()
}
