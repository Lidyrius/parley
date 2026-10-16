import SwiftUI
import UIKit

/// Colours of the mod's overview (STATE hex values) on the Claude desktop's warm neutrals.
enum Theme {
    static let claude = Color(hex: 0xD97757)
    static let background = Color(light: 0xFAF9F5, dark: 0x191918)
    static let card = Color(light: 0xFFFFFF, dark: 0x262624)
    static let stroke = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 0, alpha: 0.07) })
}

extension SessionState {
    /// The ring's colour (same in both modes, as in the mod).
    var color: Color {
        switch self {
        case .speaking, .listening, .transcribing: Theme.claude
        case .queued, .waiting: Color(hex: 0xD9A43B)
        case .working: Color(hex: 0x5B8DEF)
        case .background: Color(hex: 0x9B87F5)
        case .parked, .stopped: Color(hex: 0x8B8A85)
        case .idle: Color(hex: 0x4EBA65)
        }
    }

    /// The label's colour: a darker shade in light mode so the text stays readable on white.
    var ink: Color {
        switch self {
        case .speaking, .listening, .transcribing: Color(light: 0xB8583A, dark: 0xD97757)
        case .queued, .waiting: Color(light: 0x9A6B12, dark: 0xD9A43B)
        case .working: Color(light: 0x3363C9, dark: 0x6F9BF2)
        case .background: Color(light: 0x6E57D9, dark: 0xA897F7)
        case .parked, .stopped: Color(light: 0x6E6D68, dark: 0x9A9993)
        case .idle: Color(light: 0x2E8A45, dark: 0x5CC573)
        }
    }
}

extension ConnectionStatus {
    var color: Color {
        switch self {
        case .connected: SessionState.idle.color
        case .connecting: SessionState.waiting.color
        case .hostOffline, .unknownRoom: SessionState.stopped.color
        case .rejected, .unreachable: Color(hex: 0xE5484D)
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
