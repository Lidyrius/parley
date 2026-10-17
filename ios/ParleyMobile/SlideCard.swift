import Charts
import SwiftUI

/// One slide in the call screen (docs/CALL-SLIDES.md): a screenshot, a chart, a big number or a
/// short card — shown while Parley talks about it.
struct SlideCard: View {
    let slide: Slide
    let image: UIImage?
    var onZoom: (UIImage) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = slide.title {
                Text(title).font(.headline).lineLimit(2)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Theme.stroke))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        switch slide.kind {
        case "image":
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(maxHeight: 300)
                    .frame(maxWidth: .infinity)
                    .onTapGesture { onZoom(image) }
                    .accessibilityAddTraits(.isButton)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            }
        case "chart":
            chart.frame(height: 200)
        case "metric":
            VStack(alignment: .leading, spacing: 4) {
                Text(slide.metric ?? "")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.claude)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                if let note = slide.note { Text(note).font(.title3).foregroundStyle(.secondary) }
            }
        default:
            Text(Markdown.inline(slide.text ?? "")).font(.title3).fixedSize(horizontal: false, vertical: true)
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
        switch slide.chart {
        case "pie":
            Chart(points) { p in
                SectorMark(angle: .value("Wert", p.value), innerRadius: .ratio(0.55), angularInset: 1.5)
                    .foregroundStyle(by: .value("Name", p.label))
                    .cornerRadius(4)
            }
            .chartLegend(position: .trailing, alignment: .center)
        case "line":
            Chart(points) { p in
                LineMark(x: .value("Name", p.label), y: .value("Wert", p.value))
                    .foregroundStyle(Theme.claude)
                    .interpolationMethod(.catmullRom)
                PointMark(x: .value("Name", p.label), y: .value("Wert", p.value))
                    .foregroundStyle(Theme.claude)
                    .annotation(position: .top) { Text(Self.format(p.value) + unit).font(.caption2).foregroundStyle(.secondary) }
            }
        default:
            Chart(points) { p in
                BarMark(x: .value("Name", p.label), y: .value("Wert", p.value))
                    .foregroundStyle(Theme.claude.gradient)
                    .cornerRadius(6)
                    .annotation(position: .top) { Text(Self.format(p.value) + unit).font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }

    static func format(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : v.formatted(.number.precision(.fractionLength(0...2)))
    }
}
