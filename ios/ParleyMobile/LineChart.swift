import SwiftUI

/// How a line chart builds up on its slide (Einstellungen → Darstellung → Diagramm-Aufbau).
enum LineReveal: String, CaseIterable, Identifiable, Sendable {
    case draw, curtain, wave, unfold, focus

    var id: String { rawValue }

    var name: String {
        switch self {
        case .draw: "Zeichnen"
        case .curtain: "Vorhang"
        case .wave: "Welle"
        case .unfold: "Entfalten"
        case .focus: "Fokus"
        }
    }

    var note: String {
        switch self {
        case .draw: "Ein Stift zieht die Linie von links nach rechts, die Fläche folgt"
        case .curtain: "Ein weicher Vorhang gibt das Diagramm von links frei"
        case .wave: "Die Punkte steigen nacheinander auf, wie eine Welle"
        case .unfold: "Die Linie liegt erst flach und faltet sich in ihre Form"
        case .focus: "Das Diagramm wird aus der Unschärfe scharf"
        }
    }
}

/// A line chart drawn by hand (Swift Charts can't draw a line progressively): a smooth line over
/// a soft area, the values above the points, the labels below. `progress` runs 0 → 1 under an
/// animation and builds the chart in the chosen `reveal` style.
struct LineChart: View, Animatable {
    let labels: [String]
    let values: [Double]
    var unit = ""
    var reveal: LineReveal = .draw
    var progress: Double
    var compact = false   // the settings' preview: no texts

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        GeometryReader { geo in
            let plot = CGRect(x: 14, y: compact ? 4 : 22, width: geo.size.width - 28,
                              height: geo.size.height - (compact ? 8 : 46))
            let shown = Self.shown(values, reveal: reveal, progress: progress)
            let pts = Self.points(shown, top: Self.top(values), in: plot)
            let line = Self.smooth(pts)
            let tip = line.trimmedPath(from: 0, to: max(0.001, progress)).currentPoint ?? plot.origin
            let p = progress

            ZStack(alignment: .topLeading) {
                // Faint guides.
                Path { g in
                    for k in 0...2 {
                        let y = plot.minY + plot.height * CGFloat(k) / 2
                        g.move(to: CGPoint(x: plot.minX, y: y)); g.addLine(to: CGPoint(x: plot.maxX, y: y))
                    }
                }
                .stroke(Color.primary.opacity(0.07), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

                Group {
                    Self.area(line, pts, baseline: plot.maxY)
                        .fill(LinearGradient(colors: [Theme.claude.opacity(0.32), Theme.claude.opacity(0.02)],
                                             startPoint: .top, endPoint: .bottom))
                        .mask(alignment: .leading) {
                            // Drawing: the area follows the pen.
                            Rectangle().frame(width: reveal == .draw ? max(0, tip.x) : geo.size.width)
                        }
                    (reveal == .draw ? line.trimmedPath(from: 0, to: p) : line)
                        .stroke(Theme.claude, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    ForEach(pts.indices, id: \.self) { i in
                        let o = Self.pointOpacity(i, count: pts.count, x: pts[i].x, tip: tip.x, reveal: reveal, progress: p)
                        Circle().fill(Theme.claude)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Theme.card, lineWidth: 2))
                            .scaleEffect(0.4 + 0.6 * o)
                            .opacity(o)
                            .position(pts[i])
                        if !compact {
                            Text(SlideCard.format(values[i]) + unit)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .opacity(o)
                                .position(x: pts[i].x, y: pts[i].y - 13)
                        }
                    }
                    if reveal == .draw, p > 0.001, p < 0.999 {
                        // The pen's tip.
                        Circle().fill(Theme.claude).frame(width: 11, height: 11)
                            .shadow(color: Theme.claude.opacity(0.7), radius: 6)
                            .position(tip)
                    }
                }
                .mask {
                    if reveal == .curtain {
                        LinearGradient(stops: [.init(color: .black, location: max(0, p * 1.25 - 0.25)),
                                               .init(color: .clear, location: min(1, p * 1.25))],
                                       startPoint: .leading, endPoint: .trailing)
                    } else {
                        Rectangle()
                    }
                }
                .opacity(reveal == .focus ? p : 1)
                .blur(radius: reveal == .focus ? (1 - p) * 10 : 0)
                .scaleEffect(reveal == .focus ? 0.94 + 0.06 * p : 1)

                if !compact {
                    ForEach(labels.indices.filter { $0 < pts.count }, id: \.self) { i in
                        Text(labels[i])
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .position(x: pts[i].x, y: plot.maxY + 14)
                    }
                    .opacity(min(1, p * 3))
                }
            }
        }
    }

    /// The axis' top: a little headroom over the largest value (fixed: the line builds, not the axis).
    nonisolated static func top(_ values: [Double]) -> Double { max(1, (values.max() ?? 1) * 1.18) }

    /// The values as shown at `progress`: the wave lifts them one after another from the
    /// baseline, unfolding grows them out of their mean; the other styles show them as they are.
    nonisolated static func shown(_ values: [Double], reveal: LineReveal, progress p: Double) -> [Double] {
        let n = values.count
        switch reveal {
        case .wave:
            let step = n > 1 ? 0.55 / Double(n - 1) : 0   // each point starts a little after the last
            return values.enumerated().map { i, v in v * backOut(clamp((p - Double(i) * step) / 0.45)) }
        case .unfold:
            let mean = values.reduce(0, +) / Double(max(1, n))
            return values.map { mean + ($0 - mean) * ease(p) }
        default:
            return values
        }
    }

    nonisolated static func points(_ values: [Double], top: Double, in plot: CGRect) -> [CGPoint] {
        let n = values.count
        return values.enumerated().map { i, v in
            CGPoint(x: n > 1 ? plot.minX + plot.width * CGFloat(i) / CGFloat(n - 1) : plot.midX,
                    y: plot.maxY - plot.height * CGFloat(min(max(v / top, 0), 1.05)))
        }
    }

    /// A Catmull-Rom curve through the points (as Swift Charts' `.catmullRom`).
    nonisolated static func smooth(_ p: [CGPoint]) -> Path {
        Path { path in
            guard let first = p.first else { return }
            path.move(to: first)
            guard p.count > 1 else { return }
            for i in 0..<(p.count - 1) {
                let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
                path.addCurve(to: p2,
                              control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                              control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
            }
        }
    }

    nonisolated static func area(_ line: Path, _ p: [CGPoint], baseline: CGFloat) -> Path {
        var a = line
        guard let first = p.first, let last = p.last else { return a }
        a.addLine(to: CGPoint(x: last.x, y: baseline))
        a.addLine(to: CGPoint(x: first.x, y: baseline))
        a.closeSubpath()
        return a
    }

    /// A point (and its value) shows once the pen passed it, the curtain uncovered it, or its
    /// part of the wave has risen; unfolding and focus show them all along.
    nonisolated static func pointOpacity(_ i: Int, count n: Int, x: CGFloat, tip: CGFloat, reveal: LineReveal, progress p: Double) -> Double {
        switch reveal {
        case .draw: return x <= tip + 0.5 ? 1 : 0
        case .curtain: return clamp((p * 1.25 - Double(i) / Double(max(1, n - 1))) * 4)
        case .wave:
            let step = n > 1 ? 0.55 / Double(n - 1) : 0
            return clamp((p - Double(i) * step) / 0.2)
        case .unfold: return clamp(p * 1.6 - 0.3)
        case .focus: return 1
        }
    }

    nonisolated static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    nonisolated static func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }
    /// Ease out with a small overshoot: the wave's points settle with a little bounce.
    nonisolated static func backOut(_ t: Double) -> Double {
        let c = 1.4, u = t - 1
        return 1 + (c + 1) * u * u * u + c * u * u
    }
}
