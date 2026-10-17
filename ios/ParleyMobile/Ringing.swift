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
        let k = Appearance.shared.tuning
        let g = Knobs.general(style)
        let reach = ring * 2.8 * k[g.scale]
        TimelineView(.animation(paused: paused || !active)) { context in
            let t = paused ? 0.35 : context.date.timeIntervalSinceReferenceDate
            content
                .scaleEffect(active && style == .breathe ? 1 + k[Knobs.Breathe.scale] * Self.breath(t, k) : 1)
                .rotationEffect(.degrees(active && style == .bell ? Self.bell(t, k) : 0), anchor: .top)
                .background {
                    Canvas { ctx, size in
                        Self.draw(style, in: &ctx, size: size, t: t, ring: ring * k[g.scale], color: color, k: k)
                    }
                    .frame(width: max(reach, ring * 2.8), height: max(reach, ring * 2.8))
                    .opacity(active ? min(1, k[g.opacity]) : 0)
                    .scaleEffect(active ? 1 : 0.6)
                    .allowsHitTesting(false)
                }
        }
        .background {
            // The answer: one soft wave from the ring out over the screen.
            Circle()
                .fill(RadialGradient(colors: [color.opacity(0), color.opacity(k[g.answerGlow]), color.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: ring * 0.6))
                .frame(width: ring * 1.2, height: ring * 1.2)
                .scaleEffect(1 + k[g.answerReach] * bloom)
                .opacity(bloom < 1 ? 1 - bloom : 0)
                .allowsHitTesting(false)
        }
        .animation(.spring(response: 0.7, dampingFraction: 0.86), value: active)
        .onChange(of: active) { _, now in
            guard !now, !paused else { return }
            bloom = 0
            withAnimation(.easeOut(duration: k[g.answerTime])) { bloom = 1 }
        }
    }

    // MARK: - Motion

    /// The ring-ring beat: two short swells each cycle, 0…1.
    nonisolated static func beat(_ t: Double, _ k: Tuning, _ g: RingGeneral) -> Double {
        let c = t.truncatingRemainder(dividingBy: max(0.1, k[g.cycle])), w = max(0.01, k[g.beatWidth])
        return exp(-pow((c - k[g.beat1]) / w, 2)) + k[g.beat2Strength] * exp(-pow((c - k[g.beat2]) / w, 2))
    }

    nonisolated static func breath(_ t: Double, _ k: Tuning) -> Double {
        0.5 - 0.5 * cos(2 * .pi * t / max(0.1, k[Knobs.Breathe.period]))
    }

    /// The bell's swing in degrees: a damped shake through both beats, then rest.
    nonisolated static func bell(_ t: Double, _ k: Tuning) -> Double {
        typealias B = Knobs.Bell
        let c = t.truncatingRemainder(dividingBy: max(0.1, k[B.general.cycle]))
        guard c < k[B.swingTime] else { return 0 }
        return k[B.swing] * sin(c * 2 * .pi * k[B.freq]) * exp(-c * k[B.damping])
    }

    nonisolated static func draw(_ style: RingStyle, in ctx: inout GraphicsContext, size: CGSize, t: Double,
                                 ring: CGFloat, color: Color, k: Tuning) {
        let g = Knobs.general(style)
        let cycle = max(0.1, k[g.cycle])
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r0 = ring * 0.66   // just outside the ring's disc
        let u = ring / 128
        func circle(_ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) }
        let fade = min(1, max(0, k[g.opacity]))

        switch style {
        case .ripples:
            // Each beat sends a ring outwards; the last one may still fade as the next cycle starts.
            typealias R = Knobs.Ripples
            let phase = t.truncatingRemainder(dividingBy: cycle), life = max(0.1, k[R.life])
            let start = ring * k[R.start], reach = k[R.reach], ease = k[R.ease]
            for back in 0...Int(ceil(life / cycle)) {
                for launch in [k[g.beat1], k[g.beat2]] {
                    let age = phase - launch + Double(back) * cycle
                    guard age >= 0, age < life else { continue }
                    let p = age / life
                    let r = start * (1 + reach * (1 - pow(1 - p, ease)))
                    let a = fade * pow(1 - p, k[R.fade])
                    ctx.fill(circle(r), with: .color(color.opacity(a * k[R.fill] * 0.5)))
                    ctx.stroke(circle(r), with: .color(color.opacity(a * k[R.stroke])), lineWidth: k[R.width] * u)
                }
            }
        case .breathe:
            typealias B = Knobs.Breathe
            let s = breath(t, k)
            let r = r0 * (1.05 + k[B.reach] * s)
            ctx.fill(circle(r), with: .radialGradient(Gradient(colors: [color.opacity(fade * k[B.glow] * (0.45 + 0.55 * s)), color.opacity(0)]),
                                                      center: c, startRadius: r0 * 0.6, endRadius: r))
            ctx.stroke(circle(r0 * (1.0 + k[B.ringGrow] * s)), with: .color(color.opacity(fade * (k[B.ringAlpha] * (0.7 + s)))),
                       lineWidth: k[B.ringWidth] * u)
        case .orbit:
            typealias O = Knobs.RingOrbit
            let tail = max(1, k.int(O.tail)), spacing = k[O.spacing]
            for n in 0..<max(1, k.int(O.dots)) {
                let speed = k[O.speed] + k[O.speedStep] * Double(n)
                let head = t * speed + Double(n) * 2.1
                let r = r0 * (k[O.radius] + k[O.radiusStep] * CGFloat(n))
                for j in 0..<tail {
                    let a = head - Double(j) * spacing * (speed < 0 ? -1 : 1)
                    let f = 1 - Double(j) / Double(tail)
                    let dot = max(0.3, k[O.dot] - k[O.dotStep] * CGFloat(n)) * u * CGFloat(0.35 + 0.65 * f)
                    let p = CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - dot, y: p.y - dot, width: 2 * dot, height: 2 * dot)),
                             with: .color(color.opacity(fade * k[O.alpha] * f * f)))
                }
            }
        case .aura:
            // Bright arcs with fading tails turn around the ring, in a glow that swells on the beats.
            typealias A = Knobs.Aura
            let glow = k[A.base] + (1 - k[A.base]) * min(1, beat(t, k, g))
            let head = t * k[A.spin]
            let r = r0 * k[A.radius]
            let arcs = max(1, k.int(A.arcs)), pieces = max(1, k.int(A.tail)), seg = k[A.seg]
            func draw(_ g: inout GraphicsContext, width: CGFloat, alpha: Double) {
                for n in 0..<arcs {
                    for j in 0..<pieces {
                        let a = head + Double(n) * 2 * .pi / Double(arcs) - Double(j) * seg
                        var piece = Path()
                        piece.addArc(center: c, radius: r, startAngle: .radians(a - seg * 1.1), endAngle: .radians(a), clockwise: false)
                        g.stroke(piece, with: .color(color.opacity(fade * alpha * pow(1 - Double(j) / Double(pieces), 1.6))),
                                 style: StrokeStyle(lineWidth: width, lineCap: .butt))
                    }
                }
            }
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: k[A.blur] * u))
                layer.opacity = glow
                draw(&layer, width: k[A.width] * u, alpha: 0.9)
            }
            ctx.stroke(circle(r), with: .color(color.opacity(fade * k[A.track])), lineWidth: 2 * u)
            if k[A.line] > 0 { draw(&ctx, width: k[A.line] * u, alpha: 1) }
        case .bell:
            // Sound arcs left and right, lighting up outwards while the bell swings.
            typealias B = Knobs.Bell
            let phase = t.truncatingRemainder(dividingBy: cycle)
            for i in 0..<k.int(B.arcs) {
                let local = (phase - 0.08 - Double(i) * k[B.delay]) / max(0.05, k[B.arcTime])
                guard local > 0, local < 1 else { continue }
                let a = fade * k[B.alpha] * sin(.pi * local)
                let r = r0 * (k[B.first] + k[B.step] * CGFloat(i))
                for side in [0.0, 180.0] {
                    var arc = Path()
                    arc.addArc(center: c, radius: r, startAngle: .degrees(side - k[B.spread]), endAngle: .degrees(side + k[B.spread]), clockwise: false)
                    ctx.stroke(arc, with: .color(color.opacity(a)), style: StrokeStyle(lineWidth: k[B.width] * u, lineCap: .round))
                }
            }
        }
    }
}
