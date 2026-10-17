import AppIntents
import SwiftUI
import WidgetKit

/// The Parley widget: your sessions at a glance on the Home Screen (small, medium, large — also
/// in StandBy) and the Lock Screen (circular, rectangular, inline). It shows what the app last
/// heard from the Mac; timers count by themselves, and an old picture says when it was taken.
struct SessionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedState.widgetKind, provider: Provider()) { entry in
            SessionsView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Parley")
        .description("Deine Sessions auf einen Blick – was arbeitet und was auf dich wartet.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, snap: .demo()) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, snap: context.isPreview ? .demo() : SharedState.snapshot ?? .demo()))
    }

    /// One entry; the app reloads when the overview changes. A late reload re-reads the App Group
    /// (and lets an old picture show its age).
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let now = Date.now
        completion(Timeline(entries: [Entry(date: now, snap: SharedState.snapshot)], policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

private struct SessionsView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let colors = SharedState.colors
        let dark = scheme == .dark
        if let snap = entry.snap {
            switch family {
            case .systemSmall: SmallView(snap: snap, now: entry.date, colors: colors, dark: dark)
            case .systemMedium: MediumView(snap: snap, now: entry.date, colors: colors, dark: dark)
            case .systemLarge: LargeView(snap: snap, now: entry.date, colors: colors, dark: dark)
            case .accessoryCircular: CircularView(snap: snap)
            case .accessoryRectangular: RectangularView(snap: snap)
            default: InlineView(snap: snap)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Parley").font(.headline)
                Text("Öffne Parley einmal, dann erscheinen hier deine Sessions.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Home Screen

/// The most urgent session, large: name, state in its colour, the timer.
private struct Lead: View {
    let row: ParleyAttributes.Row?
    let colors: StateColors
    let dark: Bool
    var big = false

    var body: some View {
        if let row {
            let color = Paint.color(row.role, colors, dark: dark)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label).font(big ? .title3.weight(.semibold) : .headline).lineLimit(1)
                Text(row.title).font(.subheadline).foregroundStyle(color).lineLimit(2)
                Clock(row: row)
                    .font((big ? Font.title : .title2).monospacedDigit().weight(.semibold))
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Alles ruhig").font(.headline)
                Text("Keine Session aktiv").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// "Parley", how many run, and — if the picture is old — when it was taken.
private struct Header: View {
    let snap: WidgetSnapshot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Parley").font(.subheadline.weight(.semibold))
            Text(snap.isStale(at: now) ? "Stand \(snap.at.formatted(date: .omitted, time: .shortened))" : Copy.alive(snap.alive))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SmallView: View {
    let snap: WidgetSnapshot
    let now: Date
    let colors: StateColors
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(snap: snap, now: now)
            Spacer(minLength: 6)
            Lead(row: snap.top, colors: colors, dark: dark)
            Spacer(minLength: 6)
            if snap.alive > 1 {
                HStack(spacing: 4) {
                    ForEach(snap.sessions.dropFirst().prefix(4)) { row in
                        Circle().fill(Paint.color(row.role, colors, dark: dark)).frame(width: 7, height: 7)
                    }
                    Text(snap.alive == 2 ? "1 weitere" : "\(snap.alive - 1) weitere").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(DeepLink.session(snap.top?.id))
    }
}

private struct MediumView: View {
    let snap: WidgetSnapshot
    let now: Date
    let colors: StateColors
    let dark: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Header(snap: snap, now: now)
                Spacer(minLength: 6)
                Lead(row: snap.top, colors: colors, dark: dark)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 0) {
                CallButton(colors: colors, dark: dark)
                Spacer(minLength: 6)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(snap.sessions.dropFirst().prefix(3)) { row in
                        Line(row: row, color: Paint.color(row.role, colors, dark: dark), compact: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .widgetURL(DeepLink.session(snap.top?.id))
    }
}

private struct LargeView: View {
    let snap: WidgetSnapshot
    let now: Date
    let colors: StateColors
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Header(snap: snap, now: now)
                Spacer()
                CallButton(colors: colors, dark: dark)
            }
            Lead(row: snap.top, colors: colors, dark: dark, big: true)
            if let line = snap.line, snap.from == snap.top?.label, !line.isEmpty {
                Text("„\(line)“").font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                ForEach(snap.sessions.dropFirst().prefix(4)) { row in
                    Link(destination: DeepLink.session(row.id) ?? URL(string: "parley://")!) {
                        Line(row: row, color: Paint.color(row.role, colors, dark: dark))
                    }
                }
            }
            Spacer(minLength: 0)
            if let today = Today(snap) { Text(today).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// "$13.61 · 65 Updates · 42 % 5-h-Limit".
    private func Today(_ s: WidgetSnapshot) -> String? {
        var parts: [String] = []
        if let c = s.cost { parts.append(String(format: "$%.2f heute", c)) }
        if let u = s.updates { parts.append("\(u) Updates") }
        if let l = s.limit { parts.append("\(Int(l.rounded())) % 5-h-Limit") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A session in a list: its colour, name, state and timer.
private struct Line: View {
    let row: ParleyAttributes.Row
    let color: Color
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.label).font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold)).lineLimit(1)
                if !compact { Text(row.title).font(.caption).foregroundStyle(color).lineLimit(1) }
            }
            Spacer(minLength: 4)
            Clock(row: row)
                .font((compact ? Font.caption : .subheadline).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CallButton: View {
    let colors: StateColors
    let dark: Bool

    var body: some View {
        Button(intent: CallParleyIntent()) {
            Image(systemName: "phone.fill")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Paint.color(.accent, colors, dark: dark)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Paint.onColor(.accent, colors, dark: dark))
        .accessibilityLabel("Parley anrufen")
    }
}

// MARK: - Lock Screen

/// The 5-h limit as a ring when the Mac reports it, else how many sessions run.
private struct CircularView: View {
    let snap: WidgetSnapshot

    var body: some View {
        if let limit = snap.limit {
            Gauge(value: min(100, max(0, limit)), in: 0...100) {
                Text("5 h")
            } currentValueLabel: {
                Text("\(Int(limit.rounded()))")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .accessibilityLabel("5-Stunden-Limit \(Int(limit.rounded())) Prozent")
        } else {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: -2) {
                    Text("\(snap.alive)").font(.title2.weight(.semibold))
                    Text("aktiv").font(.caption2)
                }
            }
        }
    }
}

private struct RectangularView: View {
    let snap: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Parley · \(snap.alive) aktiv").font(.headline).widgetAccentable()
            if let top = snap.top {
                Text("\(top.label) \(top.title)").font(.caption).lineLimit(1)
                Clock(row: top).font(.caption.monospacedDigit())
            } else {
                Text("Alles ruhig").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InlineView: View {
    let snap: WidgetSnapshot

    var body: some View {
        if let top = snap.top, top.wantsSir {
            Text("Parley: \(top.label) \(top.title)")
        } else {
            Text("Parley: \(snap.alive) aktiv" + (snap.limit.map { " · \(Int($0.rounded())) % Limit" } ?? ""))
        }
    }
}

#Preview("Small", as: .systemSmall) { SessionsWidget() } timeline: { Entry(date: .now, snap: .demo()) }
#Preview("Medium", as: .systemMedium) { SessionsWidget() } timeline: { Entry(date: .now, snap: .demo()) }
#Preview("Large", as: .systemLarge) { SessionsWidget() } timeline: { Entry(date: .now, snap: .demo()) }
#Preview("Rectangular", as: .accessoryRectangular) { SessionsWidget() } timeline: { Entry(date: .now, snap: .demo()) }
