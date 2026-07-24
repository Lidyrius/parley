import SwiftUI
import AppKit

// In-app notification "pill": a styled capsule at the bottom-center of the screen (same
// place + look as the recording HUD) showing title + message, sliding up and auto-
// dismissing. Used instead of a system notification when the user turns that on in
// Settings. Queues messages so rapid notifications don't clobber each other.
@MainActor
final class NotificationPill: ObservableObject {
    static let shared = NotificationPill()

    @Published fileprivate var title = ""
    @Published fileprivate var message = ""
    @Published fileprivate var shown = false

    private var panel: NSPanel?
    private var queue: [(String, String)] = []
    private var hideWork: DispatchWorkItem?
    private var busy = false

    func present(title: String, message: String) {
        queue.append((title, message))
        if !busy { showNext() }
    }

    private func showNext() {
        guard !queue.isEmpty else { busy = false; return }
        busy = true
        let (t, m) = queue.removeFirst()
        title = t
        message = m
        if panel == nil { panel = makePanel() }
        position()
        panel?.orderFrontRegardless()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { shown = true }   // fade + zoom in

        // Longer for longer messages; 2.6–5s.
        let dwell = min(5.0, max(2.6, 1.6 + Double(m.count) / 28.0))
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell, execute: work)
    }

    private func dismiss() {
        withAnimation(.easeIn(duration: 0.3)) { shown = false }   // fade out
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.panel?.orderOut(nil)
            self.showNext()   // drain the queue
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 92),
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
        guard let panel, let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let vf = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 30))
    }
}

private struct NotificationPillView: View {
    @ObservedObject var model: NotificationPill

    var body: some View {
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
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .frame(width: 380, height: 92, alignment: .leading)
        .background(
            ZStack {
                Capsule(style: .continuous).fill(.black.opacity(0.8))
                Capsule(style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1)
            }
        )
        // Fade + subtle zoom in/out (no slide).
        .scaleEffect(model.shown ? 1 : 0.88)
        .opacity(model.shown ? 1 : 0)
    }
}
