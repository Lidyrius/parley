import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The Parley Live Activity: the Dynamic Island (compact, minimal, expanded), the Lock Screen and
/// — as the small family — the Apple Watch Smart Stack and CarPlay. Timers count by themselves;
/// the host pushes only when a state changes.
struct ParleyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ParleyAttributes.self) { context in
            LockScreenView(state: context.state, stale: context.isStale)
                .widgetURL(Link.session(context.state.top))
        } dynamicIsland: { context in
            let state = context.state
            let colors = SharedState.colors
            let tint = Paint.color(state.top?.role ?? .idle, colors, dark: true)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Orb(color: tint, size: 32)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Parley").font(.headline)
                            Text(Copy.alive(state.alive)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // The call, one tap away: round, so the sessions keep the room below.
                    Button(intent: CallParleyIntent()) {
                        Image(systemName: Copy.callSymbol(state.top))
                            .font(.headline)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Paint.color(.accent, colors, dark: true)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Paint.onColor(.accent, colors, dark: true))
                    .accessibilityLabel(Text(Copy.callTitle(state.top)))
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Expanded(state: state, colors: colors, dark: true, island: true)
                }
            } compactLeading: {
                Orb(color: tint, size: 22)
            } compactTrailing: {
                Badge(state: state, colors: colors)
            } minimal: {
                Orb(color: tint, size: 22)
            }
            .keylineTint(tint)
            .widgetURL(Link.session(state.top))
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Orb(color: Paint.color(state.top?.role ?? .idle, colors, dark: dark), size: 24)
                    Text("Parley").font(.headline)
                    Spacer()
                    Text(stale ? "Mac nicht erreichbar" : Copy.alive(state.alive))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Expanded(state: state, colors: colors, dark: dark)
            }
            .padding(14)
            .opacity(stale ? 0.6 : 1)
        }
    }
}

/// Watch Smart Stack and CarPlay: the most urgent session only.
private struct Small: View {
    let state: ParleyAttributes.ContentState
    let colors: StateColors
    let dark: Bool

    var body: some View {
        HStack(spacing: 8) {
            Orb(color: Paint.color(state.top?.role ?? .idle, colors, dark: dark), size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.top?.label ?? "Parley").font(.headline).lineLimit(1)
                if let top = state.top {
                    HStack(spacing: 4) {
                        Text(top.title)
                        Clock(row: top)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                } else {
                    Text(Copy.alive(state.alive)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }
}

// MARK: - Shared parts

/// The expanded Island's body and the Lock Screen's: the three most urgent sessions, Parley's last
/// line, and (Lock Screen) the call button.
private struct Expanded: View {
    let state: ParleyAttributes.ContentState
    let colors: StateColors
    let dark: Bool
    var island = false

    var body: some View {
        VStack(alignment: .leading, spacing: island ? 4 : 6) {
            ForEach(state.sessions.prefix(3)) { row in
                SessionRow(row: row, color: Paint.color(row.role, colors, dark: dark))
            }
            if let line = state.line, !line.isEmpty {
                Text("„\(line)“")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(island ? 1 : 2)
                    .padding(.leading, 16)   // under the names, clear of the Island's corner
            }
            if !island { callButton }
        }
    }

    /// The Lock Screen's call button (the Island has its own, round, at the top).
    private var callButton: some View {
        Button(intent: CallParleyIntent()) {
                Label(Copy.callTitle(state.top), systemImage: "phone.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Paint.onColor(.accent, colors, dark: dark))
        .background(Capsule().fill(Paint.color(.accent, colors, dark: dark)))
        .padding(.top, 4)
    }
}

private struct SessionRow: View {
    let row: ParleyAttributes.Row
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(row.label).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(row.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Clock(row: row)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(row.wantsSir ? color : .secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The compact Island's right side: what the most urgent session needs, in a glance.
private struct Badge: View {
    let state: ParleyAttributes.ContentState
    let colors: StateColors

    var body: some View {
        let top = state.top
        let color = Paint.color(top?.role ?? .idle, colors, dark: true)
        Group {
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
        .foregroundStyle(color)
        .frame(maxWidth: 52)
        .accessibilityLabel(top.map { "\($0.label), \($0.title)" } ?? Copy.alive(state.alive))
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
    static func alive(_ n: Int) -> String { n == 1 ? "1 aktiv" : "\(n) aktiv" }

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
    /// Tapping the activity opens the session it shows first.
    static func session(_ row: ParleyAttributes.Row?) -> URL? {
        guard let row, var c = URLComponents(string: "parley://session") else { return nil }
        c.queryItems = [URLQueryItem(name: "id", value: row.id)]
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
}

#Preview("Lock Screen", as: .content, using: ParleyAttributes()) {
    ParleyLiveActivity()
} contentStates: {
    ParleyAttributes.ContentState.demo()
}
