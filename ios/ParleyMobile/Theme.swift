import SwiftUI
import UIKit

/// The app's colours, from the palette picked in the settings (Claude's warm neutrals and
/// terracotta by default). Views reading these re-render when the palette changes.
@MainActor
enum Theme {
    static var palette: Palette { Appearance.shared.palette }
    /// The accent (buttons, highlights, the speaking ring) — Claude's terracotta by default.
    static var claude: Color { palette.accent.color }
    static var background: Color { palette.background.color }
    static var card: Color { palette.card.color }
    static let stroke = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 0, alpha: 0.07) })
    static var danger: Color { palette.red.color }
    /// Text and symbols on an accent fill: black on a light accent (Schwarzweiß dark), else white.
    static var onAccent: Color { palette.accent.onColor }
    /// Switches and other controls drawn in the accent: a near-white accent turns grey, so the
    /// white knob still shows.
    static var control: Color { palette.accent.controlColor }
    /// The accent a touch lighter: the top of the accent's gradients.
    static var claudeLight: Color { palette.accent.mixed(with: Shade(0xFFFFFF), 0.15).color }

    // The session view, after the Claude app's chat.
    static var userBubble: Color { palette.raised.color }
    static var codeText: Color { palette.working.ink }
    static var codeBackground: Color { palette.raised.color }
    static var codeBlock: Color { palette.background.mixed(with: palette.raised).color }
    static let diffAdd = Color(light: 0x1A7F37, dark: 0x4CC764)
    static let diffAddBackground = Color(light: 0xDDF4E3, dark: 0x183A22)
    static let diffDel = Color(light: 0xCF222E, dark: 0xF06A6A)
    static let diffDelBackground = Color(light: 0xFFE3E3, dark: 0x3F1C1E)
}

/// The picked palette, remembered across launches.
@MainActor @Observable
final class Appearance {
    static let shared = Appearance()
    static let key = "palette"

    var paletteID = UserDefaults.standard.string(forKey: key) ?? Palette.claude.id {
        didSet {
            UserDefaults.standard.set(paletteID, forKey: Self.key)
            applyScheme()
            publishColors()
        }
    }

    var palette: Palette { (Palette.all + Palette.classics + customPalettes).first { $0.id == paletteID } ?? .claude }

    /// Palettes built in the developer mode's editor, remembered.
    var customPalettes: [Palette] = (try? JSONDecoder().decode([Palette].self,
                                                               from: UserDefaults.standard.data(forKey: "customPalettes") ?? Data())) ?? [] {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(customPalettes), forKey: "customPalettes")
            publishColors()
        }
    }

    /// The palette's state colours for the Island, the Lock Screen and the controls (App Group).
    func publishColors() {
        let p = palette
        func pair(_ s: Shade) -> [UInt32] { [s.light, s.dark] }
        SharedState.colors = StateColors(accent: pair(p.accent), waiting: pair(p.waiting), working: pair(p.working),
                                         purple: pair(p.purple), idle: pair(p.idle), stopped: pair(p.stopped))
    }

    /// A palette made by voice: replaces an own one of the same name (keeping its id), else joins
    /// them — and is picked.
    func adopt(_ p: Palette) {
        var p = p
        p.id = customPalettes.first { $0.name.caseInsensitiveCompare(p.name) == .orderedSame }?.id
            ?? "custom-" + UUID().uuidString.prefix(8).lowercased()
        save(p)
    }

    /// Adds or replaces a custom palette and picks it.
    func save(_ p: Palette) {
        if let i = customPalettes.firstIndex(where: { $0.id == p.id }) { customPalettes[i] = p } else { customPalettes.append(p) }
        paletteID = p.id
    }

    func delete(_ id: String) {
        customPalettes.removeAll { $0.id == id }
        if paletteID == id { paletteID = Palette.claude.id }
    }

    /// Light, dark, or as the iPhone is set — the app's own choice.
    var scheme = SchemeChoice(rawValue: UserDefaults.standard.string(forKey: "scheme") ?? "") ?? .system {
        didSet {
            UserDefaults.standard.set(scheme.rawValue, forKey: "scheme")
            applyScheme()
        }
    }

    /// Set on the windows themselves (sheets and the call screen follow); SwiftUI's
    /// `preferredColorScheme(nil)` doesn't reliably hand back to the system.
    func applyScheme() {
        for scene in UIApplication.shared.connectedScenes {
            for window in (scene as? UIWindowScene)?.windows ?? [] {
                window.overrideUserInterfaceStyle = palette.alwaysDark ? .dark : scheme.style
            }
        }
    }

    /// The animations' knobs (developer mode), remembered. JARVIS values tuned in builds 30–31
    /// come along.
    var tuning: Tuning = (try? JSONDecoder().decode(Tuning.self, from: UserDefaults.standard.data(forKey: "tuning") ?? Data()))
        ?? Knobs.migrated(UserDefaults.standard.data(forKey: "orbTuning")) {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(tuning), forKey: "tuning") }
    }

    /// What Parley looks like in a call.
    var orbStyle = OrbStyle(rawValue: UserDefaults.standard.string(forKey: "orbStyle") ?? "") ?? .jarvis {
        didSet { UserDefaults.standard.set(orbStyle.rawValue, forKey: "orbStyle") }
    }

    /// How an incoming call moves around the caller's ring.
    var ringStyle = RingStyle(rawValue: UserDefaults.standard.string(forKey: "ringStyle") ?? "") ?? .ripples {
        didSet { UserDefaults.standard.set(ringStyle.rawValue, forKey: "ringStyle") }
    }

    /// How line charts build up on a slide.
    var lineReveal = LineReveal(rawValue: UserDefaults.standard.string(forKey: "lineReveal") ?? "") ?? .draw {
        didSet { UserDefaults.standard.set(lineReveal.rawValue, forKey: "lineReveal") }
    }
}

enum SchemeChoice: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: "System"
        case .light: "Hell"
        case .dark: "Dunkel"
        }
    }

    var style: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}

/// A colour for light and for dark mode.
struct Shade: Codable, Equatable, Sendable {
    var light: UInt32
    var dark: UInt32

    init(_ light: UInt32, _ dark: UInt32) { self.light = light; self.dark = dark }
    init(_ both: UInt32) { self.init(both, both) }

    var color: Color { Color(light: light, dark: dark) }
    /// As text: a darker shade in light mode, so it stays readable on white.
    var ink: Color { Color(light: Self.mix(light, 0x000000, 0.22), dark: dark) }

    /// Black or white, whichever reads on this colour in each mode.
    var onColor: Color { Color(light: Self.luminance(light) > 0.5 ? 0x000000 : 0xFFFFFF,
                               dark: Self.luminance(dark) > 0.5 ? 0x000000 : 0xFFFFFF) }

    var controlColor: Color { Color(light: Self.luminance(light) > 0.8 ? 0x8E8E93 : light,
                                    dark: Self.luminance(dark) > 0.8 ? 0x8E8E93 : dark) }

    /// Relative luminance (WCAG), 0 black … 1 white.
    static func luminance(_ c: UInt32) -> Double {
        func lin(_ v: UInt32) -> Double {
            let x = Double(v & 0xFF) / 255
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c >> 16) + 0.7152 * lin(c >> 8) + 0.0722 * lin(c)
    }

    func mixed(with other: Shade, _ f: Double = 0.5) -> Shade {
        Shade(Self.mix(light, other.light, f), Self.mix(dark, other.dark, f))
    }

    static func mix(_ a: UInt32, _ b: UInt32, _ f: Double) -> UInt32 {
        [16, 8, 0].reduce(0) { out, shift in
            let x = Double((a >> shift) & 0xFF), y = Double((b >> shift) & 0xFF)
            return out | UInt32((x + (y - x) * f).rounded()) << shift
        }
    }
}

/// A colour palette for the whole app: neutrals for both modes, the accent, and the colours the
/// session states keep in every palette (waiting yellow, working blue, idle green …).
struct Palette: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var note: String
    var background: Shade
    var card: Shade
    var raised: Shade      // the user's bubble, inline code
    var accent: Shade
    var waiting: Shade     // yellow
    var working: Shade     // blue
    var purple: Shade      // running in the background
    var idle: Shade        // green
    var stopped: Shade     // grey
    var red: Shade
    var alwaysDark = false   // the night light: dark whatever the setting

    static let claude = Palette(
        id: "claude", name: "Claude", note: "Warmes Papier und Terrakotta, wie die Claude-App",
        background: Shade(0xFAF9F5, 0x191918), card: Shade(0xFFFFFF, 0x262624), raised: Shade(0xF0EEE6, 0x30302E),
        accent: Shade(0xD97757), waiting: Shade(0xD9A43B), working: Shade(0x5B8DEF), purple: Shade(0x9B87F5),
        idle: Shade(0x4EBA65), stopped: Shade(0x8B8A85), red: Shade(0xE5484D))

    /// The picker's palettes: Claude, then looks after apps everyone knows (their brand and UI
    /// colours, researched 2026-10-17 — Discord's and WhatsApp's from their brand pages and UI)
    /// and two Apple Design Award 2026 winners, plus black-and-white and a night light.
    /// The accent and the state colours stay apart in both modes (FrameTests checks).
    static let all: [Palette] = [
        claude,
        Palette(id: "mono", name: "Schwarzweiß", note: "Nur Schwarz, Weiß und Grautöne – dunkel mit echtem Schwarz",
                background: Shade(0xF5F5F5, 0x000000), card: Shade(0xFFFFFF, 0x111111), raised: Shade(0xEAEAEA, 0x1E1E1E),
                accent: Shade(0x000000, 0xFFFFFF), waiting: Shade(0x7C7C80, 0x98989D), working: Shade(0x48484A, 0xC7C7CC),
                purple: Shade(0x636366, 0xAEAEB2), idle: Shade(0xA8A8AD, 0x6C6C70), stopped: Shade(0xD1D1D6, 0x3A3A3C),
                red: Shade(0x1C1C1E, 0xF2F2F7)),
        Palette(id: "nightlight", name: "Nachtlicht", note: "Gedämpftes Rot auf Schwarz für nachts im Auto – immer dunkel",
                background: Shade(0x080605), card: Shade(0x15100D), raised: Shade(0x1F1814),
                accent: Shade(0xC2401C), waiting: Shade(0x9E6C1C), working: Shade(0x6E5A9A),
                purple: Shade(0x8F4A6B), idle: Shade(0x5D7E37), stopped: Shade(0x4F4640),
                red: Shade(0xB3261E), alwaysDark: true),
        Palette(id: "chat", name: "Chat", note: "Teal, frisches Grün und grüne Blasen, nach WhatsApp",
                background: Shade(0xEFEAE2, 0x0B141A), card: Shade(0xFFFFFF, 0x202C33), raised: Shade(0xD9FDD3, 0x005C4B),
                accent: Shade(0x008069, 0x00A884), waiting: Shade(0xD08C00, 0xFFD279), working: Shade(0x027EB5, 0x53BDEB),
                purple: Shade(0x7F66FF, 0xA891FF), idle: Shade(0x25D366), stopped: Shade(0x8696A0, 0x667781),
                red: Shade(0xEA0038, 0xF15C6D)),
        Palette(id: "messages", name: "Nachrichten", note: "Blaue und grüne Blasen auf Weiß oder Schwarz, nach Apples Nachrichten",
                background: Shade(0xF2F2F7, 0x000000), card: Shade(0xFFFFFF, 0x1C1C1E), raised: Shade(0xE9E9EB, 0x262628),
                accent: Shade(0x007AFF, 0x0A84FF), waiting: Shade(0xFF9500, 0xFF9F0A), working: Shade(0x5856D6, 0x5E5CE6),
                purple: Shade(0xAF52DE, 0xBF5AF2), idle: Shade(0x34C759, 0x30D158), stopped: Shade(0x8E8E93, 0x98989D),
                red: Shade(0xFF3B30, 0xFF453A)),
        Palette(id: "silver", name: "Silber", note: "Kühles Silbergrau und Apple-Blau, nach Safari und apple.com",
                background: Shade(0xF5F5F7, 0x161617), card: Shade(0xFFFFFF, 0x1D1D1F), raised: Shade(0xE8E8ED, 0x2C2C2E),
                accent: Shade(0x0071E3, 0x2997FF), waiting: Shade(0xB64400, 0xF5A623), working: Shade(0x0A8A8A, 0x40C8C8),
                purple: Shade(0x8944AB, 0xBF5AF2), idle: Shade(0x248A3D, 0x30D158), stopped: Shade(0x86868B, 0x6E6E73),
                red: Shade(0xE30000, 0xFF453A)),
        Palette(id: "blurple", name: "Blurple", note: "Das Lila-Blau von Discord auf Schiefergrau",
                background: Shade(0xF2F3F5, 0x313338), card: Shade(0xFFFFFF, 0x2B2D31), raised: Shade(0xE3E5E8, 0x383A40),
                accent: Shade(0x5865F2), waiting: Shade(0xF0B232), working: Shade(0x00A8FC),
                purple: Shade(0xEB459E), idle: Shade(0x23A55A), stopped: Shade(0x80848E),
                red: Shade(0xDA373C, 0xF23F43)),
        Palette(id: "google", name: "Google", note: "Googles vier Farben auf Chromes Grau",
                background: Shade(0xF1F3F4, 0x202124), card: Shade(0xFFFFFF, 0x292A2D), raised: Shade(0xE8EAED, 0x35363A),
                accent: Shade(0x1A73E8, 0x8AB4F8), waiting: Shade(0xF9AB00, 0xFDD663), working: Shade(0xA142F4, 0xC58AF9),
                purple: Shade(0x12B5CB, 0x78D9EC), idle: Shade(0x1E8E3E, 0x81C995), stopped: Shade(0x5F6368, 0x9AA0A6),
                red: Shade(0xD93025, 0xF28B82)),
        Palette(id: "green-on-black", name: "Grün auf Schwarz", note: "Kräftiges Grün auf tiefem Schwarz, nach Spotify",
                background: Shade(0xF6F6F6, 0x121212), card: Shade(0xFFFFFF, 0x181818), raised: Shade(0xEBEBEB, 0x282828),
                accent: Shade(0x1DB954), waiting: Shade(0xFFA42B), working: Shade(0x509BF5),
                purple: Shade(0xAF2896, 0xD84DBA), idle: Shade(0x191414, 0xFFFFFF), stopped: Shade(0xA7A7A7, 0x727272),
                red: Shade(0xE22134, 0xF15E6C)),
        Palette(id: "sunset", name: "Sonnenuntergang", note: "Pink, Lila und Orange aus Instagrams Verlauf",
                background: Shade(0xFAFAFA, 0x000000), card: Shade(0xFFFFFF, 0x121212), raised: Shade(0xEFEFEF, 0x262626),
                accent: Shade(0xD62976, 0xE1306C), waiting: Shade(0xFA7E1E, 0xFEA54B), working: Shade(0x4F5BD5, 0x7B86F0),
                purple: Shade(0x962FBF, 0xB65CDB), idle: Shade(0x58C322), stopped: Shade(0x8E8E8E, 0x737373),
                red: Shade(0xED4956)),
        Palette(id: "tides", name: "Gezeiten", note: "Sand, Nachtblau und eine Korallen-Sonne, nach Tide Guide (Apple Design Award 2026)",
                background: Shade(0xF3EEE6, 0x0B1626), card: Shade(0xFFFCF7, 0x13233A), raised: Shade(0xE8DFD2, 0x1C3150),
                accent: Shade(0xE0613F, 0xF5916F), waiting: Shade(0xC98A1B, 0xEAC25A), working: Shade(0x2F7FD8, 0x5FA8F5),
                purple: Shade(0x6E5FD0, 0x9C8FF0), idle: Shade(0x2E9E86, 0x49C2A6), stopped: Shade(0x8A8F99, 0x6B7A90),
                red: Shade(0xC93636, 0xF06464)),
        Palette(id: "moonlight", name: "Mondlicht", note: "Indigo-Nacht und Mondgold, nach Moonlitt (Apple Design Award 2026)",
                background: Shade(0xF1F0FA, 0x12142E), card: Shade(0xFFFFFF, 0x1B1E40), raised: Shade(0xE4E2F5, 0x262A55),
                accent: Shade(0x5B5BD6, 0xA5A8FF), waiting: Shade(0xB07A12, 0xF2C46D), working: Shade(0x2F80C9, 0x6CB4F5),
                purple: Shade(0xB04FC8, 0xD18BEA), idle: Shade(0x2E9E6B, 0x6BD3A0), stopped: Shade(0x8A89A6, 0x6F7096),
                red: Shade(0xD64563, 0xF07A93)),
    ]

    /// The earlier editor palettes, still selectable under "Klassiker": official light and dark
    /// flavours (hex values from each palette's own repo); where a palette's own hues sit too
    /// close, a neighbouring hue of the same palette steps in.
    static let classics: [Palette] = [
        Palette(id: "catppuccin", name: "Catppuccin", note: "Pastell auf weichem Grau (Latte / Mocha)",
                background: Shade(0xEFF1F5, 0x1E1E2E), card: Shade(0xFFFFFF, 0x313244), raised: Shade(0xE6E9EF, 0x45475A),
                accent: Shade(0x8839EF, 0xCBA6F7), waiting: Shade(0xDF8E1D, 0xF9E2AF), working: Shade(0x1E66F5, 0x89B4FA),
                purple: Shade(0xEA76CB, 0xF5C2E7), idle: Shade(0x40A02B, 0xA6E3A1), stopped: Shade(0x8C8FA1, 0x7F849C),
                red: Shade(0xD20F39, 0xF38BA8)),
        Palette(id: "nord", name: "Nord", note: "Kühles Polarblau, ruhig und klar",
                background: Shade(0xECEFF4, 0x2E3440), card: Shade(0xFFFFFF, 0x3B4252), raised: Shade(0xE5E9F0, 0x434C5E),
                accent: Shade(0x5E81AC, 0x88C0D0), waiting: Shade(0xD08770, 0xEBCB8B), working: Shade(0xB48EAD),
                purple: Shade(0x81A1C1), idle: Shade(0xA3BE8C), stopped: Shade(0x4C566A, 0x7B88A1),
                red: Shade(0xBF616A)),
        Palette(id: "rose-pine", name: "Rosé Pine", note: "Gedämpftes Rosé und Kiefer (Dawn / Main)",
                background: Shade(0xFAF4ED, 0x191724), card: Shade(0xFFFAF3, 0x1F1D2E), raised: Shade(0xF2E9E1, 0x26233A),
                accent: Shade(0xD7827E, 0xEBBCBA), waiting: Shade(0xEA9D34, 0xF6C177), working: Shade(0x286983, 0x31748F),
                purple: Shade(0x907AA9, 0xC4A7E7), idle: Shade(0x56949F, 0x9CCFD8), stopped: Shade(0x9893A5, 0x6E6A86),
                red: Shade(0xB4637A, 0xEB6F92)),
        Palette(id: "solarized", name: "Solarized", note: "Der Klassiker: präzise abgestimmte Kontraste",
                background: Shade(0xFDF6E3, 0x002B36), card: Shade(0xFFFBF0, 0x073642), raised: Shade(0xEEE8D5, 0x0D4351),
                accent: Shade(0xCB4B16), waiting: Shade(0xB58900), working: Shade(0x268BD2),
                purple: Shade(0x6C71C4), idle: Shade(0x2AA198), stopped: Shade(0x93A1A1, 0x586E75),
                red: Shade(0xDC322F)),
        Palette(id: "gruvbox", name: "Gruvbox", note: "Retro und erdig, warmes Kontrastbraun",
                background: Shade(0xFBF1C7, 0x282828), card: Shade(0xF9F5D7, 0x3C3836), raised: Shade(0xEBDBB2, 0x504945),
                accent: Shade(0xAF3A03, 0xFE8019), waiting: Shade(0xB57614, 0xFABD2F), working: Shade(0x076678, 0x83A598),
                purple: Shade(0x8F3F71, 0xD3869B), idle: Shade(0x79740E, 0xB8BB26), stopped: Shade(0x928374, 0x7C6F64),
                red: Shade(0x9D0006, 0xFB4934)),
        Palette(id: "tokyo-night", name: "Tokyo Night", note: "Neonlichter einer Stadt bei Nacht (Day / Night)",
                background: Shade(0xE1E2E7, 0x1A1B26), card: Shade(0xF3F3F6, 0x24283B), raised: Shade(0xD5D6DB, 0x292E42),
                accent: Shade(0x9854F1, 0xBB9AF7), waiting: Shade(0xB15C00, 0xE0AF68), working: Shade(0x2E7DE9, 0x7AA2F7),
                purple: Shade(0x007197, 0x7DCFFF), idle: Shade(0x587539, 0x9ECE6A), stopped: Shade(0x848CB5, 0x565F89),
                red: Shade(0xF52A65, 0xF7768E)),
        Palette(id: "dracula", name: "Dracula", note: "Kräftige Farben auf Violettgrau (Alucard / Dracula)",
                background: Shade(0xFFFBEB, 0x282A36), card: Shade(0xFFFFFF, 0x343746), raised: Shade(0xEFEDDC, 0x44475A),
                accent: Shade(0xA3144D, 0xFF79C6), waiting: Shade(0x846E15, 0xF1FA8C), working: Shade(0x036A96, 0x8BE9FD),
                purple: Shade(0x644AC9, 0xBD93F9), idle: Shade(0x14710A, 0x50FA7B), stopped: Shade(0x9A9690, 0x6272A4),
                red: Shade(0xCB3A2A, 0xFF5555)),
        Palette(id: "kanagawa", name: "Kanagawa", note: "Nach Hokusais Welle: Tinte, Kirschblüte, Herbst",
                background: Shade(0xF2ECBC, 0x1F1F28), card: Shade(0xF8F3D2, 0x2A2A37), raised: Shade(0xE5DDB0, 0x363646),
                accent: Shade(0xB35B79, 0xD27E99), waiting: Shade(0xCC6D00, 0xE6C384), working: Shade(0x4D699B, 0x7E9CD8),
                purple: Shade(0x624C83, 0x957FB8), idle: Shade(0x6F894E, 0x98BB6C), stopped: Shade(0xA09F96, 0x727169),
                red: Shade(0xE82424, 0xFF5D62)),
        Palette(id: "primer", name: "GitHub", note: "Neutrales Grau mit GitHub-Blau, ohne Farbstich",
                background: Shade(0xF6F8FA, 0x0D1117), card: Shade(0xFFFFFF, 0x151B23), raised: Shade(0xEFF2F5, 0x212830),
                accent: Shade(0x0969DA, 0x4493F8), waiting: Shade(0x9A6700, 0xD29922), working: Shade(0x8250DF, 0xAB7DF8),
                purple: Shade(0xBF3989, 0xDB61A2), idle: Shade(0x1A7F37, 0x3FB950), stopped: Shade(0x59636E, 0x9198A1),
                red: Shade(0xD1242F, 0xF85149)),
    ]

    /// Pairs of rings too alike to tell apart, per mode ("Hell: Akzent ~ Wartet"); FrameTests
    /// requires none for the shipped palettes, the editor shows them as hints.
    var clashes: [String] {
        let rings: [(String, Shade)] = [("Akzent", accent), ("Wartet", waiting), ("Arbeitet", working),
                                        ("Bereit", idle), ("Gestoppt", stopped)]
        var out: [String] = []
        for (mode, pick) in [("Hell", \Shade.light), ("Dunkel", \Shade.dark)] where !(mode == "Hell" && alwaysDark) {
            for i in rings.indices {
                for j in rings.indices where j > i && !Self.far(rings[i].1[keyPath: pick], rings[j].1[keyPath: pick]) {
                    out.append("\(mode): \(rings[i].0) und \(rings[j].0) sind kaum zu unterscheiden")
                }
            }
            if !Self.far(background[keyPath: pick], accent[keyPath: pick]) { out.append("\(mode): Akzent hebt sich kaum vom Hintergrund ab") }
        }
        return out
    }

    /// Far enough apart to tell at a glance (RGB distance > 50).
    static func far(_ a: UInt32, _ b: UInt32) -> Bool {
        let d = [16, 8, 0].map { Double(Int((a >> $0) & 0xFF) - Int((b >> $0) & 0xFF)) }
        return d.map { $0 * $0 }.reduce(0, +).squareRoot() > 50
    }

    /// Six distinct colours for charts (the pie's slices).
    var series: [Shade] { [accent, working, idle, waiting, purple, stopped] }
}

extension SessionState {
    /// The ring's colour.
    @MainActor var color: Color { shade.color }

    /// The label's colour: a darker shade in light mode so the text stays readable on white.
    @MainActor var ink: Color { shade.ink }

    /// Text or a symbol on a fill of this colour: black or white, whichever reads (light palettes too).
    @MainActor var onColor: Color { shade.onColor }

    @MainActor private var shade: Shade {
        let p = Theme.palette
        return switch self {
        case .speaking, .listening, .transcribing: p.accent
        case .queued, .waiting: p.waiting
        case .working: p.working
        case .background: p.purple
        case .parked, .stopped: p.stopped
        case .idle: p.idle
        }
    }
}

extension ConnectionStatus {
    @MainActor var color: Color {
        switch self {
        case .connected: SessionState.idle.color
        case .connecting: SessionState.waiting.color
        case .hostOffline, .unknownRoom: SessionState.stopped.color
        case .rejected, .unreachable: Theme.danger
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(uiColor: UIColor(hex: hex))
    }

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

extension Color {
    /// The colour as 0xRRGGBB (sRGB, clamped) — what the palette editor stores.
    var hex: UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return c(r) << 16 | c(g) << 8 | c(b)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension AttributedString {
    /// A run for inline-styled lines ("**value** label", "state · time").
    static func run(_ text: String, _ color: Color? = nil, bold: Bool = false) -> AttributedString {
        var s = AttributedString(text)
        if let color { s.swiftUI.foregroundColor = color }
        if bold { s.inlinePresentationIntent = .stronglyEmphasized }
        return s
    }
}
