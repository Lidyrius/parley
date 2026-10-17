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

/// The orb's knobs (Einstellungen → Entwickler → JARVIS-Regler). The defaults are the shipped
/// look; size, voice gain and glow apply to every style, the rest shapes JARVIS.
struct OrbTuning: Codable, Equatable, Sendable {
    var shells = 3            // nested shells, 1…5
    var shellGap = 0.24       // each shell this much smaller (of the outer radius)
    var particles = 560       // points on the outer shell; inner ones scale with their size
    var innerFade = 0.85      // brightness kept per shell inward
    var twist = 0.9           // each shell's lattice turned this much (radians) against the last
    var size = 0.40           // radius / view size
    var dotSize = 1.3
    var rim = 1.1             // how much a shell's outline outshines its face
    var spin = 0.32           // turn speed (radians a second)
    var tilt = 0.38           // tilt towards you (radians)
    var reactivity = 1.6      // voice gain
    var quiver = 0.12         // how deep the voice ripples the shells
    var waves = 3.0           // ripple lobes around the globe
    var waveSpeed = 5.0
    var breathe = 0.02        // the idle wobble of each point
    var sparks = 0.12         // how far a lifted point drifts
    var sparkEvery = 23       // every n-th point can lift off
    var glow = 1.0            // the soft light behind

    static let shipped = OrbTuning()
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
            let tuning = Appearance.shared.orbTuning
            let e = smoother.next(min(1, energy(context.date) * tuning.reactivity), at: context.date.timeIntervalSinceReferenceDate)
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
                                 energy e: Double, color: Color, tuning k: OrbTuning, dense: Bool, glows: Bool) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let R = orb * k.size * (1 + 0.06 * e)
        let unit = orb / 168

        // The glow behind: brighter while speaking.
        let glow = R * (1.25 + 0.35 * e)
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - glow, y: c.y - glow, width: 2 * glow, height: 2 * glow)),
                 with: .radialGradient(Gradient(colors: [color.opacity((0.22 + 0.25 * e) * k.glow), color.opacity(0)]),
                                       center: c, startRadius: 0, endRadius: glow))

        if glows { ctx.blendMode = .plusLighter }

        /// One particle at a 3D point (unit sphere scale); nearer ones bigger and brighter.
        func dot(_ p: SIMD3<Double>, size s: Double, alpha a: Double) {
            let depth = max(0, min(1, (p.z + 1.4) / 2.6))       // 0 far … 1 near
            let persp = 1 / (1.35 - 0.35 * p.z)
            let x = c.x + CGFloat(p.x * persp) * R, y = c.y + CGFloat(p.y * persp) * R
            let r = CGFloat(s * 0.62 * (0.4 + 0.75 * depth)) * unit
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                     with: .color(color.opacity(min(1, a * (0.12 + 0.95 * depth)))))
        }

        switch style {
        case .jarvis:
            // Nested shells of light points turning as one, like JARVIS's globe: each inner shell a
            // little smaller and dimmer, its lattice turned a little against the others. The voice
            // makes every shell quiver the same way; a few points lift off, but stay close. Points
            // near a shell's outline glow most (rim-lit, like a hologram), so each shell reads as
            // its own ring of light.
            let yaw = t * k.spin, tilt = k.tilt
            for s in 0..<max(1, k.shells) {
                let radius = max(0.05, 1 - Double(s) * k.shellGap)
                let count = max(12, Int(Double(k.particles) * pow(radius, 1.6) * (dense ? 1 : 0.36)))
                let alpha = pow(k.innerFade, Double(s))
                let twist = Double(s) * k.twist
                for i in 0..<count {
                    let p = rotate(sphere(i, of: count), yaw: twist, tilt: twist * 0.5)
                    let lat = asin(p.y), lon = atan2(p.z, p.x)
                    var r = 1 + k.breathe * sin(t * 1.3 + Double(i)) + e * k.quiver * sin(k.waves * lat + 2 * lon + t * k.waveSpeed)
                    if k.sparkEvery > 0, i % k.sparkEvery == 0 {
                        r += e * k.sparks * (t * 0.6 + rand(i, 1)).truncatingRemainder(dividingBy: 1)
                    }
                    let q = rotate(p, yaw: yaw, tilt: tilt)
                    let rim = 1 - abs(q.z)
                    dot(q * (r * radius), size: k.dotSize + rand(i, 2) * 0.6,
                        alpha: alpha * (0.2 + k.rim * rim * rim) * (0.85 + 0.35 * e))
                }
            }
        case .nebula:
            // Particles inside the ball, each drifting on its own slow path.
            let n = dense ? 700 : 220
            let yaw = t * 0.18
            for i in 0..<n {
                let rr = pow(rand(i, 0), 0.45) * (0.95 + 0.25 * e)
                var p = sphere(Int(rand(i, 1) * 5000), of: 5000) * rr
                let drift: Double = 0.06 + 0.08 * e
                let dx: Double = sin(t * 0.7 + rand(i, 2) * 6.3)
                let dy: Double = cos(t * 0.6 + rand(i, 3) * 6.3)
                let dz: Double = sin(t * 0.5 + rand(i, 4) * 6.3)
                p += SIMD3(dx, dy, dz) * drift
                dot(rotate(p, yaw: yaw, tilt: 0.2), size: 1 + rand(i, 5) * 1.6, alpha: 0.35 + 0.4 * e)
            }
        case .wave:
            // Rows of dots around the globe; the voice runs across them as waves.
            let rows = dense ? 22 : 12, cols = dense ? 40 : 22
            let yaw = t * 0.25
            for a in 0..<rows {
                let lat = -Double.pi / 2 + .pi * (Double(a) + 0.5) / Double(rows)
                for b in 0..<cols {
                    let lon = 2 * .pi * Double(b) / Double(cols)
                    let r = 1 + (0.04 + 0.22 * e) * sin(lon * 3 + t * 2.4) * cos(lat * 2 - t * 1.6)
                    let p = SIMD3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon)) * r
                    dot(rotate(p, yaw: yaw, tilt: 0.35), size: 1.2, alpha: 0.5 + 0.45 * e)
                }
            }
        case .orbit:
            // A bright core and four tilted rings of particles circling it.
            let core = dense ? 140 : 50
            for i in 0..<core {
                let p = sphere(i, of: core) * (0.32 + 0.05 * sin(t * 3 + Double(i)) + 0.12 * e)
                dot(rotate(p, yaw: t * 0.5, tilt: 0.3), size: 1.5, alpha: 0.9)
            }
            let per = dense ? 120 : 40
            for ring in 0..<4 {
                let tiltRing = 0.25 + Double(ring) * 0.8, turn = Double(ring) * 0.9 + t * 0.15
                let speed = (0.45 + 0.15 * Double(ring)) * (1 + 2.2 * e)
                for j in 0..<per {
                    let a = Double(j) / Double(per) * 2 * .pi + t * speed
                    let rr = 0.82 + 0.1 * Double(ring) + 0.03 * sin(Double(j) * 1.7 + t)
                    let p = SIMD3(cos(a) * rr, 0.02 * sin(Double(j) * 3.1), sin(a) * rr)
                    dot(rotate(rotate(p, yaw: 0, tilt: tiltRing), yaw: turn, tilt: 0.25),
                        size: 1.1 + 0.6 * rand(j, ring), alpha: 0.45 + 0.4 * e)
                }
            }
        case .swirl:
            // A tilted galaxy with three arms that open up with the voice.
            let n = dense ? 760 : 240
            for i in 0..<n {
                let arm = Double(i % 3) * 2 * .pi / 3
                let rr = pow(rand(i, 0), 0.6) * (1 + 0.25 * e)
                // The arms turn as one (a turn per star would wind them up into a plain disc).
                let spread = (rand(i, 1) - 0.5) * (0.35 + 0.45 * e)
                let a = arm + rr * 4.6 + spread + t * 0.35
                let p = SIMD3(cos(a) * rr * 1.15, (rand(i, 2) - 0.5) * 0.12 * (1 - rr), sin(a) * rr * 1.15)
                dot(rotate(p, yaw: 0, tilt: 1.05), size: 0.9 + rand(i, 3) * 1.4, alpha: 0.5 + 0.4 * e)
            }
        }
    }
}
