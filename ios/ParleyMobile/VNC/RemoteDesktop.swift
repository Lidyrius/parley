import SwiftUI
import UIKit
import WebKit

/// v10 (docs/IPHONE.md): one desktop of the host, tunnelled through the relay. The phone opens a
/// channel `ch`, the host connects to the desktop and answers with its VNC password; then RFB bytes
/// go both ways as `vnc` frames, in order, and noVNC in a web view (vnc.html) speaks RFB.
@MainActor @Observable
final class DesktopChannel: Identifiable {
    enum State: Equatable {
        case opening                // waiting for the host's `open`
        case connecting             // the host is connected; noVNC logs in
        case live
        case failed(String)
        case ended                  // the desktop or the host closed it
    }

    /// The channel (`ch`): 16 characters [A-Za-z0-9].
    let id: String
    let desktop: String
    private(set) var state: State = .opening
    @ObservationIgnored private let send: (String) -> Void
    @ObservationIgnored let page = DesktopPage()

    init(desktop: String, id: String = DesktopChannel.newID(), send: @escaping (String) -> Void) {
        self.id = id
        self.desktop = desktop
        self.send = send
        page.onData = { [weak self] d in
            guard let self, self.isOpen else { return }
            self.send(Outgoing.vncData(ch: self.id, d: d))
        }
        page.onEvent = { [weak self] event in self?.pageSaid(event) }
    }

    nonisolated static func newID() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<16).map { _ in chars.randomElement()! })
    }

    private var isOpen: Bool { state == .connecting || state == .live }

    /// Asks the host for the desktop; no answer within 15 s (a host before v10) is a failure.
    func open() {
        send(Outgoing.vncOpen(ch: id, desktop: desktop))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.state == .opening else { return }
            self.fail("Der Host antwortet nicht.")
        }
    }

    /// The host's answer to `open`: the password goes to noVNC, never shown or kept.
    func opened(ok: Bool, password: String?, error: String?) {
        guard state == .opening else { return }
        guard ok else { state = .failed(error.flatMap(Frame.clean) ?? "Der Desktop ist nicht erreichbar."); return }
        state = .connecting
        page.call("start", password ?? "")
    }

    func received(_ d: String) {
        guard isOpen else { return }
        page.call("data", d)
    }

    /// The host closed it (the desktop went, 10 min without input, a third channel).
    func closedByHost() {
        guard state != .ended else { return }
        if isOpen || state == .opening { state = .ended }
        page.call("end")
    }

    /// The phone's socket dropped: what was in flight is lost, the RFB stream can't go on.
    func lost() {
        guard isOpen || state == .opening else { return }
        state = .failed("Die Verbindung zum Relay ist abgerissen.")
        page.call("end")
    }

    /// Closing the view, the app going to the background: the host lets go of the desktop.
    func close() {
        guard isOpen || state == .opening else { return }
        send(Outgoing.vncClose(ch: id))
        state = .ended
        page.call("end")
    }

    func type(_ text: String) { page.call("type", text) }
    func key(_ name: String) { page.call("key", name) }

    private func fail(_ text: String) {
        let wasOpen = isOpen || state == .opening
        state = .failed(text)
        if wasOpen { send(Outgoing.vncClose(ch: id)) }
        page.call("end")
    }

    private func pageSaid(_ event: DesktopPage.Event) {
        switch event {
        case .connected:
            if state == .connecting { state = .live }
        case .securityFailure:
            fail("Der Desktop hat die Anmeldung abgelehnt.")
        case .disconnected(let clean):
            guard isOpen else { return }
            if clean { close() } else { fail("Die Verbindung zum Desktop ist abgerissen.") }
        case .closed:
            if isOpen { close() }
        }
    }
}

/// The web view with noVNC and its bridge: calls into `window.parley` (queued until the page has
/// loaded, run in order) and the page's messages back.
@MainActor
final class DesktopPage: NSObject, WKNavigationDelegate {
    enum Event { case connected, securityFailure, disconnected(clean: Bool), closed }

    var onData: (String) -> Void = { _ in }
    var onEvent: (Event) -> Void = { _ in }
    private var loaded = false
    private var queue: [String] = []

    lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        let scripts = config.userContentController
        if let url = Bundle.main.url(forResource: "novnc", withExtension: "js"), let js = try? String(contentsOf: url, encoding: .utf8) {
            scripts.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        scripts.add(MessageProxy(self), name: "vnc")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.navigationDelegate = self
        if let url = Bundle.main.url(forResource: "vnc", withExtension: "html"), let html = try? String(contentsOf: url, encoding: .utf8) {
            // An https origin: noVNC wants a secure context. Nothing is loaded from it.
            web.loadHTMLString(html, baseURL: URL(string: "https://desktop.parley.invalid/"))
        }
        return web
    }()

    /// `window.parley.<name>(<args as JSON>)`.
    func call(_ name: String, _ args: String...) {
        let json = (try? JSONEncoder().encode(args)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let js = "window.parley && window.parley.\(name).apply(null, \(json));"
        if loaded { webView.evaluateJavaScript(js) } else { queue.append(js) }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            loaded = true
            let pending = queue
            queue = []
            for js in pending { webView.evaluateJavaScript(js) }
        }
    }

    fileprivate func received(_ body: Any) {
        guard let m = body as? [String: Any], let op = m["op"] as? String else { return }
        switch op {
        case "d": if let d = m["d"] as? String { onData(d) }
        case "close": onEvent(.closed)
        case "state":
            switch m["s"] as? String {
            case "connected": onEvent(.connected)
            case "securityfailure": onEvent(.securityFailure)
            case "disconnected": onEvent(.disconnected(clean: m["clean"] as? Bool ?? false))
            default: break
            }
        default: break
        }
    }

    /// The content controller keeps its handlers: a weak hop, so the page can go.
    private final class MessageProxy: NSObject, WKScriptMessageHandler {
        weak var page: DesktopPage?
        init(_ page: DesktopPage) { self.page = page }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated { page?.received(message.body) }
        }
    }
}

/// The desktop, full screen: noVNC fills it (tap = click, long press = right click, two fingers
/// scroll); the keyboard button types into the remote.
struct DesktopView: View {
    @Environment(AppModel.self) private var model
    let channel: DesktopChannel
    @State private var typing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Fertig") { model.closeDesktop() }
                    .font(.body.weight(.semibold))
                Spacer(minLength: 8)
                VStack(spacing: 1) {
                    Text(channel.desktop).font(.headline).lineLimit(1)
                    Text(model.hosts.active?.name ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if typing {
                    Button { channel.key("escape") } label: { Text("esc").font(.subheadline.weight(.semibold)) }
                        .accessibilityLabel("Escape")
                    Button { channel.key("tab") } label: { Image(systemName: "arrow.right.to.line") }
                        .accessibilityLabel("Tabulator")
                }
                Button { typing.toggle() } label: {
                    Image(systemName: typing ? "keyboard.chevron.compact.down" : "keyboard")
                }
                .disabled(channel.state != .live)
                .accessibilityLabel(typing ? "Tastatur ausblenden" : "Tastatur")
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(Theme.background)
            ZStack {
                Color.black
                WebHost(view: channel.page.webView).opacity(channel.state == .live ? 1 : 0.35)
                KeyCatcher(active: $typing, text: channel.type, delete: { channel.key("backspace") })
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                overlay
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onChange(of: channel.state) { _, state in if state != .live { typing = false } }
    }

    @ViewBuilder
    private var overlay: some View {
        switch channel.state {
        case .opening, .connecting:
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("Verbinde mit „\(channel.desktop)“…").foregroundStyle(.white)
            }
        case .live:
            EmptyView()
        case .failed(let text):
            ended("Keine Verbindung", text: text, symbol: "exclamationmark.triangle.fill")
        case .ended:
            ended("Verbindung beendet", text: "Der Desktop ist geschlossen.", symbol: "display")
        }
    }

    private func ended(_ title: String, text: String, symbol: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.white.opacity(0.8))
            Text(title).font(.title3.bold()).foregroundStyle(.white)
            Text(text).font(.subheadline).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Erneut verbinden") { model.openDesktop(channel.desktop) }
                    .buttonStyle(.borderedProminent)
                Button("Schließen") { model.closeDesktop() }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
        }
        .padding(24)
    }
}

private struct WebHost: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// The iOS keyboard for the remote: a view that takes key input while `active` — each typed
/// character (Return as a line break) and the delete key go straight to the desktop.
private struct KeyCatcher: UIViewRepresentable {
    @Binding var active: Bool
    let text: (String) -> Void
    let delete: () -> Void

    func makeUIView(context: Context) -> Catcher { Catcher() }

    func updateUIView(_ view: Catcher, context: Context) {
        view.onText = text
        view.onDelete = delete
        view.wanted = active
        if active, !view.isFirstResponder { view.becomeFirstResponder() }
        if !active, view.isFirstResponder { _ = view.resignFirstResponder() }
    }

    final class Catcher: UIView, UIKeyInput {
        var onText: (String) -> Void = { _ in }
        var onDelete: () -> Void = {}
        /// The keyboard stays up while wanted: a tap on the desktop makes the web view first
        /// responder, and the keys come back here right after.
        var wanted = false
        // Passwords and commands: typed as they are.
        var autocorrectionType: UITextAutocorrectionType = .no
        var autocapitalizationType: UITextAutocapitalizationType = .none
        var spellCheckingType: UITextSpellCheckingType = .no
        var smartQuotesType: UITextSmartQuotesType = .no
        var smartDashesType: UITextSmartDashesType = .no
        var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
        var keyboardType: UIKeyboardType = .asciiCapable

        override var canBecomeFirstResponder: Bool { true }
        var hasText: Bool { true }   // delete always reaches the desktop
        func insertText(_ text: String) { onText(text) }
        func deleteBackward() { onDelete() }

        override func resignFirstResponder() -> Bool {
            let done = super.resignFirstResponder()
            if done, wanted {
                DispatchQueue.main.async { [weak self] in
                    if let self, self.wanted, !self.isFirstResponder { self.becomeFirstResponder() }
                }
            }
            return done
        }
    }
}
