import AppKit

// The app's icon (Einstellungen → App-Symbol). Porzellan · Indigo is the bundle's own — compiled
// from app/AppIcon/Parley.icon by make-app.sh, with its dark, clear and tinted looks. The others take
// its place while Parley runs (NSApp.applicationIconImage: Dock tile, alerts, About); Finder and
// notifications keep the bundle's icon — changing that would break the app's signature.
enum AppIconChoice: String, CaseIterable, Identifiable {
    case porzellan, indigo, graphit, petrol

    var id: Self { self }

    var name: String {
        switch self {
        case .porzellan: "Porzellan"
        case .indigo: "Indigo"
        case .graphit: "Graphit"
        case .petrol: "Petrol"
        }
    }

    /// Its picture, light or dark (Resources/branding/icon-<name>[-dark].png).
    func image(dark: Bool) -> NSImage? {
        Bundle.module.url(forResource: "icon-\(rawValue)\(dark ? "-dark" : "")", withExtension: "png", subdirectory: "branding")
            .flatMap(NSImage.init(contentsOf:))
    }

    static var saved: Self { Keychain.get(.appIcon).flatMap(Self.init(rawValue:)) ?? .porzellan }

    /// Shows it now; called again when the system switches between light and dark.
    @MainActor static func apply(_ choice: Self) {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSApp.applicationIconImage = choice == .porzellan ? nil : choice.image(dark: dark)
    }

    /// The menu-bar symbol (menuleiste.svg) as a template: the menu bar tints it.
    @MainActor static let menuBarImage: NSImage = {
        let image = Bundle.module.url(forResource: "menubar", withExtension: "svg", subdirectory: "branding")
            .flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Parley")!
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()
}
