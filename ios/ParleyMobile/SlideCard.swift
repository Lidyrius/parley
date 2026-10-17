import Charts
import SwiftUI

/// One slide in the call screen (docs/CALL-SLIDES.md): a screenshot, a chart, a big number or a
/// short card — shown while Parley talks about it. Each kind comes in calmly: bars and lines
/// grow, the pie fades in, numbers count up, images and text fade in.
struct SlideCard: View {
    let slide: Slide
    let image: UIImage?
    var index = 0
    var count = 1
    var onZoom: (UIImage) -> Void = { _ in }
    @State private var shown = false

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
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)   // stays inside the pager's page padding
        }
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Theme.stroke))
        .onAppear {
            withAnimation(.easeOut(duration: 0.55).delay(0.05)) { shown = true }
        }
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
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
            MetricText(metric: slide.metric ?? "", shown: shown)
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
        let grow = shown ? 1.0 : 0.0
        switch slide.chart {
        case "pie":
            // Fixed colours per slice and our own legend (name, value, share) — the chart's own
            // labels can't be trusted on small slices.
            let total = max(1, points.map(\.value).reduce(0, +))
            HStack(alignment: .center, spacing: 18) {
                Chart(points) { p in
                    SectorMark(angle: .value("Wert", p.value), innerRadius: .ratio(0.6), angularInset: 1.5)
                        .foregroundStyle(Self.palette[p.id % Self.palette.count])
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
                }
            }
            .opacity(grow)
        case "line":
            Chart(points) { p in
                AreaMark(x: .value("Name", p.label), y: .value("Wert", p.value * grow))
                    .foregroundStyle(LinearGradient(colors: [Theme.claude.opacity(0.35), Theme.claude.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Name", p.label), y: .value("Wert", p.value * grow))
                    .foregroundStyle(Theme.claude)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                    .interpolationMethod(.catmullRom)
                PointMark(x: .value("Name", p.label), y: .value("Wert", p.value * grow))
                    .foregroundStyle(Theme.claude)
                    .annotation(position: .top) {
                        Text(Self.format(p.value) + unit).font(.caption2).foregroundStyle(.secondary).opacity(grow)
                    }
            }
            .chartYScale(domain: 0...top)
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

    private static let palette: [Color] = [Color(hex: 0xD97757), Color(hex: 0x5B8DEF), Color(hex: 0x4EBA65),
                                           Color(hex: 0xD9A43B), Color(hex: 0x9B87F5), Color(hex: 0x8B8A85)]

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
                let value = shown ? number : 0
                Text(SlideCard.format(number.rounded() == number ? value.rounded() : value) + rest)
                    .contentTransition(.numericText(value: value))
            } else {
                Text(metric).opacity(shown ? 1 : 0).scaleEffect(shown ? 1 : 0.9, anchor: .leading)
            }
        }
        .font(.system(size: 60, weight: .bold, design: .rounded))
        .foregroundStyle(Theme.claude.gradient)
        .minimumScaleFactor(0.5)
        .lineLimit(1)
    }

    static func split(_ s: String) -> (Double?, String) {
        guard let m = s.firstMatch(of: /^\s*(\d+(?:[.,]\d+)?)(.*)$/) else { return (nil, s) }
        return (Double(m.1.replacingOccurrences(of: ",", with: ".")), String(m.2))
    }
}
