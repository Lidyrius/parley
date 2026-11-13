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
        let q = try query(text)
        guard let u = q["u"], let relay = URL(string: u), isRelay(relay) else { throw .badRelay }
        guard let room = q["r"], isBase64URL(room, 16...64) else { throw .badRoom }
        guard let secret = q["k"], isBase64URL(secret, 16...128) else { throw .badSecret }
        if let key = q["e"], !isBase64URL(key, 43...43) { throw .badSecret }
        return Pairing(relay: relay, room: room, secret: secret, key: q["e"])
    }

    /// `h`: what the host calls itself (its machine name) — the name it gets in the list of
    /// hosts. Optional: an older host's link has none.
    static func hostName(in text: String) -> String? {
        (try? query(text))?["h"].flatMap(HostList.clean)
    }

    /// The link's parameters (the first of each name counts).
    private static func query(_ text: String) throws(PairingError) -> [String: String] {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw .notALink
        }
        if c.scheme?.lowercased() == "https", let inner = c.fragment, inner.lowercased().hasPrefix("parley:") {
            return try query(inner)
        }
        guard c.scheme?.lowercased() == "parley", c.host?.lowercased() == "pair" else { throw .notALink }
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] where q[item.name] == nil { q[item.name] = item.value ?? "" }
        return q
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
    case notALink, badRelay, badRoom, badSecret, keychain(OSStatus), inCall

    var errorDescription: String? {
        switch self {
        case .notALink: "Das ist kein Parley-Kopplungslink."
        case .badRelay: "Die Relay-Adresse im Link ist ungültig (https erforderlich)."
        case .badRoom: "Die Raum-ID im Link ist ungültig."
        case .badSecret: "Der Schlüssel im Link fehlt oder ist ungültig."
        case .keychain(let status): "Der Schlüssel konnte nicht sicher gespeichert werden (Fehler \(status))."
        case .inCall: "Während eines Anrufs bleibt der Host, wie er ist. Bitte erst auflegen."
        }
    }
}

/// One host this phone is paired with — a Mac, a PC, a server: the name Sir gave it and its pairing.
struct HostPairing: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var name: String
    var pairing: Pairing
}

/// The hosts this phone is paired with and the one it talks to — one at a time.
struct HostList: Codable, Equatable, Sendable {
    private(set) var hosts: [HostPairing] = []
    private var activeID: String?

    init() {}

    /// Builds before the list kept a single pairing: it is the first host, "Mac".
    init(legacy: Pairing) { add(legacy, name: nil) }

    /// The host picked — or, should that one be gone, the first.
    var active: HostPairing? { hosts.first { $0.id == activeID } ?? hosts.first }

    /// A host joins and becomes the active one. Its name: `name` (the link's `h`), else "Mac" for
    /// the first and "Host 2", "Host 3" … after it. A room that is in the list already is that
    /// host paired anew: it keeps its place, id and name.
    @discardableResult mutating func add(_ pairing: Pairing, name: String?) -> HostPairing {
        if let i = hosts.firstIndex(where: { $0.pairing.relay == pairing.relay && $0.pairing.room == pairing.room }) {
            hosts[i].pairing = pairing
            activeID = hosts[i].id
            return hosts[i]
        }
        var n = hosts.count + 1
        while hosts.contains(where: { $0.name == "Host \(n)" }) { n += 1 }
        let host = HostPairing(name: name.flatMap(Self.clean) ?? (hosts.isEmpty ? "Mac" : "Host \(n)"), pairing: pairing)
        hosts.append(host)
        activeID = host.id
        return host
    }

    /// The active one removed: the first of the others takes over.
    mutating func remove(_ id: String) {
        let wasActive = active?.id == id
        hosts.removeAll { $0.id == id }
        if wasActive { activeID = hosts.first?.id }
    }

    mutating func activate(_ id: String) {
        if hosts.contains(where: { $0.id == id }) { activeID = id }
    }

    /// An empty name changes nothing.
    mutating func rename(_ id: String, to name: String) {
        guard let i = hosts.firstIndex(where: { $0.id == id }), let name = Self.clean(name) else { return }
        hosts[i].name = name
    }

    /// A host's name as kept: trimmed, at most 40 characters; nil when nothing is left.
    static func clean(_ name: String) -> String? {
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        return n.isEmpty ? nil : n
    }
}

/// The pairings live in the Keychain: they hold the room secrets. This device only, no backups.
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

    /// The hosts and which one is active, as one item. Without it, the single pairing a build
    /// before the list kept (`legacy`) becomes the first host — and is removed only once the list
    /// is written, so it can't get lost on the way.
    static func loadHosts(account: String = "hosts", legacy: String = "relay") -> HostList {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
           let list = try? JSONDecoder().decode(HostList.self, from: data) { return list }
        guard let old = load(account: legacy) else { return HostList() }
        let list = HostList(legacy: old)
        if (try? saveHosts(list, account: account)) != nil { remove(account: legacy) }
        return list
    }

    /// Updated in place (not removed and added again): a failed write leaves the list as it was.
    static func saveHosts(_ list: HostList, account: String = "hosts") throws(PairingError) {
        guard !list.hosts.isEmpty else { remove(account: account); return }
        guard let data = try? JSONEncoder().encode(list) else { throw .keychain(errSecParam) }
        let item = [kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as [String: Any]
        var status = SecItemUpdate(query(account) as CFDictionary, item as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(account).merging(item) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw .keychain(status) }
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
