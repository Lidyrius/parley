import Foundation
import CryptoKit

// VoIP pushes to the iPhone (docs/IPHONE.md, "Ringing"): token-based APNs auth — an ES256 JWT
// signed with the team's .p8 key — over HTTP/2 (URLSession negotiates it with Apple's servers).
// The phone's PushKit wakes the app, which shows the CallKit incoming call.

struct APNsCredentials: Equatable, Sendable {
    static let defaultTeam = "384887N3UL"

    var keyId: String
    var teamId: String
    var keyP8: String   // PEM ("-----BEGIN PRIVATE KEY-----" …)

    var isComplete: Bool { !keyId.isEmpty && !teamId.isEmpty && !keyP8.isEmpty }

    static func load() -> APNsCredentials {
        let team = Keychain.get(.apnsTeamId) ?? ""
        return APNsCredentials(keyId: Keychain.get(.apnsKeyId) ?? "", teamId: team.isEmpty ? defaultTeam : team,
                               keyP8: Keychain.get(.apnsKeyP8) ?? "")
    }
}

enum APNs {
    static let topic = "de.developaway.parley.mobile.voip"

    static func host(env: String) -> String {
        env == "development" ? "api.sandbox.push.apple.com" : "api.push.apple.com"
    }

    /// "AuthKey_ABC123DEFG.p8" → "ABC123DEFG" (Apple's download name); nil for anything else.
    static func keyId(fileName: String) -> String? {
        let name = (fileName as NSString).lastPathComponent
        guard name.hasPrefix("AuthKey_"), name.lowercased().hasSuffix(".p8") else { return nil }
        let id = String(name.dropFirst("AuthKey_".count).dropLast(3))
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return id
    }

    static func privateKey(pem: String) throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(pemRepresentation: pem)
    }

    /// The provider token: header {alg ES256, kid}, claims {iss team, iat}, ES256 (raw r‖s) signature.
    static func jwt(keyId: String, teamId: String, key: P256.Signing.PrivateKey, issuedAt: Date) throws -> String {
        struct Header: Encodable { let alg = "ES256"; let kid: String }
        struct Claims: Encodable { let iss: String; let iat: Int }
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let head = RelayLink.base64url(try enc.encode(Header(kid: keyId)))
        let body = RelayLink.base64url(try enc.encode(Claims(iss: teamId, iat: Int(issuedAt.timeIntervalSince1970))))
        let input = "\(head).\(body)"
        let signature = try key.signature(for: Data(input.utf8))
        return "\(input).\(RelayLink.base64url(signature.rawRepresentation))"
    }

    static func request(token: String, env: String, jwt: String, label: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://\(host(env: env))/3/device/\(token)")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        req.setValue(topic, forHTTPHeaderField: "apns-topic")
        req.setValue("voip", forHTTPHeaderField: "apns-push-type")
        req.setValue("10", forHTTPHeaderField: "apns-priority")
        req.setValue("0", forHTTPHeaderField: "apns-expiration")   // a call that rings late is worse than none
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        struct Payload: Encodable { let label: String }
        req.httpBody = try? JSONEncoder().encode(Payload(label: label))
        return req
    }

    // A visible notification (Unterwegs + Stumm): "Parley · Tippfrei" + the spoken line; tapping
    // it opens that session on the phone. Grouped per session.
    static let alertTopic = "de.developaway.parley.mobile"

    static func alertRequest(token: String, env: String, jwt: String, title: String, body: String, session: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://\(host(env: env))/3/device/\(token)")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        req.setValue(alertTopic, forHTTPHeaderField: "apns-topic")
        req.setValue("alert", forHTTPHeaderField: "apns-push-type")
        req.setValue("10", forHTTPHeaderField: "apns-priority")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        struct Alert: Encodable { let title: String; let body: String }
        struct Aps: Encodable {
            let alert: Alert; let sound = "default"; let threadId: String
            enum CodingKeys: String, CodingKey { case alert, sound, threadId = "thread-id" }
        }
        struct Payload: Encodable { let aps: Aps; let session: String }
        req.httpBody = try? JSONEncoder().encode(Payload(aps: Aps(alert: Alert(title: title, body: body), threadId: session), session: session))
        return req
    }

    // The Parley Live Activity (docs/LIVE-ACTIVITIES.md): push-to-start, update, end. `body` is the
    // whole JSON payload (LiveActivity.payload); priority 5 is not budgeted, 10 is.
    static let activityTopic = "de.developaway.parley.mobile.push-type.liveactivity"

    static func activityRequest(token: String, env: String, jwt: String, body: Data, priority: Int) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://\(host(env: env))/3/device/\(token)")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        req.setValue(activityTopic, forHTTPHeaderField: "apns-topic")
        req.setValue("liveactivity", forHTTPHeaderField: "apns-push-type")
        req.setValue(String(priority), forHTTPHeaderField: "apns-priority")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = body
        return req
    }

    // A silent push (the widgets' picture): wakes the app in the background, shows nothing.
    // Priority 5 and push type `background` are what APNs requires for it.
    static func backgroundRequest(token: String, env: String, jwt: String, body: Data) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://\(host(env: env))/3/device/\(token)")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        req.setValue(alertTopic, forHTTPHeaderField: "apns-topic")
        req.setValue("background", forHTTPHeaderField: "apns-push-type")
        req.setValue("5", forHTTPHeaderField: "apns-priority")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = body
        return req
    }

    /// APNs' error body: {"reason":"BadDeviceToken"}.
    static func reason(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["reason"] as? String
    }
}

// Sends VoIP pushes; keeps the provider token ~50 min (APNs accepts it for an hour and rejects
// refreshing more often than every 20 min).
// ponytail: @unchecked Sendable — the cache is behind `lock`.
final class APNsClient: @unchecked Sendable {
    static let tokenLifetime: TimeInterval = 50 * 60

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let lock = NSLock()
    private var cached: (jwt: String, at: Date, creds: APNsCredentials)?
    private let credentials: @Sendable () -> APNsCredentials
    private let now: @Sendable () -> Date
    private let transport: Transport
    private let log: @Sendable (String) -> Void

    init(credentials: @escaping @Sendable () -> APNsCredentials = { APNsCredentials.load() },
         now: @escaping @Sendable () -> Date = { Date() },
         transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
         log: @escaping @Sendable (String) -> Void = { Log.write($0) }) {
        self.credentials = credentials
        self.now = now
        self.transport = transport
        self.log = log
    }

    var configured: Bool { credentials().isComplete }

    /// The current provider token (cached; re-signed after 50 min or when the key changed).
    func providerToken() throws -> String {
        let creds = credentials()
        let t = now()
        if let c = lock.withLock({ cached }), c.creds == creds, t.timeIntervalSince(c.at) < Self.tokenLifetime {
            return c.jwt
        }
        let jwt = try APNs.jwt(keyId: creds.keyId, teamId: creds.teamId, key: APNs.privateKey(pem: creds.keyP8), issuedAt: t)
        lock.withLock { cached = (jwt, t, creds) }
        return jwt
    }

    /// One VoIP push; returns the HTTP status (-1 = not sent) and APNs' reason. Logged either way.
    @discardableResult
    func push(token: String, env: String, label: String) async -> (status: Int, reason: String?) {
        await send(env: env) { APNs.request(token: token, env: env, jwt: $0, label: label) }
    }

    /// One visible notification (Unterwegs + Stumm).
    @discardableResult
    func notify(token: String, env: String, title: String, body: String, session: String) async -> (status: Int, reason: String?) {
        await send(env: env) { APNs.alertRequest(token: token, env: env, jwt: $0, title: title, body: body, session: session) }
    }

    /// One silent push for the widgets.
    @discardableResult
    func background(token: String, env: String, body: Data) async -> (status: Int, reason: String?) {
        await send(env: env) { APNs.backgroundRequest(token: token, env: env, jwt: $0, body: body) }
    }

    /// One Live Activity push (start / update / end).
    @discardableResult
    func liveActivity(token: String, env: String, body: Data, priority: Int) async -> (status: Int, reason: String?) {
        await send(env: env) { APNs.activityRequest(token: token, env: env, jwt: $0, body: body, priority: priority) }
    }

    private func send(env: String, _ build: (String) -> URLRequest) async -> (status: Int, reason: String?) {
        guard configured else { log("apns: no push key — skipped"); return (-1, "no key") }
        let jwt: String
        do { jwt = try providerToken() } catch {
            log("apns: push key unusable (\(error.localizedDescription))")
            return (-1, "bad key")
        }
        do {
            let (data, resp) = try await transport(build(jwt))
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let reason = APNs.reason(data)
            log("apns: push \(env) → \(status)\(reason.map { " \($0)" } ?? "")")
            if status == 403, reason == "ExpiredProviderToken" { lock.withLock { cached = nil } }
            return (status, reason)
        } catch {
            log("apns: push failed (\(error.localizedDescription))")
            return (-1, error.localizedDescription)
        }
    }
}
