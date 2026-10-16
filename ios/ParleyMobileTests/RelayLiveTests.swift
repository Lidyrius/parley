import Foundation
import Testing
@testable import ParleyMobile

/// Against a live relay whose room a host has claimed and fills. Opt-in:
/// `TEST_RUNNER_PARLEY_TEST_LINK='parley://pair?…' xcodebuild test …`
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PARLEY_TEST_LINK"] != nil))
struct RelayLiveTests {
    let link = ProcessInfo.processInfo.environment["PARLEY_TEST_LINK"] ?? ""

    @Test func connectsReceivesAndResumes() async throws {
        let relay = Relay()
        relay.use(try Pairing.parse(link))
        relay.reconnect()
        defer { relay.disconnect() }
        try await until { relay.snapshot != nil && relay.hostOnline != nil }

        #expect(relay.status == .connected)
        let snapshot = try #require(relay.snapshot)
        #expect(!snapshot.sessions.isEmpty)
        #expect(abs(relay.skew) < 120_000)
        if let id = snapshot.sessions.first(where: \.canResume)?.id { relay.resume(id) }
        try await Task.sleep(for: .milliseconds(300))  // let the resume leave before the socket closes
    }

    @Test func aWrongSecretIsRejected() async throws {
        var c = try #require(URLComponents(string: link))
        c.queryItems = c.queryItems?.map { $0.name == "k" ? URLQueryItem(name: "k", value: "wrong-wrong-wrong-wrong") : $0 }
        let relay = Relay()
        relay.use(try Pairing.parse(try #require(c.string)))
        relay.reconnect()
        defer { relay.disconnect() }
        try await until { relay.failure != nil }
        #expect(relay.status == .rejected)
    }

    private func until(_ done: () -> Bool) async throws {
        for _ in 0..<50 where !done() { try await Task.sleep(for: .milliseconds(100)) }
        try #require(done())
    }
}
