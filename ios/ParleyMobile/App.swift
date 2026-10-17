import SwiftUI
import UIKit
import UserNotifications

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
/// It also owns the notification side (Unterwegs + Stumm): the token, and opening the session a
/// tapped notification is about.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = AppModel.shared
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()   // the token needs no permission; showing does
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AppModel.shared.alertToken = PushPayload.hex(deviceToken)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["session"] as? String else { return }
        await MainActor.run { AppModel.shared.open(session: id) }
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

    /// Stumm (with Unterwegs): updates arrive as a notification, the reply is typed. Persisted;
    /// sent on change and after every (re)connect.
    var silent: Bool {
        didSet {
            guard silent != oldValue else { return }
            UserDefaults.standard.set(silent, forKey: Self.silentKey)
            relay.send(Outgoing.silent(silent))
            if silent, !demo {
                Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
            }
        }
    }
    /// The open session (navigation path; a tapped notification sets it).
    var path: [String] = []
    /// v3: each session's history as last received, its images, and messages typed but not yet seen in it.
    private(set) var histories: [String: [ChatItem]] = [:]
    private(set) var images: [String: UIImage] = [:]
    private(set) var pending: [String: [String]] = [:]
    /// Sessions whose history goes further back than what is loaded; an older page in flight.
    private(set) var hasOlder: Set<String> = []
    private(set) var loadingOlder: Set<String> = []
    @ObservationIgnored private var requestedImages: Set<String> = []
    @ObservationIgnored var alertToken: String? {
        didSet { if alertToken != oldValue { sendAlertToken() } }
    }

    @ObservationIgnored private var push: PushRegistry?
    @ObservationIgnored private var isForeground = false
    @ObservationIgnored private let pushEnvironment = PushEnvironment.current()
    private static let awayKey = "awayMode"
    private static let silentKey = "silentMode"

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        demo = arguments.contains("-demo")
        call = CallController(relay: relay, demo: demo)
        away = !demo && UserDefaults.standard.bool(forKey: Self.awayKey)
        silent = !demo && UserDefaults.standard.bool(forKey: Self.silentKey)
        call.ensureRelay = { [weak self] in self?.dialIfIdle() }
        call.onEnded = { [weak self] in self?.callEnded() }
        relay.onEvent = { [weak self] in self?.handle($0) }
        if demo {
            relay.startDemo()
            images["demo-5"] = Demo.screenshot()
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

    // MARK: - session view (v3)

    func open(session id: String) { path = [id] }

    func loadHistory(_ id: String) {
        if demo { histories[id] = Demo.history; return }
        relay.send(Outgoing.history(id: id))
    }

    /// The page before the oldest loaded item (scrolled to the top).
    func loadOlder(_ id: String) {
        guard !demo, hasOlder.contains(id), !loadingOlder.contains(id), let first = histories[id]?.first else { return }
        loadingOlder.insert(id)
        relay.send(Outgoing.history(id: id, before: first.id))
    }

    /// A received page merged into what is loaded: an older page goes in front; the newest page
    /// replaces the tail from its first item on (older pages stay) — or everything, when it no
    /// longer overlaps.
    nonisolated static func merge(_ old: [ChatItem], page: [ChatItem], before: String?) -> [ChatItem] {
        if let before {
            return old.first?.id == before ? page + old : old
        }
        guard let first = page.first, let j = old.firstIndex(where: { $0.id == first.id }) else { return page }
        return Array(old[..<j]) + page
    }

    func loadImage(session id: String, key: String) {
        guard !demo, requestedImages.insert(key).inserted else { return }
        relay.send(Outgoing.image(id: id, key: key))
    }

    func say(_ text: String, to id: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        pending[id, default: []].append(t)
        if !demo { relay.send(Outgoing.say(id: id, text: t)) }
    }

    private func sendAlertToken() {
        guard let token = alertToken, !demo else { return }
        relay.send(Outgoing.alertPush(token: token, env: pushEnvironment))
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
            relay.send(Outgoing.silent(silent))
            sendPushToken()
            sendAlertToken()
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
        case .frame(.history(let id, let items, let before, let more)):
            let old = histories[id] ?? []
            histories[id] = Self.merge(old, page: items, before: before)
            if before != nil {
                loadingOlder.remove(id)
                if more { hasOlder.insert(id) } else { hasOlder.remove(id) }
            } else if (items.first.map { first in old.firstIndex { $0.id == first.id } ?? 0 } ?? 0) == 0 {
                // Nothing older loaded in front of this page: its own `more` says.
                if more { hasOlder.insert(id) } else { hasOlder.remove(id) }
            }
            // A typed message shows as sent once the session has it (typed or as a reply).
            let seen = Set(items.filter { $0.kind == .user || $0.kind == .voice }.compactMap(\.text))
            pending[id]?.removeAll { seen.contains($0) }
        case .frame(.caption(let c)):
            call.captionReceived(c)
        case .frame(.slides(let s)):
            call.slidesReceived(s)
        case .frame(.image(let key, let data)):
            if let data, let image = UIImage(data: data) { images[key] = image }
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
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.scenePhaseChanged(phase)
            Appearance.shared.applyScheme()   // the window exists by now
        }
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
