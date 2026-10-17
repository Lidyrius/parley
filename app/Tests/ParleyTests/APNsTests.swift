import XCTest
import CryptoKit
@testable import Parley

// VoIP push: the provider token (ES256 JWT), the request, the token cache — no network.
final class APNsTests: XCTestCase {
    private func unbase64url(_ s: Substring) throws -> Data {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return try XCTUnwrap(Data(base64Encoded: b))
    }

    func testKeyIdFromTheFileName() {
        XCTAssertEqual(APNs.keyId(fileName: "AuthKey_ABC123DEFG.p8"), "ABC123DEFG")
        XCTAssertEqual(APNs.keyId(fileName: "/Users/x/Downloads/AuthKey_Z9Y8X7W6V5.P8"), "Z9Y8X7W6V5")
        XCTAssertNil(APNs.keyId(fileName: "key.p8"))
        XCTAssertNil(APNs.keyId(fileName: "AuthKey_.p8"))
        XCTAssertNil(APNs.keyId(fileName: "AuthKey_AB-12.p8"))
    }

    func testJWTHeaderClaimsAndSignatureVerifiesWithThePublicKey() throws {
        let key = P256.Signing.PrivateKey()
        let jwt = try APNs.jwt(keyId: "ABC123DEFG", teamId: "384887N3UL", key: key,
                               issuedAt: Date(timeIntervalSince1970: 1_760_000_000.7))
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 3)
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: unbase64url(parts[0])) as? [String: String])
        XCTAssertEqual(header, ["alg": "ES256", "kid": "ABC123DEFG"])
        let claims = try XCTUnwrap(JSONSerialization.jsonObject(with: unbase64url(parts[1])) as? [String: Any])
        XCTAssertEqual(claims["iss"] as? String, "384887N3UL")
        XCTAssertEqual(claims["iat"] as? Int, 1_760_000_000)
        XCTAssertEqual(claims.count, 2)
        XCTAssertFalse(jwt.contains("="))
        let raw = try unbase64url(parts[2])
        XCTAssertEqual(raw.count, 64)                                     // r ‖ s, not DER
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: raw)
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
        XCTAssertFalse(P256.Signing.PrivateKey().publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    func testTheP8PEMLoads() throws {
        let key = P256.Signing.PrivateKey()
        XCTAssertTrue(key.pemRepresentation.hasPrefix("-----BEGIN PRIVATE KEY-----"))   // PKCS#8, like Apple's .p8
        XCTAssertEqual(try APNs.privateKey(pem: key.pemRepresentation).rawRepresentation, key.rawRepresentation)
        XCTAssertThrowsError(try APNs.privateKey(pem: "nope"))
    }

    func testRequestHostsHeadersAndPayload() throws {
        let prod = APNs.request(token: "ab12", env: "production", jwt: "J", label: "Tippfrei")
        XCTAssertEqual(prod.url?.absoluteString, "https://api.push.apple.com/3/device/ab12")
        XCTAssertEqual(prod.httpMethod, "POST")
        XCTAssertEqual(prod.value(forHTTPHeaderField: "authorization"), "bearer J")
        XCTAssertEqual(prod.value(forHTTPHeaderField: "apns-topic"), "de.developaway.parley.mobile.voip")
        XCTAssertEqual(prod.value(forHTTPHeaderField: "apns-push-type"), "voip")
        XCTAssertEqual(prod.value(forHTTPHeaderField: "apns-priority"), "10")
        XCTAssertEqual(prod.value(forHTTPHeaderField: "apns-expiration"), "0")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(prod.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["label": "Tippfrei"])
        XCTAssertEqual(APNs.request(token: "ab12", env: "development", jwt: "J", label: "x").url?.host, "api.sandbox.push.apple.com")
    }

    private final class World: @unchecked Sendable {
        var t = Date(timeIntervalSince1970: 1_760_000_000)
        var creds: APNsCredentials
        var requests: [URLRequest] = []
        init(_ c: APNsCredentials) { creds = c }
    }

    func testClientCachesTheTokenFiftyMinutesAndReportsStatusAndReason() async throws {
        let key = P256.Signing.PrivateKey()
        let w = World(APNsCredentials(keyId: "K1", teamId: "T1", keyP8: key.pemRepresentation))
        let client = APNsClient(credentials: { w.creds }, now: { w.t }, transport: { req in
            w.requests.append(req)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: "HTTP/2", headerFields: nil)!
            return (Data(#"{"reason":"BadDeviceToken"}"#.utf8), resp)
        }, log: { _ in })
        let first = await client.push(token: "ab", env: "production", label: "x")
        XCTAssertEqual(first.status, 400)
        XCTAssertEqual(first.reason, "BadDeviceToken")
        w.t += 49 * 60
        _ = await client.push(token: "ab", env: "production", label: "x")
        w.t += 2 * 60                                                      // 51 min after signing
        _ = await client.push(token: "ab", env: "production", label: "x")
        let auth = w.requests.map { $0.value(forHTTPHeaderField: "authorization") }
        XCTAssertEqual(auth.count, 3)
        XCTAssertEqual(auth[0], auth[1])
        XCTAssertNotEqual(auth[1], auth[2])
    }

    func testNotConfiguredSendsNothing() async {
        let w = World(APNsCredentials(keyId: "", teamId: "T", keyP8: ""))
        let client = APNsClient(credentials: { w.creds }, transport: { req in w.requests.append(req); throw URLError(.badURL) }, log: { _ in })
        let r = await client.push(token: "ab", env: "production", label: "x")
        XCTAssertEqual(r.status, -1)
        XCTAssertEqual(w.requests.count, 0)
        w.creds = APNsCredentials(keyId: "K", teamId: "T", keyP8: "not a key")
        let bad = await client.push(token: "ab", env: "production", label: "x")
        XCTAssertEqual(bad.reason, "bad key")
        XCTAssertEqual(w.requests.count, 0)
    }
}
