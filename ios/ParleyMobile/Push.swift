import Foundation
import PushKit

/// APNs environment the VoIP token belongs to (`push` frame `env`).
enum PushEnvironment: String, Sendable {
    case production, development

    /// The build's real environment: the `aps-environment` of its embedded provisioning profile
    /// (Xcode installs: development, also for a Release build signed for development). App Store
    /// and TestFlight builds carry no profile and are production. No profile in a Debug build
    /// (the simulator) means development.
    static func current(bundle: Bundle = .main) -> PushEnvironment {
        if let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url), let env = fromProfile(data) {
            return env
        }
        #if DEBUG
        return .development
        #else
        return .production
        #endif
    }

    /// Reads `Entitlements → aps-environment` from a provisioning profile (a CMS envelope around
    /// an XML plist; the plist is cut out as text, no CMS parsing needed).
    static func fromProfile(_ data: Data) -> PushEnvironment? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil),
              let entitlements = (plist as? [String: Any])?["Entitlements"] as? [String: Any],
              let env = entitlements["aps-environment"] as? String else { return nil }
        return PushEnvironment(rawValue: env)
    }
}

/// The host's VoIP push payload: `{"label": "<spoken project name>"}`.
enum PushPayload {
    static func label(_ payload: [AnyHashable: Any]) -> String? {
        (payload["label"] as? String).flatMap(Frame.clean)
    }

    /// v7: a guest's call — the share whose room carries it.
    static func share(_ payload: [AnyHashable: Any]) -> String? {
        (payload["share"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// What CallKit shows for an incoming call: "Parley · Tippfrei", or just "Parley".
    static func callerName(_ label: String?) -> String {
        label.map { "Parley · \($0)" } ?? "Parley"
    }

    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}

/// PushKit VoIP registration. iOS requires every VoIP push to report an incoming CallKit call
/// before the completion handler runs — otherwise it stops delivering them to the app.
/// The registry calls back on the main queue, hence the main-actor conformance.
@MainActor
final class PushRegistry: NSObject, @preconcurrency PKPushRegistryDelegate {
    private let registry = PKPushRegistry(queue: .main)
    private(set) var token: String?
    var onToken: ((String) -> Void)?
    /// Must report the call to CallKit and call the completion once it has.
    var onIncoming: ((_ label: String?, _ share: String?, _ reported: @escaping () -> Void) -> Void)?

    override init() {
        super.init()
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
    }

    func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let hex = PushPayload.hex(credentials.token)
        token = hex
        onToken?(hex)
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        token = nil
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP, let onIncoming else { completion(); return }
        onIncoming(PushPayload.label(payload.dictionaryPayload), PushPayload.share(payload.dictionaryPayload), completion)
    }
}
