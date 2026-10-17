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
        didSet { UserDefaults.standard.set(paletteID, forKey: Self.key) }
    }

    var palette: Palette { Palette.all.first { $0.id == paletteID } ?? .claude }

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

/// A colour for light and for dark mode.
struct Shade: Equatable, Sendable {
    let light: UInt32
    let dark: UInt32

    init(_ light: UInt32, _ dark: UInt32) { self.light = light; self.dark = dark }
    init(_ both: UInt32) { self.init(both, both) }

    var color: Color { Color(light: light, dark: dark) }
    /// As text: a darker shade in light mode, so it stays readable on white.
    var ink: Color { Color(light: Self.mix(light, 0x000000, 0.22), dark: dark) }

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
struct Palette: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let note: String
    let background: Shade
    let card: Shade
    let raised: Shade      // the user's bubble, inline code
    let accent: Shade
    let waiting: Shade     // yellow
    let working: Shade     // blue
    let purple: Shade      // running in the background
    let idle: Shade        // green
    let stopped: Shade     // grey
    let red: Shade

    static let claude = Palette(
        id: "claude", name: "Claude", note: "Warmes Papier und Terrakotta, wie die Claude-App",
        background: Shade(0xFAF9F5, 0x191918), card: Shade(0xFFFFFF, 0x262624), raised: Shade(0xF0EEE6, 0x30302E),
        accent: Shade(0xD97757), waiting: Shade(0xD9A43B), working: Shade(0x5B8DEF), purple: Shade(0x9B87F5),
        idle: Shade(0x4EBA65), stopped: Shade(0x8B8A85), red: Shade(0xE5484D))

    // The others: well-known editor palettes in their official light and dark flavours (hex values
    // from each palette's own repo). The accent and the state colours stay apart in both modes —
    // where a palette's own hues sit too close, a neighbouring hue of the same palette steps in.
    static let all: [Palette] = [
        claude,
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

    /// Six distinct colours for charts (the pie's slices).
    var series: [Shade] { [accent, working, idle, waiting, purple, stopped] }
}

extension SessionState {
    /// The ring's colour.
    @MainActor var color: Color { shade.color }

    /// The label's colour: a darker shade in light mode so the text stays readable on white.
    @MainActor var ink: Color { shade.ink }

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
