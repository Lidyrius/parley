import SwiftUI
import AppKit

// Floating "listening" pill: a live mic waveform in a capsule at the bottom-center of
// the screen, above every window/space/full-screen app. Shows while recording so the
// user can see they're being heard and when it ends.
@MainActor
final class RecordingHUD: ObservableObject {
    static let barCount = 42
    @Published var levels: [Float] = Array(repeating: 0, count: RecordingHUD.barCount)
    @Published var done = false

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show() {
        hideWork?.cancel()
        done = false
        levels = Array(repeating: 0, count: Self.barCount)
        if panel == nil { panel = makePanel() }
        position()
        panel?.orderFrontRegardless()
    }

    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    /// Show the "done" state briefly, then fade the pill away.
    func finish() {
        done = true
        let work = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 60),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .screenSaver                       // above normal windows
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true                  // never steals clicks
        p.contentView = NSHostingView(rootView: WaveformPill(hud: self))
        return p
    }

    private func position() {
        guard let panel, let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let vf = screen.visibleFrame
        let x = vf.midX - size.width / 2
        let y = vf.minY + 28
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct WaveformPill: View {
    @ObservedObject var hud: RecordingHUD

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: hud.done ? "checkmark.circle.fill" : "mic.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(hud.done ? .green : .red)

            HStack(spacing: 3) {
                ForEach(Array(hud.levels.enumerated()), id: \.offset) { _, l in
                    Capsule()
                        .fill(.white.opacity(0.9))
                        .frame(width: 3, height: max(3, CGFloat(l) * 26))
                }
            }
            .frame(height: 28)
            .animation(.linear(duration: 0.06), value: hud.levels)

            Text(hud.done ? "Fertig" : "Höre zu…")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.72), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        .frame(width: 260, height: 60)
    }
}
