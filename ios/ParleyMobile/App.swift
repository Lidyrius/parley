import SwiftUI
import UIKit
import UserNotifications
import WidgetKit

@main
struct ParleyMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.control)   // the accent; a near-white one (Schwarzweiß dark) greys so switches show
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
        UNUserNotificationCenter.current().setNotificationCategories([AppModel.laterCategory])
        application.registerForRemoteNotifications()   // the token needs no permission; showing does
        return true
    }

    /// The host's silent push for the widgets: store what it carries, the widgets reload.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let widget = userInfo["widget"] else { return .noData }
        return WidgetFeed.received(widget) ? .newData : .failed
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AppModel.shared.alertToken = PushPayload.hex(deviceToken)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let after = CallController.laterAfter(action: response.actionIdentifier) {
            await AppModel.shared.deliverLater(after)
            return
        }
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
    /// Fragerunde (Einstellungen): after a call, how long a new update waits while other sessions
    /// still work, so they come as one call (0 = never; nothing else at work → it rings at once).
    /// Persisted; sent on change and after every (re)connect.
    static let roundKey = "roundSeconds"
    static let roundChoices = [0, 30, 60, 90, 120, 180, 300]
    var roundSeconds = UserDefaults.standard.object(forKey: AppModel.roundKey) as? Int ?? 90 {
        didSet {
            guard roundSeconds != oldValue else { return }
            UserDefaults.standard.set(roundSeconds, forKey: Self.roundKey)
            relay.send(Outgoing.round(seconds: roundSeconds))
        }
    }

    /// Unterwegs-Modus: updates ring this phone instead of being voiced on the Mac. Persisted;
    /// sent on change and after every (re)connect.
    var away: Bool {
        didSet {
            guard away != oldValue else { return }
            SharedState.away = away
            relay.send(Outgoing.away(away))
            reloadControls()
            if !away { Task { await activity.endAll() } }   // the host ends it too; this is at once
            // Calls will come in: ask for the mic (and speech) now, not on the lock screen — and
            // for notifications, which a declined call leaves to put it off.
            if away, !demo {
                Task {
                    await CallController.requestPermissions()
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                }
            }
        }
    }

    /// Stumm (with Unterwegs): updates arrive as a notification, the reply is typed. Persisted;
    /// sent on change and after every (re)connect.
    var silent: Bool {
        didSet {
            guard silent != oldValue else { return }
            SharedState.silent = silent
            relay.send(Outgoing.silent(silent))
            reloadControls()
            if silent, !demo {
                Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
            }
        }
    }
    /// The open session (navigation path; a tapped notification sets it).
    var path: [String] = []
    /// The overview's sheet asked for "Nachricht": that session view opens with the keyboard up.
    var compose: String?
    /// v3: each session's history as last received, its images, and messages typed but not yet seen in it.
    private(set) var histories: [String: [ChatItem]] = [:]
    private(set) var images: [String: UIImage] = [:]
    private(set) var pending: [String: [String]] = [:]
    /// Sessions whose history goes further back than what is loaded; an older page in flight.
    private(set) var hasOlder: Set<String> = []
    /// v6: what opening a snapshot did, by its id — absent while the host hasn't answered.
    private(set) var opened: [String: [SnapshotResult]] = [:]
    // v7 (Guests.swift): shares of other people's sessions this phone joined, a link waiting to
    // be joined, the invite links Sir made (by session) and guests asking Sir to let them in.
    var guests: [GuestShare] = []
    @ObservationIgnored var guestRelays: [String: Relay] = [:]
    var pendingJoin: JoinLink?
    var shareLinks: [String: String] = [:]
    var joinRequests: [JoinRequest] = []
    var guestNotice: String?
    /// v7: questions for this phone as a guest (the Rückfrage screen shows the first).
    var guestAsks: [GuestAsk] = []
    private(set) var loadingOlder: Set<String> = []
    @ObservationIgnored private var requestedImages: Set<String> = []
    @ObservationIgnored var alertToken: String? {
        didSet { if alertToken != oldValue { sendAlertToken() } }
    }

    @ObservationIgnored private var push: PushRegistry?
    @ObservationIgnored private var isForeground = false
    @ObservationIgnored private let pushEnvironment = PushEnvironment.current()
    @ObservationIgnored let activity = ActivityLink()

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        demo = arguments.contains("-demo")
        call = CallController(relay: relay, demo: demo)
        // The switches live in the App Group (the controls read and set them); older builds kept
        // them in the app's own defaults.
        for key in ["awayMode", "silentMode"] where SharedState.defaults.object(forKey: key) == nil {
            SharedState.defaults.set(UserDefaults.standard.bool(forKey: key), forKey: key)
        }
        away = !demo && SharedState.away
        silent = !demo && SharedState.silent
        Appearance.shared.publishColors()
        call.ensureRelay = { [weak self] in self?.dialIfIdle() }
        call.onEnded = { [weak self] in self?.resumeOnConnect = nil; self?.callEnded() }
        call.onConnected = { [weak self] in self?.connected() }
        call.onDeclined = { [weak self] label in self?.offerLater(label) }
        call.onSubtitle = { [weak self] line in
            guard let self else { return }
            Task { await self.activity.subtitle(line, from: self.call.label) }
        }
        relay.onEvent = { [weak self] in self?.handle($0) }
        if demo {
            relay.startDemo()
            images["demo-5"] = Demo.screenshot()
            // `-demoCall speaking|listening|idle|incoming|connecting` opens the call screen.
            // `-demoJoin`: a guest asks to join (the approval sheet).
            if arguments.contains("-demoAsk") {   // `-demoAsk`: a question as a guest
                guestAsks = [GuestAsk(id: "demo-ask", session: "demo-shirts", label: "Shirts",
                                      text: "Max, für die Überschrift habe ich zwei Varianten. Welche passt zur Kampagne?",
                                      replies: ["Variante A", "Variante B"], seconds: 120)]
            }
            if arguments.contains("-demoJoin") {
                joinRequests = [JoinRequest(id: "demo-join", session: "demo-shirts", label: "Shirts", name: "Max")]
            }
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
        startGuests()
        // A push-to-start token or a new activity's update token: to the host now — the app may
        // have been woken in the background just for that.
        activity.onChange = { [weak self] in
            guard let self else { return }
            Task { await self.withRelay { self.sendActivityTokens() } }
        }
        activity.start()
        let push = PushRegistry()
        push.onToken = { [weak self] _ in self?.sendPushToken() }
        push.onIncoming = { [weak self] label, reported in
            guard let self else { reported(); return }
            call.reportIncoming(label: label, reported: reported)
            if pairing == nil { call.hangUp() }  // a host that still has this phone's token
        }
        self.push = push
    }

    var isPaired: Bool { demo || pairing != nil || !guests.isEmpty }

    /// "Parley anrufen" in the app.
    /// "Fortsetzen": Sir starts it, so (Unterwegs) he starts the call too — it connects at once,
    /// nothing to answer — and the resume goes to the host once the call is up; the host voices
    /// it there instead of ringing. At the desk (or in a call already) it goes out at once.
    @ObservationIgnored private var resumeOnConnect: String?

    func resume(_ id: String) {
        guard away, !demo, call.phase == .none else { relay.resume(id); return }
        resumeOnConnect = id
        callParley()
    }

    private func connected() {
        guard let id = resumeOnConnect else { return }
        resumeOnConnect = nil
        relay.resume(id)
    }

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

    // MARK: - Put off from the lock screen

    /// The lock screen's call UI can't carry the ringing screen's "In 1 Min." … buttons; a
    /// decline there leaves this notification with the same choices instead.
    nonisolated static var laterCategory: UNNotificationCategory {
        UNNotificationCategory(identifier: "parley.later",
                               actions: [UNNotificationAction(identifier: "later.60", title: "In 1 Min. anrufen"),
                                         UNNotificationAction(identifier: "later.300", title: "In 5 Min. anrufen"),
                                         UNNotificationAction(identifier: "later.back", title: "Ich rufe zurück")],
                               intentIdentifiers: [])
    }

    private func offerLater(_ label: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Parley" + (label.map { " · \($0)" } ?? "")
        content.body = "Gerade nicht? Ich rufe in einer oder fünf Minuten wieder an – oder du rufst zurück."
        content.categoryIdentifier = "parley.later"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "parley.later", content: content, trigger: nil))
    }

    /// A choice from that notification, maybe with the app in the background.
    func deliverLater(_ after: Int?) async {
        await withRelay { relay.send(Outgoing.later(after: after)) }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["parley.later"])
    }

    /// A switch flipped outside the app (a control, Siri): to the host now.
    func syncSwitches() async {
        await withRelay {
            relay.send(Outgoing.away(away))
            relay.send(Outgoing.silent(silent))
        }
    }

    /// Runs `send` once the relay is connected — dialling it if idle, up to 20 s, as a background
    /// task (the app may be in the background for a control, a notification, a push). A socket
    /// dialled just for this closes again afterwards there.
    func withRelay(_ send: () -> Void) async {
        guard !demo else { return }
        let task = UIApplication.shared.beginBackgroundTask(withName: "parley.relay")
        defer { UIApplication.shared.endBackgroundTask(task) }
        dialIfIdle()
        for _ in 0..<200 where !relay.canSend { try? await Task.sleep(for: .milliseconds(100)) }
        send()
        try? await Task.sleep(for: .milliseconds(500))   // let it leave
        if !isForeground, !call.isBusy { relay.disconnect() }
    }

    private func sendActivityTokens() {
        if let t = activity.startToken { relay.send(Outgoing.activityStart(token: t, env: pushEnvironment)) }
        relay.send(Outgoing.activity(token: activity.updateToken, env: pushEnvironment))
    }

    private func reloadControls() {
        guard #available(iOS 18, *) else { return }
        ControlCenter.shared.reloadControls(ofKind: SharedState.awayKind)
        ControlCenter.shared.reloadControls(ofKind: SharedState.silentKind)
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
            // `-demoActivity`: the Live Activity with demo content (Island, Lock Screen) — it can
            // only start in the foreground.
            if demo, ProcessInfo.processInfo.arguments.contains("-demoActivity") { Task { await activity.startDemo() } }
            // A control may have flipped a switch while the app was away.
            if !demo, away != SharedState.away { away = SharedState.away }
            if !demo, silent != SharedState.silent { silent = SharedState.silent }
            dialIfIdle()
        case .background:
            isForeground = false
            if !call.isBusy { relay.disconnect() }
            for r in guestRelays.values { r.disconnect() }
        default: break
        }
    }

    private func dialIfIdle() {
        if relay.link == .idle { relay.reconnect() }
        for r in guestRelays.values where r.link == .idle { r.reconnect() }
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
        relay(for: id).send(Outgoing.history(id: id))
    }

    /// The page before the oldest loaded item (scrolled to the top).
    func loadOlder(_ id: String) {
        guard !demo, hasOlder.contains(id), !loadingOlder.contains(id), let first = histories[id]?.first else { return }
        loadingOlder.insert(id)
        relay(for: id).send(Outgoing.history(id: id, before: first.id))
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
        relay(for: id).send(Outgoing.image(id: id, key: key))
    }

    // MARK: Snapshots (v6) — the host keeps them; the list comes with every `sessions` frame.

    func saveSnapshot(name: String, ids: [String]) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !ids.isEmpty, !demo else { return }
        relay.send(Outgoing.snapshotSave(name: n, ids: ids))
    }

    func openSnapshot(_ s: SavedSnapshot) {
        opened[s.id] = nil
        guard demo else { relay.send(Outgoing.snapshotOpen(id: s.id)); return }
        Task { [weak self] in   // the demo answers like a host would
            try? await Task.sleep(for: .milliseconds(900))
            let kinds = ["running", "resumed", "resumed", "started"]
            self?.opened[s.id] = s.sessions.enumerated().map { i, item in
                SnapshotResult(id: item.id, name: item.name, result: kinds[i % kinds.count])
            }
        }
    }

    func deleteSnapshot(_ id: String) {
        guard !demo else { return }
        relay.send(Outgoing.snapshotDelete(id: id))
    }

    func say(_ text: String, to id: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        pending[id, default: []].append(t)
        if !demo { relay(for: id).send(Outgoing.say(id: id, text: t)) }
    }

    func sendAlertToken(on r: Relay) {
        guard let token = alertToken, !demo else { return }
        r.send(Outgoing.alertPush(token: token, env: pushEnvironment))
    }

    private func sendAlertToken() {
        guard let token = alertToken, !demo else { return }
        relay.send(Outgoing.alertPush(token: token, env: pushEnvironment))
    }

    private func sendPushToken() {
        guard let token = push?.token else { return }
        relay.send(Outgoing.push(token: token, env: pushEnvironment))
    }

    func handle(_ event: RelayEvent) {
        switch event {
        case .opened:
            // Per-connection state: the host may have restarted or the socket been replaced.
            relay.send(Outgoing.away(away))
            relay.send(Outgoing.silent(silent))
            relay.send(Outgoing.round(seconds: roundSeconds))
            sendPushToken()
            sendAlertToken()
            sendActivityTokens()
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
        case .frame(.snapshotOpened(let id, let results)):
            opened[id] = results
        case .frame(.palette(let p)):
            Appearance.shared.adopt(p)
            relay.send(Outgoing.paletteSaved(p.name))
        case .frame(.image(let key, let data)):
            if let data, let image = UIImage(data: data) { images[key] = image }
        case .frame(.shareLink(_, let session, let link)):
            shareLinks[session] = link
        case .frame(.joinRequest(let r)):
            joinRequests.removeAll { $0.id == r.id }
            joinRequests.append(r)
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
                OverviewView()
            } else {
                PairingView()
            }
        }
        // The system camera opens the QR's parley:// link here.
        .sheet(item: Binding(get: { model.pendingJoin }, set: { model.pendingJoin = $0 })) { JoinView(link: $0) }
        .fullScreenCover(item: Binding(get: { model.guestAsks.first }, set: { _ in })) { GuestAskView(ask: $0) }
        .onOpenURL { url in
            // v7: someone shares a session with this phone.
            if url.host == "join" {
                if let link = JoinLink.parse(url.absoluteString) { model.pendingJoin = link } else { linkError = "Der Einladungslink ist ungültig." }
                return
            }
            // The Island / Lock Screen: parley://session?id=<id> opens that session.
            if url.host == "session" {
                if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value {
                    model.open(session: id)
                }
                return
            }
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
