import Foundation

/// One adjustable value of an animation (Einstellungen → Entwickler): its list section, range
/// and shipped value. `whole` ones are counts.
struct Knob: Identifiable, Sendable {
    let id: String
    let label: String
    let section: String
    let range: ClosedRange<Double>
    let value: Double
    var whole = false

    init(_ id: String, _ label: String, _ section: String, _ range: ClosedRange<Double>, _ value: Double, whole: Bool = false) {
        self.id = id
        self.label = label
        self.section = section
        self.range = range
        self.value = value
        self.whole = whole
    }
}

/// The developer's changes, remembered; a knob not in here keeps its shipped value.
struct Tuning: Codable, Equatable, Sendable {
    var values: [String: Double] = [:]

    subscript(_ k: Knob) -> Double { values[k.id] ?? k.value }
    func int(_ k: Knob) -> Int { Int(self[k].rounded()) }
}

/// What every orb has, per style (each style is tuned on its own).
struct OrbGeneral: Sendable {
    let size, gain, rise, fall, swell, glow, glowReach, depth, fadeFar, sizeFar: Knob

    init(_ p: String) {
        let s = "Allgemein"
        size = Knob("\(p).size", "Größe", s, 0.15...0.6, 0.40)
        gain = Knob("\(p).gain", "Empfindlichkeit für die Stimme", s, 0...5, 1.6)
        rise = Knob("\(p).rise", "Reaktion: Anstieg (s)", s, 0.005...0.4, 0.04)
        fall = Knob("\(p).fall", "Reaktion: Abklingen (s)", s, 0.01...1, 0.11)
        swell = Knob("\(p).swell", "Wächst beim Sprechen", s, 0...0.4, 0.06)
        glow = Knob("\(p).glow", "Schein", s, 0...3, 1)
        glowReach = Knob("\(p).glowReach", "Schein: Weite", s, 0.6...3, 1.25)
        depth = Knob("\(p).depth", "Perspektive", s, 0...0.9, 0.35)
        fadeFar = Knob("\(p).fadeFar", "Hinten blasser", s, 0...1, 0.88)
        sizeFar = Knob("\(p).sizeFar", "Hinten kleiner", s, 0...1, 0.65)
    }

    var all: [Knob] { [size, gain, rise, fall, swell, glow, glowReach, depth, fadeFar, sizeFar] }
}

/// What every ringing motion has, per style.
struct RingGeneral: Sendable {
    let cycle, beat1, beat2, beatWidth, beat2Strength, scale, opacity, answerGlow, answerReach, answerTime: Knob

    init(_ p: String) {
        let s = "Takt", a = "Annehmen"
        cycle = Knob("\(p).cycle", "Klingel-Zyklus (s)", s, 0.8...6, 2.4)
        beat1 = Knob("\(p).beat1", "1. Schlag bei (s)", s, 0...2, 0.2)
        beat2 = Knob("\(p).beat2", "2. Schlag bei (s)", s, 0...3, 0.62)
        beatWidth = Knob("\(p).beatWidth", "Schlag-Breite (s)", s, 0.02...0.5, 0.12)
        beat2Strength = Knob("\(p).beat2Strength", "Stärke 2. Schlag", s, 0...1.5, 0.85)
        scale = Knob("\(p).scale", "Größe der Bewegung", s, 0.4...2.5, 1)
        opacity = Knob("\(p).opacity", "Deckkraft", s, 0...1.5, 1)
        answerGlow = Knob("\(p).answerGlow", "Welle: Helligkeit", a, 0...0.9, 0.22)
        answerReach = Knob("\(p).answerReach", "Welle: Weite", a, 1...14, 7)
        answerTime = Knob("\(p).answerTime", "Welle: Dauer (s)", a, 0.2...3, 1.1)
    }

    var all: [Knob] { [cycle, beat1, beat2, beatWidth, beat2Strength, scale, opacity, answerGlow, answerReach, answerTime] }
}

/// Every knob, by animation.
enum Knobs {
    enum Jarvis {
        static let general = OrbGeneral("jarvis")
        static let shells = Knob("jarvis.shells", "Anzahl", "Schalen", 1...6, 3, whole: true)
        static let gap = Knob("jarvis.gap", "Abstand", "Schalen", 0.02...0.45, 0.24)
        static let twist = Knob("jarvis.twist", "Verdrehung", "Schalen", 0...3.2, 0.9)
        static let twistTilt = Knob("jarvis.twistTilt", "Verdrehung: Neigung", "Schalen", 0...2, 0.5)
        static let innerFade = Knob("jarvis.innerFade", "Helligkeit innen", "Schalen", 0.05...1, 0.85)
        static let particles = Knob("jarvis.particles", "Anzahl außen", "Teilchen", 40...1600, 560, whole: true)
        static let countFalloff = Knob("jarvis.countFalloff", "Weniger innen", "Teilchen", 0...3, 1.6)
        static let dot = Knob("jarvis.dot", "Punktgröße", "Teilchen", 0.2...3.5, 1.3)
        static let dotVar = Knob("jarvis.dotVar", "Größe streuen", "Teilchen", 0...2, 0.6)
        static let rim = Knob("jarvis.rim", "Randleuchten", "Teilchen", 0...3, 1.1)
        static let face = Knob("jarvis.face", "Fläche hell", "Teilchen", 0...1, 0.2)
        static let spin = Knob("jarvis.spin", "Drehtempo", "Bewegung", -1.5...1.5, 0.32)
        static let tilt = Knob("jarvis.tilt", "Neigung", "Bewegung", -1.57...1.57, 0.38)
        static let breathe = Knob("jarvis.breathe", "Atmen in Ruhe", "Bewegung", 0...0.12, 0.02)
        static let breatheSpeed = Knob("jarvis.breatheSpeed", "Atmen: Tempo", "Bewegung", 0...6, 1.3)
        static let quiver = Knob("jarvis.quiver", "Beben", "Stimme", 0...0.5, 0.12)
        static let latWaves = Knob("jarvis.latWaves", "Wellen (Breite)", "Stimme", 0...10, 3)
        static let lonWaves = Knob("jarvis.lonWaves", "Wellen (Länge)", "Stimme", 0...8, 2)
        static let waveSpeed = Knob("jarvis.waveSpeed", "Wellentempo", "Stimme", -15...15, 5)
        static let voiceLight = Knob("jarvis.voiceLight", "Aufleuchten", "Stimme", 0...1, 0.35)
        static let sparks = Knob("jarvis.sparks", "Funken: Weite", "Stimme", 0...0.9, 0.12)
        static let sparkEvery = Knob("jarvis.sparkEvery", "Funken: jeder n-te Punkt (0 = aus)", "Stimme", 0...80, 23, whole: true)
        static let sparkSpeed = Knob("jarvis.sparkSpeed", "Funken: Tempo", "Stimme", 0...3, 0.6)
        static let all = general.all + [shells, gap, twist, twistTilt, innerFade, particles, countFalloff, dot, dotVar, rim, face,
                                        spin, tilt, breathe, breatheSpeed, quiver, latWaves, lonWaves, waveSpeed, voiceLight,
                                        sparks, sparkEvery, sparkSpeed]
    }

    enum Nebula {
        static let general = OrbGeneral("nebula")
        static let count = Knob("nebula.count", "Anzahl", "Wolke", 40...2500, 700, whole: true)
        static let compact = Knob("nebula.compact", "Zur Mitte hin dichter", "Wolke", 0.15...1.6, 0.45)
        static let radius = Knob("nebula.radius", "Radius", "Wolke", 0.3...1.6, 0.95)
        static let dot = Knob("nebula.dot", "Punktgröße", "Wolke", 0.2...3.5, 1)
        static let dotVar = Knob("nebula.dotVar", "Größe streuen", "Wolke", 0...3, 1.6)
        static let alpha = Knob("nebula.alpha", "Helligkeit", "Wolke", 0...1, 0.35)
        static let drift = Knob("nebula.drift", "Treiben", "Bewegung", 0...0.4, 0.06)
        static let driftSpeed = Knob("nebula.driftSpeed", "Treiben: Tempo", "Bewegung", 0...4, 1)
        static let spin = Knob("nebula.spin", "Drehtempo", "Bewegung", -1.5...1.5, 0.18)
        static let tilt = Knob("nebula.tilt", "Neigung", "Bewegung", -1.57...1.57, 0.2)
        static let voiceRadius = Knob("nebula.voiceRadius", "Weitet sich", "Stimme", 0...1.2, 0.25)
        static let voiceDrift = Knob("nebula.voiceDrift", "Treibt stärker", "Stimme", 0...0.6, 0.08)
        static let voiceAlpha = Knob("nebula.voiceAlpha", "Aufleuchten", "Stimme", 0...1, 0.4)
        static let all = general.all + [count, compact, radius, dot, dotVar, alpha, drift, driftSpeed, spin, tilt,
                                        voiceRadius, voiceDrift, voiceAlpha]
    }

    enum Wave {
        static let general = OrbGeneral("wave")
        static let rows = Knob("wave.rows", "Reihen", "Gitter", 3...60, 22, whole: true)
        static let cols = Knob("wave.cols", "Punkte je Reihe", "Gitter", 4...100, 40, whole: true)
        static let dot = Knob("wave.dot", "Punktgröße", "Gitter", 0.2...3.5, 1.2)
        static let alpha = Knob("wave.alpha", "Helligkeit", "Gitter", 0...1, 0.5)
        static let amp = Knob("wave.amp", "Wellen in Ruhe", "Wellen", 0...0.3, 0.04)
        static let lonFreq = Knob("wave.lonFreq", "Wellen (Länge)", "Wellen", 0...10, 3)
        static let latFreq = Knob("wave.latFreq", "Wellen (Breite)", "Wellen", 0...10, 2)
        static let lonSpeed = Knob("wave.lonSpeed", "Tempo (Länge)", "Wellen", -10...10, 2.4)
        static let latSpeed = Knob("wave.latSpeed", "Tempo (Breite)", "Wellen", -10...10, 1.6)
        static let spin = Knob("wave.spin", "Drehtempo", "Bewegung", -1.5...1.5, 0.25)
        static let tilt = Knob("wave.tilt", "Neigung", "Bewegung", -1.57...1.57, 0.35)
        static let voiceAmp = Knob("wave.voiceAmp", "Wellenhöhe", "Stimme", 0...0.8, 0.22)
        static let voiceAlpha = Knob("wave.voiceAlpha", "Aufleuchten", "Stimme", 0...1, 0.45)
        static let all = general.all + [rows, cols, dot, alpha, amp, lonFreq, latFreq, lonSpeed, latSpeed, spin, tilt,
                                        voiceAmp, voiceAlpha]
    }

    enum Orbit {
        static let general = OrbGeneral("orbit")
        static let coreCount = Knob("orbit.coreCount", "Teilchen", "Kern", 0...500, 140, whole: true)
        static let coreSize = Knob("orbit.coreSize", "Größe", "Kern", 0...0.9, 0.32)
        static let corePulse = Knob("orbit.corePulse", "Pulsieren", "Kern", 0...0.3, 0.05)
        static let coreSpin = Knob("orbit.coreSpin", "Drehtempo", "Kern", -2...2, 0.5)
        static let coreDot = Knob("orbit.coreDot", "Punktgröße", "Kern", 0.2...3.5, 1.5)
        static let rings = Knob("orbit.rings", "Anzahl", "Ringe", 0...10, 4, whole: true)
        static let perRing = Knob("orbit.perRing", "Teilchen je Ring", "Ringe", 6...400, 120, whole: true)
        static let radius = Knob("orbit.radius", "Radius", "Ringe", 0.3...1.6, 0.82)
        static let radiusStep = Knob("orbit.radiusStep", "Radius: Schritt", "Ringe", 0...0.4, 0.1)
        static let tilt = Knob("orbit.tilt", "Neigung", "Ringe", -1.57...1.57, 0.25)
        static let tiltStep = Knob("orbit.tiltStep", "Neigung: Schritt", "Ringe", 0...1.8, 0.8)
        static let wobble = Knob("orbit.wobble", "Wackeln", "Ringe", 0...0.3, 0.03)
        static let dot = Knob("orbit.dot", "Punktgröße", "Ringe", 0.2...3.5, 1.1)
        static let dotVar = Knob("orbit.dotVar", "Größe streuen", "Ringe", 0...2, 0.6)
        static let alpha = Knob("orbit.alpha", "Helligkeit", "Ringe", 0...1, 0.45)
        static let speed = Knob("orbit.speed", "Tempo", "Bewegung", -3...3, 0.45)
        static let speedStep = Knob("orbit.speedStep", "Tempo: Schritt", "Bewegung", -1...1, 0.15)
        static let precession = Knob("orbit.precession", "Ringe wandern", "Bewegung", -1...1, 0.15)
        static let coreVoice = Knob("orbit.coreVoice", "Kern wächst", "Stimme", 0...0.6, 0.12)
        static let voiceSpeed = Knob("orbit.voiceSpeed", "Schneller", "Stimme", 0...8, 2.2)
        static let voiceAlpha = Knob("orbit.voiceAlpha", "Aufleuchten", "Stimme", 0...1, 0.4)
        static let all = general.all + [coreCount, coreSize, corePulse, coreSpin, coreDot, rings, perRing, radius, radiusStep,
                                        tilt, tiltStep, wobble, dot, dotVar, alpha, speed, speedStep, precession,
                                        coreVoice, voiceSpeed, voiceAlpha]
    }

    enum Swirl {
        static let general = OrbGeneral("swirl")
        static let count = Knob("swirl.count", "Sterne", "Galaxie", 40...2500, 760, whole: true)
        static let arms = Knob("swirl.arms", "Arme", "Galaxie", 1...10, 3, whole: true)
        static let winding = Knob("swirl.winding", "Windung", "Galaxie", -12...12, 4.6)
        static let spread = Knob("swirl.spread", "Arme: Breite", "Galaxie", 0...2, 0.35)
        static let radius = Knob("swirl.radius", "Radius", "Galaxie", 0.3...1.8, 1.15)
        static let concentration = Knob("swirl.concentration", "Zur Mitte hin dichter", "Galaxie", 0.2...2, 0.6)
        static let thickness = Knob("swirl.thickness", "Dicke", "Galaxie", 0...0.6, 0.12)
        static let dot = Knob("swirl.dot", "Punktgröße", "Galaxie", 0.2...3.5, 0.9)
        static let dotVar = Knob("swirl.dotVar", "Größe streuen", "Galaxie", 0...3, 1.4)
        static let alpha = Knob("swirl.alpha", "Helligkeit", "Galaxie", 0...1, 0.5)
        static let spin = Knob("swirl.spin", "Drehtempo", "Bewegung", -2...2, 0.35)
        static let tilt = Knob("swirl.tilt", "Neigung", "Bewegung", -1.57...1.57, 1.05)
        static let voiceSpread = Knob("swirl.voiceSpread", "Arme öffnen sich", "Stimme", 0...2, 0.45)
        static let voiceRadius = Knob("swirl.voiceRadius", "Wächst", "Stimme", 0...1, 0.25)
        static let voiceAlpha = Knob("swirl.voiceAlpha", "Aufleuchten", "Stimme", 0...1, 0.4)
        static let all = general.all + [count, arms, winding, spread, radius, concentration, thickness, dot, dotVar, alpha,
                                        spin, tilt, voiceSpread, voiceRadius, voiceAlpha]
    }

    enum Ripples {
        static let general = RingGeneral("ring.ripples")
        static let start = Knob("ring.ripples.start", "Start-Radius", "Wellen", 0.3...1.4, 0.66)
        static let reach = Knob("ring.ripples.reach", "Weite", "Wellen", 0.1...1.8, 0.6)
        static let life = Knob("ring.ripples.life", "Lebensdauer (s)", "Wellen", 0.3...4, 2)
        static let ease = Knob("ring.ripples.ease", "Abbremsen", "Wellen", 0.5...5, 2.2)
        static let width = Knob("ring.ripples.width", "Linienstärke", "Wellen", 0.3...8, 2)
        static let stroke = Knob("ring.ripples.stroke", "Linie: Helligkeit", "Wellen", 0...1, 0.5)
        static let fill = Knob("ring.ripples.fill", "Fläche: Helligkeit", "Wellen", 0...0.6, 0.18)
        static let fade = Knob("ring.ripples.fade", "Verblassen", "Wellen", 0.3...4, 1.6)
        static let all = general.all + [start, reach, life, ease, width, stroke, fill, fade]
    }

    enum Breathe {
        static let general = RingGeneral("ring.breathe")
        static let period = Knob("ring.breathe.period", "Atemzug (s)", "Atmen", 0.6...8, 2.8)
        static let scale = Knob("ring.breathe.grow", "Kugel wächst", "Atmen", 0...0.3, 0.05)
        static let reach = Knob("ring.breathe.reach", "Leuchten: Weite", "Atmen", 0...1.4, 0.3)
        static let glow = Knob("ring.breathe.glow", "Leuchten: Helligkeit", "Atmen", 0...1, 0.32)
        static let ringGrow = Knob("ring.breathe.ringGrow", "Ring wächst", "Atmen", 0...0.6, 0.12)
        static let ringAlpha = Knob("ring.breathe.ringAlpha", "Ring: Helligkeit", "Atmen", 0...1, 0.25)
        static let ringWidth = Knob("ring.breathe.ringWidth", "Ring: Stärke", "Atmen", 0...8, 1.5)
        static let all = general.all + [period, scale, reach, glow, ringGrow, ringAlpha, ringWidth]
    }

    enum RingOrbit {
        static let general = RingGeneral("ring.orbit")
        static let dots = Knob("ring.orbit.dots", "Lichtpunkte", "Orbit", 1...10, 3, whole: true)
        static let speed = Knob("ring.orbit.speed", "Tempo", "Orbit", -6...6, 1.25)
        static let speedStep = Knob("ring.orbit.speedStep", "Tempo: Schritt", "Orbit", -2...2, 0.3)
        static let radius = Knob("ring.orbit.radius", "Radius", "Orbit", 0.6...2.4, 1.1)
        static let radiusStep = Knob("ring.orbit.radiusStep", "Radius: Schritt", "Orbit", 0...0.6, 0.11)
        static let tail = Knob("ring.orbit.tail", "Schweif: Länge", "Orbit", 1...60, 18, whole: true)
        static let spacing = Knob("ring.orbit.spacing", "Schweif: Abstand", "Orbit", 0.005...0.3, 0.06)
        static let dot = Knob("ring.orbit.dot", "Punktgröße", "Orbit", 0.5...10, 3.6)
        static let dotStep = Knob("ring.orbit.dotStep", "Punktgröße: Schritt", "Orbit", 0...2, 0.6)
        static let alpha = Knob("ring.orbit.alpha", "Helligkeit", "Orbit", 0...1, 0.85)
        static let all = general.all + [dots, speed, speedStep, radius, radiusStep, tail, spacing, dot, dotStep, alpha]
    }

    enum Aura {
        static let general = RingGeneral("ring.aura")
        static let arcs = Knob("ring.aura.arcs", "Bögen", "Aura", 1...8, 2, whole: true)
        static let spin = Knob("ring.aura.spin", "Drehtempo", "Aura", -6...6, 1.4)
        static let tail = Knob("ring.aura.tail", "Bogenlänge (Stücke)", "Aura", 2...80, 28, whole: true)
        static let seg = Knob("ring.aura.seg", "Stück-Länge", "Aura", 0.01...0.2, 0.05)
        static let radius = Knob("ring.aura.radius", "Radius", "Aura", 0.6...1.8, 1.04)
        static let blur = Knob("ring.aura.blur", "Schein: Unschärfe", "Aura", 0...40, 10)
        static let width = Knob("ring.aura.width", "Schein: Breite", "Aura", 1...50, 16)
        static let line = Knob("ring.aura.line", "Linie: Stärke", "Aura", 0...10, 3)
        static let base = Knob("ring.aura.base", "Leuchten zwischen den Schlägen", "Aura", 0...1, 0.5)
        static let track = Knob("ring.aura.track", "Spur: Helligkeit", "Aura", 0...0.6, 0.12)
        static let all = general.all + [arcs, spin, tail, seg, radius, blur, width, line, base, track]
    }

    enum Bell {
        static let general = RingGeneral("ring.bell")
        static let swing = Knob("ring.bell.swing", "Schwingen (Grad)", "Glocke", 0...30, 7)
        static let freq = Knob("ring.bell.freq", "Schwingen: Tempo", "Glocke", 0.5...15, 5.5)
        static let damping = Knob("ring.bell.damping", "Schwingen: Dämpfung", "Glocke", 0...6, 1.6)
        static let swingTime = Knob("ring.bell.swingTime", "Schwingen: Dauer (s)", "Glocke", 0.1...3, 1.1)
        static let arcs = Knob("ring.bell.arcs", "Schallbögen", "Schall", 0...8, 3, whole: true)
        static let spread = Knob("ring.bell.spread", "Bogen: Winkel", "Schall", 4...90, 26)
        static let first = Knob("ring.bell.first", "Erster Bogen: Radius", "Schall", 0.7...2, 1.08)
        static let step = Knob("ring.bell.step", "Bogen-Abstand", "Schall", 0.02...0.6, 0.2)
        static let width = Knob("ring.bell.width", "Linienstärke", "Schall", 0.5...10, 3)
        static let alpha = Knob("ring.bell.alpha", "Helligkeit", "Schall", 0...1, 0.75)
        static let delay = Knob("ring.bell.delay", "Versatz je Bogen (s)", "Schall", 0...0.5, 0.13)
        static let arcTime = Knob("ring.bell.arcTime", "Leuchtdauer (s)", "Schall", 0.1...2, 0.75)
        static let all = general.all + [swing, freq, damping, swingTime, arcs, spread, first, step, width, alpha, delay, arcTime]
    }

    static func list(_ s: OrbStyle) -> [Knob] {
        switch s {
        case .jarvis: Jarvis.all
        case .nebula: Nebula.all
        case .wave: Wave.all
        case .orbit: Orbit.all
        case .swirl: Swirl.all
        }
    }

    static func general(_ s: OrbStyle) -> OrbGeneral {
        switch s {
        case .jarvis: Jarvis.general
        case .nebula: Nebula.general
        case .wave: Wave.general
        case .orbit: Orbit.general
        case .swirl: Swirl.general
        }
    }

    static func list(_ s: RingStyle) -> [Knob] {
        switch s {
        case .ripples: Ripples.all
        case .breathe: Breathe.all
        case .orbit: RingOrbit.all
        case .aura: Aura.all
        case .bell: Bell.all
        }
    }

    static func general(_ s: RingStyle) -> RingGeneral {
        switch s {
        case .ripples: Ripples.general
        case .breathe: Breathe.general
        case .orbit: RingOrbit.general
        case .aura: Aura.general
        case .bell: Bell.general
        }
    }

    /// The JARVIS values tuned before knobs were per style (build 30–31's `orbTuning`).
    static func migrated(_ json: Data?) -> Tuning {
        guard let json, let old = try? JSONSerialization.jsonObject(with: json) as? [String: Double] else { return Tuning() }
        let map: [String: Knob] = ["shells": Jarvis.shells, "shellGap": Jarvis.gap, "particles": Jarvis.particles,
                                   "innerFade": Jarvis.innerFade, "twist": Jarvis.twist, "size": Jarvis.general.size,
                                   "dotSize": Jarvis.dot, "rim": Jarvis.rim, "spin": Jarvis.spin, "tilt": Jarvis.tilt,
                                   "reactivity": Jarvis.general.gain, "quiver": Jarvis.quiver, "waves": Jarvis.latWaves,
                                   "waveSpeed": Jarvis.waveSpeed, "breathe": Jarvis.breathe, "sparks": Jarvis.sparks,
                                   "sparkEvery": Jarvis.sparkEvery, "glow": Jarvis.general.glow]
        var t = Tuning()
        for (key, v) in old { if let k = map[key], v != k.value { t.values[k.id] = v } }
        return t
    }
}
