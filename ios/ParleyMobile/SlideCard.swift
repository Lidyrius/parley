import Charts
import SwiftUI

/// One slide in the call screen (docs/CALL-SLIDES.md): a screenshot, a chart, a big number or a
/// short card — shown while Parley talks about it. Each kind comes in calmly once its card is the
/// current one: images and text fade in; bars and lines grow and the pie fills clockwise, slowly
/// enough to watch; numbers count up.
struct SlideCard: View {
    let slide: Slide
    let image: UIImage?
    var index = 0
    var count = 1
    /// The deck's current card: it builds up when it becomes current (neighbours wait, unbuilt).
    var active = true
    var onZoom: (UIImage) -> Void = { _ in }
    @State private var shown = false   // fades: text, images, labels
    @State private var grown = false   // builds: bars, lines, the pie's sweep, the number

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Theme.card)
                .overlay(alignment: .topLeading) {
                    // A warm glow from the corner, like the call screen's backdrop.
                    RadialGradient(colors: [Theme.claude.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                }
                .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
        }
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Theme.stroke))
        .onAppear { if active { reveal() } }
        .onChange(of: active) { _, now in if now { reveal() } }
        .accessibilityElement(children: .combine)
    }

    private func reveal() {
        guard !shown else { return }
        withAnimation(.easeOut(duration: 0.7).delay(0.1)) { shown = true }
        withAnimation(.easeInOut(duration: 1.8).delay(0.35)) { grown = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.claude.gradient))
            Text(slide.title ?? kindName).font(.headline).lineLimit(2)
            Spacer(minLength: 8)
            if count > 1 {
                Text("\(index + 1) / \(count)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.userBubble))
            }
        }
    }

    private var icon: String {
        switch slide.kind {
        case "image": "photo"
        case "chart": slide.chart == "pie" ? "chart.pie.fill" : slide.chart == "line" ? "chart.xyaxis.line" : "chart.bar.fill"
        case "metric": "number"
        default: "text.alignleft"
        }
    }

    private var kindName: String {
        switch slide.kind {
        case "image": "Bild"
        case "chart": "Diagramm"
        case "metric": "Kennzahl"
        default: "Notiz"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch slide.kind {
        case "image":
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.stroke))
                    .frame(maxHeight: 250)
                    .frame(maxWidth: .infinity)
                    .opacity(shown ? 1 : 0)
                    .onTapGesture { onZoom(image) }
                    .accessibilityAddTraits(.isButton)
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.userBubble)
                    .frame(height: 170)
                    .overlay { ProgressView() }
            }
        case "chart":
            chart.frame(height: slide.chart == "pie" ? 170 : 190)
        case "metric":
            MetricText(metric: slide.metric ?? "", shown: grown)
            if let note = slide.note {
                Text(note).font(.title3).foregroundStyle(.secondary)
                    .opacity(shown ? 1 : 0)
            }
        default:
            Text(Markdown.inline(slide.text ?? ""))
                .font(.title3)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 4)
        }
    }

    private struct Point: Identifiable { let id: Int; let label: String; let value: Double }

    private var points: [Point] {
        let values = slide.values ?? []
        let labels = slide.labels ?? []
        return values.enumerated().map { Point(id: $0.offset, label: $0.offset < labels.count ? labels[$0.offset] : "\($0.offset + 1)", value: $0.element) }
    }

    @ViewBuilder
    private var chart: some View {
        let unit = slide.unit.map { " " + $0 } ?? ""
        let top = max(1, (points.map(\.value).max() ?? 1) * 1.18)   // fixed scale: the marks grow, not the axis
        let grow = grown ? 1.0 : 0.0
        switch slide.chart {
        case "pie":
            // Fixed colours per slice and our own legend (name, value, share) — the chart's own
            // labels can't be trusted on small slices.
            let total = max(1, points.map(\.value).reduce(0, +))
            // An invisible last slice holds what is not yet filled: the ring sweeps round from the top.
            let rest = Point(id: -1, label: "", value: total * (1 - grow) + 0.0001)
            HStack(alignment: .center, spacing: 18) {
                Chart(points + [rest]) { p in
                    SectorMark(angle: .value("Wert", p.value), innerRadius: .ratio(0.6), angularInset: p.id < 0 ? 0 : 1.5)
                        .foregroundStyle(p.id < 0 ? Color.clear : Self.palette[p.id % Self.palette.count])
                        .cornerRadius(4)
                }
                .chartLegend(.hidden)
                .frame(width: 150, height: 150)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(points) { p in
                        HStack(spacing: 8) {
                            Circle().fill(Self.palette[p.id % Self.palette.count]).frame(width: 9, height: 9)
                            Text(p.label).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(Self.share(p.value / total)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                    .opacity(shown ? 1 : 0)
                }
            }
        case "line":
            LineChart(labels: points.map(\.label), values: points.map(\.value), unit: unit,
                      reveal: Appearance.shared.lineReveal, progress: grow)
        default:
            Chart(points) { p in
                BarMark(x: .value("Name", p.label), y: .value("Wert", p.value * grow))
                    .foregroundStyle(LinearGradient(colors: [Theme.claude.opacity(0.75), Theme.claude], startPoint: .bottom, endPoint: .top))
                    .cornerRadius(7)
                    .annotation(position: .top) {
                        Text(Self.format(p.value) + unit).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).opacity(grow)
                    }
            }
            .chartYScale(domain: 0...top)
        }
    }

    private static var palette: [Color] { Theme.palette.series.map(\.color) }

    /// "38 %", "<1 %".
    static func share(_ f: Double) -> String {
        let p = f * 100
        return p < 1 ? "<1 %" : "\(Int(p.rounded())) %"
    }

    static func format(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : v.formatted(.number.precision(.fractionLength(0...2)))
    }
}

/// "244" / "24 / 24" / "98 %": the leading number counts up from 0, the rest stays.
private struct MetricText: View {
    let metric: String
    let shown: Bool

    var body: some View {
        let (number, rest) = Self.split(metric)
        Group {
            if let number {
                let raw = String(metric.dropLast(rest.count)).trimmingCharacters(in: .whitespaces)
                HStack(spacing: 0) {
                    // The final number holds the width, so the count never pushes " / 80" around.
                    ZStack(alignment: .trailing) {
                        Text(raw).hidden()
                        CountUp(value: shown ? number : 0, like: raw)
                    }
                    Text(rest)
                }
            } else {
                Text(metric).opacity(shown ? 1 : 0).scaleEffect(shown ? 1 : 0.9, anchor: .leading)
            }
        }
        .font(.system(size: 60, weight: .bold, design: .rounded).monospacedDigit())
        .foregroundStyle(Theme.claude.gradient)
        .minimumScaleFactor(0.5)
        .lineLimit(1)
    }

    static func split(_ s: String) -> (Double?, String) {
        guard let m = s.firstMatch(of: /^\s*(\d+(?:[.,]\d+)?)(.*)$/) else { return (nil, s) }
        return (Double(m.1.replacingOccurrences(of: ",", with: ".")), String(m.2))
    }
}

/// A number counting from 0 to its value while animated, written like `like` ("80", "98,5").
struct CountUp: View, Animatable {
    var value: Double
    let like: String
    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View { Text(Self.text(value, like: like)) }

    nonisolated static func text(_ v: Double, like: String) -> String {
        guard let sep = like.firstIndex(where: { $0 == "," || $0 == "." }) else { return String(Int(v.rounded())) }
        let decimals = like.distance(from: sep, to: like.endIndex) - 1
        return String(format: "%.\(decimals)f", v).replacingOccurrences(of: ".", with: String(like[sep]))
    }
}
