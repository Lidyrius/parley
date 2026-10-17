import SwiftUI

/// What Parley looks like in a call (Einstellungen → Darstellung → Parley): a cloud of particles
/// in the palette's colour that breathes on its own and stirs with the voice — after JARVIS's
/// particle globe and the orbs AI assistants use to show they speak.
enum OrbStyle: String, CaseIterable, Identifiable, Sendable {
    case jarvis, nebula, wave, orbit, swirl

    var id: String { rawValue }

    var name: String {
        switch self {
        case .jarvis: "JARVIS"
        case .nebula: "Nebel"
        case .wave: "Welle"
        case .orbit: "Orbit"
        case .swirl: "Wirbel"
        }
    }

    var note: String {
        switch self {
        case .jarvis: "Mehrere Schalen aus Lichtpunkten, die sich gemeinsam drehen und mit der Stimme beben"
        case .nebula: "Eine weiche Wolke, die mit der Stimme aufleuchtet und sich weitet"
        case .wave: "Ein Punktgitter, über das die Stimme in Wellen läuft"
        case .orbit: "Ringe aus Teilchen kreisen um einen hellen Kern, schneller beim Sprechen"
        case .swirl: "Eine Galaxie, deren Arme sich mit der Stimme öffnen"
        }
    }
}

/// The orb. `energy` is the voice level, 0…1 (eased per display frame here).
struct ParticleOrb: View {
    let style: OrbStyle
    let color: Color
    var size: CGFloat = 168
    var paused = false
    var energy: (Date) -> Double = { _ in 0 }
    @State private var smoother = LevelSmoother()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: paused)) { context in
            let t = paused ? 12.0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000)
            let tuning = Appearance.shared.tuning
            let g = Knobs.general(style)
            let e = smoother.next(min(1, energy(context.date) * tuning[g.gain]), at: context.date.timeIntervalSinceReferenceDate,
                                  rise: tuning[g.rise], fall: tuning[g.fall])
            Canvas { ctx, canvas in
                // On dark, overlapping particles add up to light — the hologram's glow.
                Self.draw(style, in: &ctx, size: canvas, orb: size, t: t, energy: e, color: color, tuning: tuning,
                          dense: size >= 100, glows: scheme == .dark)
            }
            .frame(width: size * 1.7, height: size * 1.7)   // the glow and the sparks reach past the orb
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: - Drawing

    /// A stable pseudo-random number in 0..<1 for particle `i`, stream `k`.
    nonisolated static func rand(_ i: Int, _ k: Int) -> Double {
        let x = sin(Double(i) * 12.9898 + Double(k) * 78.233) * 43758.5453
        return x - x.rounded(.down)
    }

    /// The i-th of n points spread evenly over the unit sphere (Fibonacci lattice).
    nonisolated static func sphere(_ i: Int, of n: Int) -> SIMD3<Double> {
        let y = 1 - 2 * (Double(i) + 0.5) / Double(n)
        let r = (1 - y * y).squareRoot()
        let a = Double(i) * 2.399963229728653   // the golden angle
        return SIMD3(cos(a) * r, y, sin(a) * r)
    }

    nonisolated static func rotate(_ p: SIMD3<Double>, yaw: Double, tilt: Double) -> SIMD3<Double> {
        let x = p.x * cos(yaw) + p.z * sin(yaw), z = -p.x * sin(yaw) + p.z * cos(yaw)
        return SIMD3(x, p.y * cos(tilt) - z * sin(tilt), p.y * sin(tilt) + z * cos(tilt))
    }

    nonisolated static func draw(_ style: OrbStyle, in ctx: inout GraphicsContext, size: CGSize, orb: CGFloat, t: Double,
                                 energy e: Double, color: Color, tuning k: Tuning, dense: Bool, glows: Bool) {
        let g = Knobs.general(style)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let R = orb * k[g.size] * (1 + k[g.swell] * e)
        let unit = orb / 168
        let few = dense ? 1.0 : 0.33   // the small orb above a slide: fewer points

        // The glow behind: brighter while speaking.
        let glow = R * (k[g.glowReach] + 0.35 * e)
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - glow, y: c.y - glow, width: 2 * glow, height: 2 * glow)),
                 with: .radialGradient(Gradient(colors: [color.opacity((0.22 + 0.25 * e) * k[g.glow]), color.opacity(0)]),
                                       center: c, startRadius: 0, endRadius: glow))

        if glows { ctx.blendMode = .plusLighter }

        let perspective = k[g.depth], fadeFar = k[g.fadeFar], sizeFar = k[g.sizeFar]
        /// One particle at a 3D point (unit sphere scale); nearer ones bigger and brighter.
        func dot(_ p: SIMD3<Double>, size s: Double, alpha a: Double) {
            let depth = max(0, min(1, (p.z + 1.4) / 2.6))       // 0 far … 1 near
            let persp = 1 / (1 + perspective - perspective * p.z)
            let x = c.x + CGFloat(p.x * persp) * R, y = c.y + CGFloat(p.y * persp) * R
            let r = CGFloat(s * 0.71 * (1 - sizeFar + sizeFar * depth)) * unit
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                     with: .color(color.opacity(min(1, a * (1 - fadeFar + fadeFar * 1.08 * depth)))))
        }

        switch style {
        case .jarvis:
            // Nested shells of light points turning as one, like JARVIS's globe: each inner shell a
            // little smaller and dimmer, its lattice turned a little against the others. The voice
            // makes every shell quiver the same way; a few points lift off, but stay close. Points
            // near a shell's outline glow most (rim-lit, like a hologram), so each shell reads as
            // its own ring of light.
            typealias J = Knobs.Jarvis
            let yaw = t * k[J.spin], tilt = k[J.tilt]
            let quiver = k[J.quiver], lat0 = k[J.latWaves], lon0 = k[J.lonWaves], speed = k[J.waveSpeed]
            let breathe = k[J.breathe], breatheSpeed = k[J.breatheSpeed]
            let sparkEvery = k.int(J.sparkEvery), sparks = k[J.sparks], sparkSpeed = k[J.sparkSpeed]
            let dotSize = k[J.dot], dotVar = k[J.dotVar], rimK = k[J.rim], face = k[J.face], light = k[J.voiceLight]
            for s in 0..<max(1, k.int(J.shells)) {
                let radius = max(0.05, 1 - Double(s) * k[J.gap])
                let count = max(8, Int(k[J.particles] * pow(radius, k[J.countFalloff]) * few))
                let alpha = pow(k[J.innerFade], Double(s))
                let twist = Double(s) * k[J.twist]
                for i in 0..<count {
                    let p = rotate(sphere(i, of: count), yaw: twist, tilt: twist * k[J.twistTilt])
                    let lat = asin(p.y), lon = atan2(p.z, p.x)
                    var r = 1 + breathe * sin(t * breatheSpeed + Double(i)) + e * quiver * sin(lat0 * lat + lon0 * lon + t * speed)
                    if sparkEvery > 0, i % sparkEvery == 0 {
                        r += e * sparks * (t * sparkSpeed + rand(i, 1)).truncatingRemainder(dividingBy: 1)
                    }
                    let q = rotate(p, yaw: yaw, tilt: tilt)
                    let rim = 1 - abs(q.z)
                    dot(q * (r * radius), size: dotSize + rand(i, 2) * dotVar,
                        alpha: alpha * (face + rimK * rim * rim) * (1 - light + 0.5 * light + light * e))
                }
            }
        case .nebula:
            // Particles inside the ball, each drifting on its own slow path.
            typealias N = Knobs.Nebula
            let n = max(1, Int(k[N.count] * few))
            let yaw = t * k[N.spin], tilt = k[N.tilt], ds = k[N.driftSpeed]
            let drift = k[N.drift] + k[N.voiceDrift] * e
            let radius = k[N.radius] + k[N.voiceRadius] * e, compact = k[N.compact]
            let alpha = k[N.alpha] + k[N.voiceAlpha] * e, dotSize = k[N.dot], dotVar = k[N.dotVar]
            for i in 0..<n {
                let rr = pow(rand(i, 0), compact) * radius
                var p = sphere(Int(rand(i, 1) * 5000), of: 5000) * rr
                let dx: Double = sin(t * 0.7 * ds + rand(i, 2) * 6.3)
                let dy: Double = cos(t * 0.6 * ds + rand(i, 3) * 6.3)
                let dz: Double = sin(t * 0.5 * ds + rand(i, 4) * 6.3)
                p += SIMD3(dx, dy, dz) * drift
                dot(rotate(p, yaw: yaw, tilt: tilt), size: dotSize + rand(i, 5) * dotVar, alpha: alpha)
            }
        case .wave:
            // Rows of dots around the globe; the voice runs across them as waves.
            typealias W = Knobs.Wave
            let rows = max(2, Int(Double(k.int(W.rows)) * (dense ? 1 : 0.55)))
            let cols = max(3, Int(Double(k.int(W.cols)) * (dense ? 1 : 0.55)))
            let yaw = t * k[W.spin], tilt = k[W.tilt]
            let amp = k[W.amp] + k[W.voiceAmp] * e
            let lonF = k[W.lonFreq], latF = k[W.latFreq], lonS = k[W.lonSpeed], latS = k[W.latSpeed]
            let alpha = k[W.alpha] + k[W.voiceAlpha] * e, dotSize = k[W.dot]
            for a in 0..<rows {
                let lat = -Double.pi / 2 + .pi * (Double(a) + 0.5) / Double(rows)
                for b in 0..<cols {
                    let lon = 2 * .pi * Double(b) / Double(cols)
                    let r = 1 + amp * sin(lon * lonF + t * lonS) * cos(lat * latF - t * latS)
                    let p = SIMD3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon)) * r
                    dot(rotate(p, yaw: yaw, tilt: tilt), size: dotSize, alpha: alpha)
                }
            }
        case .orbit:
            // A bright core and tilted rings of particles circling it.
            typealias O = Knobs.Orbit
            let core = Int(k[O.coreCount] * few)
            let coreR = k[O.coreSize], pulse = k[O.corePulse], coreVoice = k[O.coreVoice], coreSpin = k[O.coreSpin]
            for i in 0..<core {
                let p = sphere(i, of: core) * (coreR + pulse * sin(t * 3 + Double(i)) + coreVoice * e)
                dot(rotate(p, yaw: t * coreSpin, tilt: 0.3), size: k[O.coreDot], alpha: 0.9)
            }
            let per = max(3, Int(k[O.perRing] * few))
            let alpha = k[O.alpha] + k[O.voiceAlpha] * e, dotSize = k[O.dot], dotVar = k[O.dotVar], wobble = k[O.wobble]
            for ring in 0..<k.int(O.rings) {
                let tiltRing = k[O.tilt] + Double(ring) * k[O.tiltStep], turn = Double(ring) * 0.9 + t * k[O.precession]
                let speed = (k[O.speed] + k[O.speedStep] * Double(ring)) * (1 + k[O.voiceSpeed] * e)
                let base = k[O.radius] + k[O.radiusStep] * Double(ring)
                for j in 0..<per {
                    let a = Double(j) / Double(per) * 2 * .pi + t * speed
                    let rr = base + wobble * sin(Double(j) * 1.7 + t)
                    let p = SIMD3(cos(a) * rr, 0.02 * sin(Double(j) * 3.1), sin(a) * rr)
                    dot(rotate(rotate(p, yaw: 0, tilt: tiltRing), yaw: turn, tilt: 0.25),
                        size: dotSize + dotVar * rand(j, ring), alpha: alpha)
                }
            }
        case .swirl:
            // A tilted galaxy whose arms open up with the voice.
            typealias S = Knobs.Swirl
            let n = max(1, Int(k[S.count] * few))
            let arms = max(1, k.int(S.arms))
            let winding = k[S.winding], spread = k[S.spread] + k[S.voiceSpread] * e
            let radius = k[S.radius] * (1 + k[S.voiceRadius] * e), conc = k[S.concentration], thick = k[S.thickness]
            let spin = t * k[S.spin], tilt = k[S.tilt]
            let alpha = k[S.alpha] + k[S.voiceAlpha] * e, dotSize = k[S.dot], dotVar = k[S.dotVar]
            for i in 0..<n {
                let arm = Double(i % arms) * 2 * .pi / Double(arms)
                let rr = pow(rand(i, 0), conc)
                // The arms turn as one (a turn per star would wind them up into a plain disc).
                let a = arm + rr * winding + (rand(i, 1) - 0.5) * spread + spin
                let p = SIMD3(cos(a) * rr * radius, (rand(i, 2) - 0.5) * thick * (1 - rr), sin(a) * rr * radius)
                dot(rotate(p, yaw: 0, tilt: tilt), size: dotSize + rand(i, 3) * dotVar, alpha: alpha)
            }
        }
    }
}
