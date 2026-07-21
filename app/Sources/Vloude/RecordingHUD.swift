import SwiftUI
import AppKit

// Floating "listening" pill: a volume-reactive waveform + a pulsing orb in a capsule at
// the bottom-center of the screen, above every window / space / full-screen app.
//
// Motion is a CONTINUOUS traveling wave (a phase that advances every frame) whose
// amplitude follows the eased mic volume — no discrete left-shifting of samples, so it
// never steps. Driven by a 60 Hz timer bumping a @Published tick (TimelineView(.animation)
// does not run in a non-key/nonactivating NSPanel).
@MainActor
final class RecordingHUD: ObservableObject {
    static let barCount = 40
    static let maxOrbRadius: CGFloat = 17

    fileprivate var latest: Float = 0     // raw recent peak (decays each frame)
    fileprivate var vol: Float = 0        // eased amplitude for the bars
    fileprivate var orb: Float = 0        // eased amplitude for the orb (gentler)
    fileprivate var phase: Double = 0     // continuous traveling-wave phase
    @Published fileprivate var tick: Int = 0
    @Published var done = false

    private var panel: NSPanel?
    private var timer: DispatchSourceTimer?
    private var hideWork: DispatchWorkItem?

    func show() {
        hideWork?.cancel()
        done = false
        latest = 0; vol = 0; orb = 0; phase = 0
        if panel == nil { panel = makePanel() }
        position()
        panel?.orderFrontRegardless()
        startTimer()
    }

    func push(_ level: Float) {
        if level > latest { latest = level }   // peak-hold; decays in step()
    }

    func finish() {
        done = true
        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil); self?.stopTimer()
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
                // Gentle, well-interpolated easing (soft attack, softer release).
                self.vol += (self.latest - self.vol) * (self.latest > self.vol ? 0.16 : 0.07)
                self.orb += (self.latest - self.orb) * (self.latest > self.orb ? 0.10 : 0.05)
                self.phase += 0.09
                self.latest *= 0.92
                self.tick &+= 1
            }
        }
        timer = t
        t.resume()
    }

    private func stopTimer() { timer?.cancel(); timer = nil }

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
                _ = hud.tick
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
        let maxR = RecordingHUD.maxOrbRadius

        // Orb: FIXED centre so pulsing never moves/resizes the waveform.
        let cx = maxR + 8
        let orbR = 6 + CGFloat(min(1, hud.orb)) * (maxR - 6)
        ctx.fill(Path(ellipseIn: CGRect(x: cx - orbR - 6, y: cy - orbR - 6,
                                        width: (orbR + 6) * 2, height: (orbR + 6) * 2)),
                 with: .color(accent.opacity(0.16)))
        ctx.fill(Path(ellipseIn: CGRect(x: cx - orbR, y: cy - orbR, width: orbR * 2, height: orbR * 2)),
                 with: .radialGradient(
                    Gradient(colors: [accent.opacity(0.95), accent.opacity(0.6)]),
                    center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: orbR))

        // Waveform: fixed left edge (based on maxR, not the live orb radius) → constant width.
        let left = cx + maxR + 16
        let right = size.width
        let n = RecordingHUD.barCount
        guard right > left, n > 0 else { return }
        let slot = (right - left) / CGFloat(n)
        let barW = max(2, slot * 0.5)
        let maxH = size.height
        let vol = Double(min(1, hud.vol))
        for i in 0..<n {
            let t = Double(i) / Double(n - 1)
            let env = sin(t * .pi)                                   // taper at the ends
            // Two travelling components → organic, always-moving, never stepping.
            let flow = 0.55 + 0.30 * sin(hud.phase + Double(i) * 0.55)
                            + 0.15 * sin(hud.phase * 1.7 + Double(i) * 0.22)
            let amp = (0.12 + 0.88 * vol) * env * max(0, flow)
            let h = max(barW, CGFloat(amp) * maxH)
            let x = left + slot * CGFloat(i) + (slot - barW) / 2
            let rect = CGRect(x: x, y: cy - h / 2, width: barW, height: h)
            ctx.fill(Path(roundedRect: rect, cornerRadius: barW / 2), with: .color(.white.opacity(0.92)))
        }
    }
}
