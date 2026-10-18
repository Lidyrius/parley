import CryptoKit
import Foundation

// End-to-end encryption between the host and the phones (docs/IPHONE.md → v5): AES-256-GCM under
// the pairing key, which only travels in the QR code — the relay can neither read nor forge a
// frame. Sealed bytes: nonce ‖ ciphertext ‖ tag; plaintext: sender clock (8 bytes BE, epoch ms)
// ‖ payload. Text frames keep their `t` readable outside (the relay caches `sessions`).
struct RelaySeal: Sendable {
    private let key: SymmetricKey

    // The pairing key (32 bytes, base64url); nil when it isn't one.
    init?(key: String) {
        guard let data = Self.base64url(key), data.count == 32 else { return nil }
        self.key = SymmetricKey(data: data)
    }

    static let window: TimeInterval = 120

    // `{"t":"<t>","e":"<sealed>"}`; nil for a frame without a string `t`.
    func text(_ json: String, at now: Date) -> String? {
        guard let f = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let t = f["t"] as? String, let sealed = seal(Data(json.utf8), aad: "parley1/text/" + t, at: now),
              let wire = try? JSONSerialization.data(withJSONObject: ["t": t, "e": sealed.base64EncodedString()]) else { return nil }
        return String(decoding: wire, as: UTF8.self)
    }

    func binary(_ data: Data, at now: Date) -> Data? { seal(data, aad: "parley1/bin", at: now) }

    // A sealed text frame → its JSON, sender clock and nonce; nil unless it opens and matches its `t`.
    func open(text wire: String) -> (json: String, at: Date, nonce: Data)? {
        guard let f = (try? JSONSerialization.jsonObject(with: Data(wire.utf8))) as? [String: Any],
              let t = f["t"] as? String, let e = f["e"] as? String, let sealed = Data(base64Encoded: e),
              let (payload, at, nonce) = open(sealed, aad: "parley1/text/" + t),
              let inner = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              inner["t"] as? String == t else { return nil }
        return (String(decoding: payload, as: UTF8.self), at, nonce)
    }

    func open(binary sealed: Data) -> (data: Data, at: Date, nonce: Data)? {
        open(sealed, aad: "parley1/bin")
    }

    private func seal(_ payload: Data, aad: String, at now: Date) -> Data? {
        var clock = UInt64(max(0, now.timeIntervalSince1970 * 1000).rounded()).bigEndian
        let plain = Data(bytes: &clock, count: 8) + payload
        return try? AES.GCM.seal(plain, using: key, authenticating: Data(aad.utf8)).combined
    }

    private func open(_ sealed: Data, aad: String) -> (Data, Date, Data)? {
        guard sealed.count >= 12 + 16 + 8, let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: key, authenticating: Data(aad.utf8)), plain.count >= 8 else { return nil }
        let ms = plain.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return (Data(plain.dropFirst(8)), Date(timeIntervalSince1970: Double(ms) / 1000), Data(sealed.prefix(12)))
    }

    static func base64url(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        return Data(base64Encoded: b)
    }
}

// The host's replay check on what the phones send: a frame's clock within the window of its own,
// and a nonce not seen in that window.
struct ReplayGuard {
    private var seen: [Data: Date] = [:]
    private var pruned = Date.distantPast

    mutating func accept(at sent: Date, nonce: Data, now: Date) -> Bool {
        guard abs(now.timeIntervalSince(sent)) <= RelaySeal.window else { return false }
        if now.timeIntervalSince(pruned) > 10 {   // ~50 audio frames a second: prune now and then
            seen = seen.filter { now.timeIntervalSince($0.value) <= RelaySeal.window }
            pruned = now
        }
        guard seen[nonce] == nil else { return false }
        seen[nonce] = now
        return true
    }
}
