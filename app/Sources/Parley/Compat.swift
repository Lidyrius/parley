import SwiftUI

// macOS 15.x compatibility. Liquid Glass (.glassEffect / GlassEffectContainer) is
// macOS 26 only; on older systems we fall back to a plain material so the UI is
// functional, just not glassy. One universal binary: 26-only calls stay behind
// #available guards, deployment target is macOS 14.
extension View {
    @ViewBuilder
    func liquidGlass(cornerRadius r: CGFloat) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(in: .rect(cornerRadius: r))
        } else {
            self.background(.regularMaterial, in: .rect(cornerRadius: r))
        }
    }
}

// Drop-in for GlassEffectContainer: groups glass on macOS 26, transparent passthrough
// otherwise.
struct GlassContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer { content() }
        } else {
            content()
        }
    }
}
