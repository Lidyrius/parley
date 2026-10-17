import SwiftUI
import UIKit

@main
struct ParleyMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.claude)
        }
    }
}

/// iOS also launches the app in the background — for a VoIP push or a Siri "Parley anrufen" —
/// where no scene comes up. The model (PushKit, CallKit) must exist at launch for those.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = AppModel.shared
        return true
    }
}

/// Owns the pairing (Keychain), the relay connection, the call and the push registration.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let demo: Bool
    let relay = Relay()
    let call: CallController
    private(set) var pairing: Pairing?
    /// Unterwegs-Modus: updates ring this phone instead of being voiced on the Mac. Persisted;
    /// sent on change and after every (re)connect.
    var away: Bool {
        didSet {
            guard away != oldValue else { return }
            UserDefaults.standard.set(away, forKey: Self.awayKey)
            relay.send(Outgoing.away(away))
            // Calls will come in: ask for the mic (and speech) now, not on the lock screen.
            if away, !demo { Task { await CallController.requestPermissions() } }
        }
    }

    @ObservationIgnored private var push: PushRegistry?
    @ObservationIgnored private var isForeground = false
    @ObservationIgnored private let pushEnvironment = PushEnvironment.current()
    private static let awayKey = "awayMode"

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        demo = arguments.contains("-demo")
        call = CallController(relay: relay, demo: demo)
        away = !demo && UserDefaults.standard.bool(forKey: Self.awayKey)
        call.ensureRelay = { [weak self] in self?.dialIfIdle() }
        call.onEnded = { [weak self] in self?.callEnded() }
        relay.onEvent = { [weak self] in self?.handle($0) }
        if demo {
            relay.startDemo()
            // `-demoCall speaking|listening|idle|incoming|connecting` opens the call screen.
            if let i = arguments.firstIndex(of: "-demoCall") {
                let state = i + 1 < arguments.count ? Demo.CallState(rawValue: arguments[i + 1]) : nil
                call.startDemo(state ?? .speaking)
            }
            return
        }
        if let saved = PairingStore.load() {
            pairing = saved
            relay.use(saved)  // dialled once the scene is active (or a call needs it)
        }
        let push = PushRegistry()
        push.onToken = { [weak self] _ in self?.sendPushToken() }
        push.onIncoming = { [weak self] label, reported in
            guard let self else { reported(); return }
            call.reportIncoming(label: label, reported: reported)
            if pairing == nil { call.hangUp() }  // a host that still has this phone's token
        }
        self.push = push
    }

    var isPaired: Bool { demo || pairing != nil }

    /// "Parley anrufen" in the app.
    func callParley() {
        Task {
            if !demo { await CallController.requestPermissions() }
            do {
                try await call.startOutgoing()
            } catch {
                call.failure = "Der Anruf ließ sich nicht starten."
            }
        }
    }

    func pair(_ link: String) throws(PairingError) {
        let p = try Pairing.parse(link)
        try PairingStore.save(p)
        pairing = p
        relay.use(p)
        relay.reconnect()
    }

    func unpair() {
        call.hangUp()
        relay.forget()
        PairingStore.remove()
        pairing = nil
    }

    /// iOS suspends sockets in the background anyway; close cleanly and redial on return.
    /// A call keeps it (audio background mode) until it ends.
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isForeground = true
            dialIfIdle()
        case .background:
            isForeground = false
            if !call.isBusy { relay.disconnect() }
        default: break
        }
    }

    private func dialIfIdle() {
        if relay.link == .idle { relay.reconnect() }
    }

    /// Back in the background without a call: close the socket once `call end` has left.
    private func callEnded() {
        guard !isForeground else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            if !isForeground, !call.isBusy { relay.disconnect() }
        }
    }

    private func sendPushToken() {
        guard let token = push?.token else { return }
        relay.send(Outgoing.push(token: token, env: pushEnvironment))
    }

    private func handle(_ event: RelayEvent) {
        switch event {
        case .opened:
            // Per-connection state: the host may have restarted or the socket been replaced.
            relay.send(Outgoing.away(away))
            sendPushToken()
            if call.phase.isActive { relay.send(Outgoing.call(started: true)) }
            call.relayChanged()
        case .closed:
            call.relayChanged()
        case .audio(let frame):
            call.play(frame)
        case .frame(.peer):
            call.relayChanged()
        case .frame(.audio(let state, let label)):
            call.hostAudioChanged(state, label: label)
        case .frame(.ring(let label)):
            // In the background the VoIP push rings instead (the socket is closed there anyway).
            if isForeground { call.reportIncoming(label: label) }
        case .frame:
            break
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var linkError: String?

    var body: some View {
        @Bindable var call = model.call
        Group {
            if model.isPaired {
                OverviewView(expanded: model.demo ? Demo.expanded : [])
            } else {
                PairingView()
            }
        }
        // The system camera opens the QR's parley:// link here.
        .onOpenURL { url in
            do { try model.pair(url.absoluteString) } catch { linkError = error.localizedDescription }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in model.scenePhaseChanged(phase) }
        .sensoryFeedback(.success, trigger: model.pairing) { old, new in new != nil && old != new }
        .alert("Kopplung fehlgeschlagen", isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(linkError ?? "")
        }
        // A failed call is reported by a banner on the overview: an alert here would race the
        // cover's dismissal.
        .fullScreenCover(isPresented: $call.showsScreen) {
            CallView()
        }
    }
}
