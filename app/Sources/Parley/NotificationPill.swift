import SwiftUI
import AppKit

// In-app notification "pill" at the bottom-center of the screen (same spot as the
// recording HUD). One combined animation: fade + gentle zoom in, a SLOW glass sweep once,
// a staggered message reveal, and a dwell bar that depletes; fade out. A 60 Hz timer
// drives appear / hold / out plus elapsed time for the sweep.
@MainActor
final class NotificationPill: ObservableObject {
    static let shared = NotificationPill()

    @Published fileprivate var title = ""
    @Published fileprivate var message = ""
    @Published fileprivate var appear: Double = 0    // 0→1 in, 1→0 out
    @Published fileprivate var dwell: Double = 1      // 1→0 during hold
    @Published fileprivate var elapsed: Double = 0    // seconds since shown (drives the sweep)
    @Published fileprivate var tick: Int = 0

    private var panel: NSPanel?
    private var timer: DispatchSourceTimer?
    private var queue: [(String, String)] = []
    private var state = 0            // 0 in · 1 hold · 2 out
    private var dwellTotal = 3.0
    private var busy = false

    func present(title: String, message: String) {
        queue.append((title, message))
        if !busy { showNext() }
    }

    private func showNext() {
        guard !queue.isEmpty else { busy = false; return }
        busy = true
        let (t, m) = queue.removeFirst()
        title = t; message = m
        appear = 0; dwell = 1; elapsed = 0; state = 0
        dwellTotal = min(5.0, max(2.8, 1.8 + Double(m.count) / 30.0))
        if panel == nil { panel = makePanel() }
        position()
        panel?.orderFrontRegardless()
        startTimer()
    }

    private func startTimer() {
        stopTimer()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / 60.0)
        let dt = 1.0 / 60.0
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsed += dt
                switch self.state {
                case 0:
                    self.appear += dt / 0.42
                    if self.appear >= 1 { self.appear = 1; self.state = 1 }
                case 1:
                    self.dwell -= dt / self.dwellTotal
                    if self.dwell <= 0 { self.dwell = 0; self.state = 2 }
                default:
                    self.appear -= dt / 0.34
                    if self.appear <= 0 {
                        self.appear = 0
                        self.panel?.orderOut(nil)
                        self.stopTimer()
                        self.showNext()
                        return
                    }
                }
                self.tick &+= 1
            }
        }
        timer = t
        t.resume()
    }

    private func stopTimer() { timer?.cancel(); timer = nil }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.contentView = NSHostingView(rootView: NotificationPillView(model: self))
        return p
    }

    private func position() {
        guard let panel else { return }
        // Screen under the mouse = where the user is actually looking (multi-monitor safe).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let size = panel.frame.size
        let vf = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 30))
    }
}

private struct NotificationPillView: View {
    @ObservedObject var model: NotificationPill
    private let W: CGFloat = 380, H: CGFloat = 92
    private let sweepDuration = 1.4          // slow, clearly visible

    var body: some View {
        _ = model.tick
        let a = model.appear
        return content
            .frame(width: W, height: H, alignment: .leading)
            .background(capsule)
            .overlay(sweep)
            .overlay(alignment: .bottom) { dwellBar }
            .clipShape(Capsule(style: .continuous))
            .scaleEffect(0.9 + 0.1 * smooth(a))         // gentle zoom
            .opacity(min(1, a * 1.5))                    // fade
            .frame(width: 400, height: 100)              // panel padding for shadow
    }

    private var content: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().fill(.blue.opacity(0.18)).frame(width: 38, height: 38)
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 25)).foregroundStyle(.blue)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Text(model.message).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
                    .opacity(messageReveal)              // stagger: message after title
                    .offset(x: (1 - messageReveal) * 10)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var capsule: some View {
        ZStack {
            Capsule(style: .continuous).fill(.black.opacity(0.8))
            Capsule(style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
    }

    // Slow one-time light sweep across the capsule.
    private var sweep: some View {
        GeometryReader { geo in
            let p = min(1, model.elapsed / sweepDuration)      // 0→1 over ~1.4s
            let x = (p * 1.5 - 0.3) * geo.size.width
            LinearGradient(colors: [.clear, .white.opacity(0.30), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.4)
                .offset(x: x)
                .opacity(p < 1 ? 1 : 0)
                .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }

    private var dwellBar: some View {
        GeometryReader { geo in
            Capsule().fill(.blue.opacity(0.9))
                .frame(width: geo.size.width * CGFloat(max(0, model.dwell)), height: 3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 3)
        .padding(.horizontal, 22)
        .padding(.bottom, 5)
    }

    private var messageReveal: Double { smooth(min(1, max(0, (model.appear - 0.45) / 0.55))) }
    private func smooth(_ p: Double) -> Double { let q = min(1, max(0, p)); return q * q * (3 - 2 * q) }
}
