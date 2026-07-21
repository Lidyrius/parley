import SwiftUI
import AppKit

// Floating "listening" pill: a live mic waveform + a volume-pulsing orb in a capsule
// at the bottom-center of the screen, above every window / space / full-screen app.
// Rendered with Canvas inside TimelineView(.animation) → redraws at the display refresh
// (60/120fps), with per-frame easing so motion stays smooth even though raw mic level
// samples arrive only ~30×/s. Shows while recording, then a brief "done" state.
@MainActor
final class RecordingHUD: ObservableObject {
    static let barCount = 56

    // Plain state, eased + read inside the animation frame (not @Published — the
    // TimelineView already redraws every frame, so we avoid publish churn).
    fileprivate var target = [Float](repeating: 0, count: RecordingHUD.barCount)
    fileprivate var display = [Float](repeating: 0, count: RecordingHUD.barCount)
    fileprivate var latest: Float = 0
    fileprivate var orb: Float = 0

    @Published var done = false

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show() {
        hideWork?.cancel()
        done = false
        target = .init(repeating: 0, count: Self.barCount)
        display = .init(repeating: 0, count: Self.barCount)
        latest = 0; orb = 0
        if panel == nil { panel = makePanel() }
        position()
        panel?.orderFrontRegardless()
    }

    func push(_ level: Float) {
        target.removeFirst(); target.append(level)
        if level > latest { latest = level }   // fast attack for the orb
    }

    // Eased one frame; called from the Canvas renderer each display refresh.
    fileprivate func step() {
        for i in display.indices { display[i] += (target[i] - display[i]) * 0.35 }
        orb += (latest - orb) * 0.30
        latest *= 0.86                          // release so the orb settles when quiet
    }

    func finish() {
        done = true
        let work = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 64),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.contentView = NSHostingView(rootView: WaveformPill(hud: self))
        return p
    }

    private func position() {
        guard let panel, let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let vf = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 30))
    }
}

private struct WaveformPill: View {
    @ObservedObject var hud: RecordingHUD

    var body: some View {
        ZStack {
            Capsule().fill(.black.opacity(0.74))
            Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1)
            TimelineView(.animation) { _ in
                Canvas { ctx, size in
                    hud.step()
                    render(ctx, size, done: hud.done)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
        .frame(width: 340, height: 64)
    }

    private func render(_ ctx: GraphicsContext, _ size: CGSize, done: Bool) {
        let cy = size.height / 2
        let accent = done ? Color.green : Color.red

        // Left: volume-pulsing orb with a soft glow.
        let orbR = 6 + CGFloat(min(1, hud.orb)) * 11
        let cx = orbR
        ctx.fill(Path(ellipseIn: CGRect(x: cx - orbR - 7, y: cy - orbR - 7,
                                        width: (orbR + 7) * 2, height: (orbR + 7) * 2)),
                 with: .color(accent.opacity(0.16)))
        ctx.fill(Path(ellipseIn: CGRect(x: cx - orbR, y: cy - orbR, width: orbR * 2, height: orbR * 2)),
                 with: .radialGradient(
                    Gradient(colors: [accent.opacity(0.95), accent.opacity(0.6)]),
                    center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: orbR))

        // Right: the waveform bars.
        let left = cx + 18 + 12
        let right = size.width
        let n = hud.display.count
        guard right > left, n > 0 else { return }
        let slot = (right - left) / CGFloat(n)
        let barW = max(2, slot * 0.55)
        let maxH = size.height - 6
        for i in 0..<n {
            let x = left + slot * CGFloat(i) + (slot - barW) / 2
            let h = max(barW, CGFloat(min(1, hud.display[i])) * maxH)
            let rect = CGRect(x: x, y: cy - h / 2, width: barW, height: h)
            ctx.fill(Path(roundedRect: rect, cornerRadius: barW / 2), with: .color(.white.opacity(0.92)))
        }
    }
}
