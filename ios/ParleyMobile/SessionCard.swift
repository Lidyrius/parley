import SwiftUI

/// One session tile (design C): ring, name, "state · time"; details behind a chevron;
/// "Fortsetzen" as the tile's one action.
struct SessionCard: View {
    let session: Session
    let skew: Double
    let canResume: Bool
    /// Stretch to the row's height (tidy rows); off next to an expanded tile.
    var fillsRow = true
    @Binding var isExpanded: Bool
    let onResume: () -> Void
    @State private var resumeTaps = 0
    @ScaledMetric(relativeTo: .headline) private var ringSize: CGFloat = 40

    var body: some View {
        // The timers tick once a second on the host's clock.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let at = context.date.ms + skew
            VStack(alignment: .leading, spacing: 12) {
                header(at)
                if isExpanded { details(at).transition(.opacity.combined(with: .move(edge: .top))) }
                if session.canResume { resumeButton }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: fillsRow ? .infinity : nil, alignment: .topLeading)
        .background(background)
        .sensoryFeedback(.impact(weight: .medium), trigger: resumeTaps)
    }

    private var isOff: Bool { session.state == .stopped }

    private func header(_ at: Double) -> some View {
        Button {
            guard session.stats != nil else { return }
            withAnimation(.snappy) { isExpanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    RingView(session: session, skew: skew, size: ringSize)
                    Spacer(minLength: 0)
                    if session.stats != nil {
                        Image(systemName: "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .padding(4)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.name)
                        .font(.headline)
                        .foregroundStyle(isOff ? .secondary : .primary)
                        .lineLimit(1)
                    // "state · time" on one line like the mod; on a narrow tile the time drops below.
                    ViewThatFits(in: .horizontal) {
                        Text(stateText + .run(" · " + Fmt.timer(session, at: at), .secondary))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(stateText)
                            Text(Fmt.timer(session, at: at)).foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                    .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.name), \(Fmt.stateLabel(session)), \(Fmt.timer(session, at: at))")
        .accessibilityHint(session.stats == nil ? "" : isExpanded ? "Details ausblenden" : "Details anzeigen")
    }

    private var stateText: AttributedString {
        .run(Fmt.stateLabel(session), isOff ? .secondary : session.state.ink)
    }

    private func details(_ at: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.bottom, 2)
            ForEach(Fmt.facts(session, at: at), id: \.label) { fact in
                HStack(alignment: .firstTextBaseline) {
                    Text(fact.label).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(fact.value).monospacedDigit().multilineTextAlignment(.trailing)
                }
            }
            if !session.tasks.isEmpty {
                Text(session.tasks.map { "◍ " + $0.description }.joined(separator: "\n"))
                    .foregroundStyle(SessionState.background.ink)
                    .padding(.top, 2)
            }
            if let line = session.stats?.lastLine, !line.isEmpty {
                Text("„\(line)“")
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .padding(.top, 2)
            }
        }
        .font(.footnote)
    }

    private var resumeButton: some View {
        Button {
            resumeTaps += 1
            onResume()
        } label: {
            Label("Fortsetzen", systemImage: "play.fill")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.claude)
        .disabled(!canResume)
    }

    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return shape
            .fill(Theme.card)
            .overlay(shape.fill(Theme.claude.opacity(session.voice ? 0.10 : 0)))
            .overlay(shape.strokeBorder(session.voice ? Theme.claude.opacity(0.55) : Theme.stroke, lineWidth: 1))
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
