import SwiftUI

/// First launch: pair with the host by scanning its QR code or pasting the link
/// (design A2 "Silhouetten-Echo", docs/design/screens/ios/40-kopplung).
struct PairingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var error: String?
    @State private var showsScanner = ProcessInfo.processInfo.arguments.contains("-demoScanner")

    /// The icon's outline repeated outwards: size (pt), opacity, line width.
    private static let echo: [(size: CGFloat, alpha: Double, width: CGFloat)] =
        [(176, 0.50, 2), (232, 0.34, 1.75), (300, 0.22, 1.5), (380, 0.13, 1.25), (470, 0.07, 1)]

    var body: some View {
        VStack(spacing: 0) {
            AppIconImage(size: 128)
                .background {
                    // Outside the layout: the outer ones may run over the screen's edge.
                    ForEach(Self.echo, id: \.size) { e in
                        IconShape()
                            .stroke(Theme.claude.opacity(e.alpha * (scheme == .light ? 1.5 : 1)), lineWidth: e.width)
                            .frame(width: e.size, height: e.size)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)

            VStack(spacing: 22) {
                VStack(spacing: 8) {
                    Text("Guten Tag, Sir.")
                        .font(.largeTitle.bold())
                    Text("Ein Code vom Mac, und Ihre Sessions sind hier.")
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)

                HintCard(symbol: "desktopcomputer", title: "Auf dem Mac",
                         detail: "Parley-Menü → „Handy\u{00A0}verbinden…\u{2060}“")   // keeps the menu name in one piece

                VStack(spacing: 14) {
                    Button { showsScanner = true } label: {
                        Label("Code scannen", systemImage: "qrcode.viewfinder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .foregroundStyle(Theme.onAccent)
                            .background(Capsule().fill(Theme.claude))
                    }
                    .buttonStyle(.plain)

                    Button { error = pasteAndPair(model) } label: {
                        Label("Link einfügen", systemImage: "doc.on.clipboard")
                            .font(.headline)
                            .foregroundStyle(Theme.claude)
                    }
                    .buttonStyle(.plain)

                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }

                Label("Verschlüsselt · nur Ihr Mac und Ihr iPhone", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
            .frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(Theme.background)
        .fullScreenCover(isPresented: $showsScanner) { ScannerSheet() }
    }
}

/// Reads a pairing link from the clipboard and pairs with it; the error message, or nil.
@MainActor func pasteAndPair(_ model: AppModel) -> String? {
    guard let text = UIPasteboard.general.string, !text.isEmpty else {
        return "In der Zwischenablage ist kein Link. Kopieren Sie ihn am Mac unter „Handy verbinden…“."
    }
    do { try model.pair(text); return nil } catch { return error.localizedDescription }
}

/// The app icon's outline: a continuous rounded square, 22.5 % corners.
struct IconShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.225, style: .continuous)
    }
}

/// The icon Sir chose (Settings → App-Symbol), as the app shows it on the Home Screen.
struct AppIconImage: View {
    let size: CGFloat

    var body: some View {
        Image(AppIconChoice.current.preview)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(IconShape())
            .shadow(color: .black.opacity(0.35), radius: size * 0.14, y: size * 0.06)
    }
}

/// One line of help as a card: a symbol on a clay tile, a title, a detail.
struct HintCard: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.claude)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.claude.opacity(0.18)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.stroke))
        .accessibilityElement(children: .combine)
    }
}
