import SwiftUI

/// How an incoming call moves around the caller's ring (Einstellungen → Darstellung → Anruf).
/// All of them keep a phone's ring-ring rhythm: two beats, then a pause.
enum RingStyle: String, CaseIterable, Identifiable, Sendable {
    case ripples, breathe, orbit, aura, bell

    var id: String { rawValue }

    var name: String {
        switch self {
        case .ripples: "Wellen"
        case .breathe: "Atmen"
        case .orbit: "Orbit"
        case .aura: "Aura"
        case .bell: "Glocke"
        }
    }

    var note: String {
        switch self {
        case .ripples: "Ringe laufen im Klingeltakt nach außen und verblassen"
        case .breathe: "Der Ring atmet ruhig, ein weiches Leuchten schwillt an und ab"
        case .orbit: "Drei Lichtpunkte mit Schweif kreisen um den Ring"
        case .aura: "Ein farbiger Schein dreht sich um den Ring und pulsiert"
        case .bell: "Der Ring schwingt wie eine Glocke, Schallbögen laufen nach außen"
        }
    }
}

/// The caller's ring with its ringing motion. `active` false (answered, declined) draws the
/// motion back into the ring and sends one soft wave out across the screen — the morph into
/// the call.
struct RingingStage<Content: View>: View {
    let style: RingStyle
    let color: Color
    var active = true
    var ring: CGFloat = 128   // the ring's size: the motion scales with it
    var paused = false
    @ViewBuilder let content: Content
    @State private var bloom = 1.0   // 0 → 1: the answer's wave; 1 = done

    var body: some View {
        TimelineView(.animation(paused: paused || !active)) { context in
            let t = paused ? 0.35 : context.date.timeIntervalSinceReferenceDate
            content
                .scaleEffect(active && style == .breathe ? 1 + 0.05 * Self.breath(t) : 1)
                .rotationEffect(.degrees(active && style == .bell ? Self.bell(t) : 0), anchor: .top)
                .background {
                    Canvas { ctx, size in Self.draw(style, in: &ctx, size: size, t: t, ring: ring, color: color) }
                        .frame(width: ring * 2.8, height: ring * 2.8)
                        .opacity(active ? 1 : 0)
                        .scaleEffect(active ? 1 : 0.6)
                        .allowsHitTesting(false)
                }
        }
        .background {
            // The answer: one soft wave from the ring out over the screen.
            Circle()
                .fill(RadialGradient(colors: [color.opacity(0), color.opacity(0.22), color.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: ring * 0.6))
                .frame(width: ring * 1.2, height: ring * 1.2)
                .scaleEffect(1 + 7 * bloom)
                .opacity(bloom < 1 ? 1 - bloom : 0)
                .allowsHitTesting(false)
        }
        .animation(.spring(response: 0.7, dampingFraction: 0.86), value: active)
        .onChange(of: active) { _, now in
            guard !now, !paused else { return }
            bloom = 0
            withAnimation(.easeOut(duration: 1.1)) { bloom = 1 }
        }
    }

    // MARK: - Motion

    nonisolated static var cycle: Double { 2.4 }

    /// The ring-ring beat: two short swells in each 2.4 s cycle, 0…1.
    nonisolated static func beat(_ t: Double) -> Double {
        let c = t.truncatingRemainder(dividingBy: 2.4)
        return exp(-pow((c - 0.2) / 0.12, 2)) + 0.85 * exp(-pow((c - 0.62) / 0.12, 2))
    }

    nonisolated static func breath(_ t: Double) -> Double { 0.5 - 0.5 * cos(2 * .pi * t / 2.8) }

    /// The bell's swing in degrees: a damped shake through both beats, then rest.
    nonisolated static func bell(_ t: Double) -> Double {
        let c = t.truncatingRemainder(dividingBy: 2.4)
        guard c < 1.1 else { return 0 }
        return 7 * sin(c * 2 * .pi * 5.5) * exp(-c * 1.6)
    }

    nonisolated static func draw(_ style: RingStyle, in ctx: inout GraphicsContext, size: CGSize, t: Double,
                                 ring: CGFloat, color: Color) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r0 = ring * 0.66   // just outside the ring's disc
        let u = ring / 128
        func circle(_ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) }

        switch style {
        case .ripples:
            // Each beat sends a ring outwards; it lives 2 s, so the last one still fades as the next cycle starts.
            let phase = t.truncatingRemainder(dividingBy: cycle)
            for back in 0...1 {
                for launch in [0.1, 0.52] {
                    let age = phase - launch + Double(back) * cycle
                    guard age >= 0, age < 2.0 else { continue }
                    let p = age / 2.0
                    let r = r0 * (1 + 0.6 * (1 - pow(1 - p, 2.2)))
                    let a = 0.5 * pow(1 - p, 1.6)
                    ctx.fill(circle(r), with: .color(color.opacity(a * 0.18)))
                    ctx.stroke(circle(r), with: .color(color.opacity(a)), lineWidth: 2 * u)
                }
            }
        case .breathe:
            let s = breath(t)
            let r = r0 * (1.05 + 0.3 * s)
            ctx.fill(circle(r), with: .radialGradient(Gradient(colors: [color.opacity(0.32 * (0.45 + 0.55 * s)), color.opacity(0)]),
                                                      center: c, startRadius: r0 * 0.6, endRadius: r))
            ctx.stroke(circle(r0 * (1.0 + 0.12 * s)), with: .color(color.opacity(0.18 + 0.25 * s)), lineWidth: 1.5 * u)
        case .orbit:
            for k in 0..<3 {
                let speed = 1.25 + 0.3 * Double(k)
                let head = t * speed + Double(k) * 2.1
                let r = r0 * (1.1 + 0.11 * CGFloat(k))
                for j in 0..<18 {
                    let a = head - Double(j) * 0.06
                    let f = 1 - Double(j) / 18
                    let dot = (3.6 - 0.6 * CGFloat(k)) * u * CGFloat(0.35 + 0.65 * f)
                    let p = CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - dot, y: p.y - dot, width: 2 * dot, height: 2 * dot)),
                             with: .color(color.opacity(0.85 * f * f)))
                }
            }
        case .aura:
            let glow = 0.5 + 0.5 * min(1, beat(t))
            let spin = Angle.degrees(t * 75)
            // Two bright arcs on a dim ring, turning: the turn reads clearly through the glow.
            let gradient = Gradient(stops: [.init(color: color, location: 0), .init(color: color.opacity(0), location: 0.22),
                                            .init(color: color.opacity(0), location: 0.5), .init(color: color, location: 0.5),
                                            .init(color: color.opacity(0), location: 0.72), .init(color: color.opacity(0), location: 1)])
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 12 * u))
                layer.opacity = glow
                layer.stroke(circle(r0 * 1.04), with: .conicGradient(gradient, center: c, angle: spin), lineWidth: 18 * u)
            }
            ctx.stroke(circle(r0 * 1.04), with: .color(color.opacity(0.12)), lineWidth: 2 * u)
            ctx.stroke(circle(r0 * 1.04), with: .conicGradient(gradient, center: c, angle: spin), lineWidth: 3 * u)
        case .bell:
            // Sound arcs left and right, lighting up outwards while the bell swings.
            let phase = t.truncatingRemainder(dividingBy: cycle)
            for i in 0..<3 {
                let local = (phase - 0.08 - Double(i) * 0.13) / 0.75
                guard local > 0, local < 1 else { continue }
                let a = 0.75 * sin(.pi * local)
                let r = r0 * (1.08 + 0.2 * CGFloat(i))
                for side in [0.0, 180.0] {
                    var arc = Path()
                    arc.addArc(center: c, radius: r, startAngle: .degrees(side - 26), endAngle: .degrees(side + 26), clockwise: false)
                    ctx.stroke(arc, with: .color(color.opacity(a)), style: StrokeStyle(lineWidth: 3 * u, lineCap: .round))
                }
            }
        }
    }
}
