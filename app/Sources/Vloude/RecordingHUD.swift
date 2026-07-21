import SwiftUI
import AppKit

// Floating "listening" pill: a live mic waveform + a volume-pulsing orb in a capsule at
// the bottom-center of the screen, above every window / space / full-screen app.
//
// Animation is driven by a 60 Hz timer that eases state and bumps a @Published tick —
// NOT TimelineView(.animation), which does not run in a non-key / nonactivating NSPanel
// (so the waveform never moved while recording). State-change redraws work regardless
// of window focus.
@MainActor
final class RecordingHUD: ObservableObject {
    static let barCount = 56

    fileprivate var target = [Float](repeating: 0, count: RecordingHUD.barCount)
    fileprivate var display = [Float](repeating: 0, count: RecordingHUD.barCount)
    fileprivate var latest: Float = 0
    fileprivate var orb: Float = 0
    @Published fileprivate var tick: Int = 0
    @Published var done = false

    private var panel: NSPanel?
    private var timer: DispatchSourceTimer?
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
        startTimer()
    }

    func push(_ level: Float) {
        target.removeFirst(); target.append(level)
        if level > latest { latest = level }   // fast attack for the orb
    }

    func finish() {
        done = true
        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
            self?.stopTimer()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func startTimer() {
        stopTimer()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / 60.0)
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for i in self.display.indices { self.display[i] += (self.target[i] - self.display[i]) * 0.35 }
                self.orb += (self.latest - self.orb) * 0.30
                self.latest *= 0.86                  // release so the orb settles when quiet
                self.tick &+= 1                      // publish → redraw
            }
        }
        timer = t
        t.resume()
    }

    private func stopTimer() {
        timer?.cancel(); timer = nil
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
            Canvas { ctx, size in
                _ = hud.tick               // redraw on every timer tick
                render(ctx, size, done: hud.done)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 340, height: 64)
    }

    private func render(_ ctx: GraphicsContext, _ size: CGSize, done: Bool) {
        let cy = size.height / 2
        let accent = done ? Color.green : Color.red

        // Left: volume-pulsing orb (shifted right so its glow isn't clipped).
        let orbR = 6 + CGFloat(min(1, hud.orb)) * 11
        let cx = orbR + 10
        ctx.fill(Path(ellipseIn: CGRect(x: cx - orbR - 6, y: cy - orbR - 6,
                                        width: (orbR + 6) * 2, height: (orbR + 6) * 2)),
                 with: .color(accent.opacity(0.16)))
        ctx.fill(Path(ellipseIn: CGRect(x: cx - orbR, y: cy - orbR, width: orbR * 2, height: orbR * 2)),
                 with: .radialGradient(
                    Gradient(colors: [accent.opacity(0.95), accent.opacity(0.6)]),
                    center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: orbR))

        // Right: the waveform bars.
        let left = cx + orbR + 14
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
