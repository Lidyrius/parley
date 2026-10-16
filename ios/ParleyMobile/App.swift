import SwiftUI

@main
struct ParleyMobileApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.claude)
        }
    }
}

/// Owns the pairing (Keychain) and the relay connection.
@MainActor @Observable
final class AppModel {
    let demo: Bool
    let relay = Relay()
    private(set) var pairing: Pairing?

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        demo = arguments.contains("-demo")
        if demo {
            relay.startDemo()
        } else if let saved = PairingStore.load() {
            pairing = saved
            relay.use(saved)  // dialled once the scene is active
        }
    }

    var isPaired: Bool { demo || pairing != nil }

    func pair(_ link: String) throws(PairingError) {
        let p = try Pairing.parse(link)
        try PairingStore.save(p)
        pairing = p
        relay.use(p)
        relay.reconnect()
    }

    func unpair() {
        relay.forget()
        PairingStore.remove()
        pairing = nil
    }

    /// iOS suspends sockets in the background anyway; close cleanly and redial on return.
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active: if relay.link == .idle { relay.reconnect() }
        case .background: relay.disconnect()
        default: break
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var linkError: String?

    var body: some View {
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
    }
}
