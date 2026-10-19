import Foundation
import Security

/// What the host's QR code carries (docs/IPHONE.md → Pairing): the relay, the room, its secret,
/// and the end-to-end key (v5; nil from an older host — then frames go in the clear).
struct Pairing: Codable, Equatable, Sendable {
    let relay: URL
    let room: String
    let secret: String
    var key: String? = nil

    /// `wss://<relay>/v1/room/<room>?role=phone` (relay protocol v1). A base path is kept.
    var socketURL: URL {
        var c = URLComponents(url: relay, resolvingAgainstBaseURL: false) ?? URLComponents()
        c.scheme = relay.scheme == "http" ? "ws" : "wss"
        let base = c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path
        c.path = base + "/v1/room/" + room
        c.queryItems = [URLQueryItem(name: "role", value: "phone")]
        c.fragment = nil
        return c.url!
    }

    /// Parses `parley://pair?u=<relay>&r=<room>&k=<secret>`. Also takes the relay's
    /// `https://<relay>/pair#<link>` page URL, which carries the link in its fragment.
    static func parse(_ text: String) throws(PairingError) -> Pairing {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw .notALink
        }
        if c.scheme?.lowercased() == "https", let inner = c.fragment, inner.lowercased().hasPrefix("parley:") {
            return try parse(inner)
        }
        guard c.scheme?.lowercased() == "parley", c.host?.lowercased() == "pair" else { throw .notALink }
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] where q[item.name] == nil { q[item.name] = item.value ?? "" }

        guard let u = q["u"], let relay = URL(string: u), isRelay(relay) else { throw .badRelay }
        guard let room = q["r"], isBase64URL(room, 16...64) else { throw .badRoom }
        guard let secret = q["k"], isBase64URL(secret, 16...128) else { throw .badSecret }
        if let key = q["e"], !isBase64URL(key, 43...43) { throw .badSecret }
        return Pairing(relay: relay, room: room, secret: secret, key: q["e"])
    }

    private static func isRelay(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false), !host.isEmpty, url.query == nil else { return false }
        if url.scheme == "https" { return true }
        #if DEBUG
        // Debug builds only: a relay under `wrangler dev` on this Mac.
        return url.scheme == "http" && ["localhost", "127.0.0.1"].contains(host)
        #else
        return false
        #endif
    }

    private static func isBase64URL(_ s: String, _ length: ClosedRange<Int>) -> Bool {
        length.contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

enum PairingError: Error, Equatable, LocalizedError {
    case notALink, badRelay, badRoom, badSecret, keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notALink: "Das ist kein Parley-Kopplungslink."
        case .badRelay: "Die Relay-Adresse im Link ist ungültig (https erforderlich)."
        case .badRoom: "Die Raum-ID im Link ist ungültig."
        case .badSecret: "Der Schlüssel im Link fehlt oder ist ungültig."
        case .keychain(let status): "Der Schlüssel konnte nicht sicher gespeichert werden (Fehler \(status))."
        }
    }
}

/// The pairing lives in the Keychain: it holds the room secret. This device only, no backups.
enum PairingStore {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "de.developaway.parley.mobile",
         kSecAttrAccount as String: account]
    }

    static func load(account: String = "relay") -> Pairing? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Pairing.self, from: data)
    }

    static func save(_ pairing: Pairing, account: String = "relay") throws(PairingError) {
        remove(account: account)
        var q = query(account)
        q[kSecValueData as String] = (try? JSONEncoder().encode(pairing)) ?? Data()
        // After first unlock: a later stage reconnects from the background (CallKit / push).
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw .keychain(status) }
    }

    static func remove(account: String = "relay") {
        SecItemDelete(query(account) as CFDictionary)
    }

    /// v7: the shares this phone joined as a guest — their rooms and keys, so the Keychain too.
    static func loadGuests() -> [GuestShare] {
        var q = query("guests")
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return [] }
        return (try? JSONDecoder().decode([GuestShare].self, from: data)) ?? []
    }

    static func saveGuests(_ list: [GuestShare]) {
        remove(account: "guests")
        guard !list.isEmpty else { return }
        var q = query("guests")
        q[kSecValueData as String] = (try? JSONEncoder().encode(list)) ?? Data()
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// v7: an invite to someone else's session — `parley://join?u&r&k&e` (as a pairing) plus `s`, the
/// session's name, and `h`, who shares it.
struct JoinLink: Equatable, Sendable, Identifiable {
    let pairing: Pairing
    let label: String
    let host: String
    var id: String { pairing.room }

    static func parse(_ text: String) -> JoinLink? {
        guard var c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        // `https://<relay>/join#<parley://join?…>`: the link as sent (universal link / the relay's page).
        if c.scheme?.lowercased() == "https", c.path == "/join", let inner = c.percentEncodedFragment?.removingPercentEncoding {
            return parse(inner)
        }
        guard c.scheme?.lowercased() == "parley", c.host?.lowercased() == "join" else { return nil }
        let q = c.queryItems ?? []
        func value(_ n: String) -> String { q.first { $0.name == n }?.value ?? "" }
        c.host = "pair"
        c.queryItems = q.filter { ["u", "r", "k", "e"].contains($0.name) }
        guard let link = c.string, let p = try? Pairing.parse(link), p.key != nil else { return nil }   // never in the clear
        return JoinLink(pairing: p, label: String(value("s").prefix(60)), host: String(value("h").prefix(60)))
    }
}
