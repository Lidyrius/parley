import XCTest
@testable import Parley

// Shared sessions: invite → the guest asks → Sir lets him in (fresh room) → he reads only his
// session and his words reach it marked with his name → Sir ends it.
final class SharesTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_760_000_000) }
    private final class Fake: RelaySocket, @unchecked Sendable {
        let request: URLRequest
        var sent: [String] = []
        init(_ r: URLRequest) { request = r }
        func send(_ text: String, completion: @escaping @Sendable ((any Error)?) -> Void) { sent.append(text); completion(nil) }
        func send(data: Data, completion: @escaping @Sendable ((any Error)?) -> Void) { completion(nil) }
        func receive(_ handler: @escaping @Sendable (Result<RelayInbound, any Error>) -> Void) {}
        func close() {}
    }
    private final class Box: @unchecked Sendable { var toSir: [String] = []; var sockets: [Fake] = [] }

    private var clock = Clock()
    private var reg: SessionRegistry!
    private var server: ControlServer!
    private var hub: ShareHub!
    private var box = Box()
    private var file: URL!

    override func setUp() {
        let c = clock, b = box
        reg = SessionRegistry(now: { c.t }, phase: { "idle" }, daily: DailyStats(now: { c.t }))
        server = ControlServer(sessions: reg, now: { c.t })
        file = FileManager.default.temporaryDirectory.appendingPathComponent("parley-shares-\(UUID().uuidString).json")
        hub = ShareHub(server: server, file: file, now: { c.t }, relayURL: { "https://relay.test" }) { s, hub in
            let c = RelayClient(config: s.config, sessions: { "{}" }, resume: { _ in },
                                connect: { let f = Fake($0); b.sockets.append(f); return f }, log: { _ in })
            c?.onEvent = { [weak hub] in hub?.guest(s.id, $0) }
            return c
        }
        hub.toSir = { b.toSir.append($0) }
        presence("web", "Website")
        presence("shop", "Shop")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: file) }

    @discardableResult
    private func presence(_ id: String, _ label: String = "") -> String {
        server.handle(HTTPRequest(method: "POST", path: "/presence",
                                  body: Data(#"{"session_id":"\#(id)","label":"\#(label)","cwd":"/x/\#(id)","state":"idle"}"#.utf8))).1
    }

    private func instruction(_ id: String) -> String {
        _ = server.sessionsJSON()   // the server queue has the delivery
        let r = presence(id)
        return ((try? JSONSerialization.jsonObject(with: Data(r.utf8))) as? [String: String])?["instruction"] ?? ""
    }

    func testInviteAskApproveWriteEnd() throws {
        let (invite, link) = try XCTUnwrap(hub.create(session: "web"))
        XCTAssertTrue(link.hasPrefix("parley://join?u=https%3A%2F%2Frelay.test&r=\(invite.room)&k="), link)
        XCTAssertTrue(link.contains("&s=Website&h="))
        XCTAssertNil(hub.create(session: "nope"))
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)                                           // keys inside

        hub.guest(invite.id, .say(id: "web", text: "vorab"))                    // not let in yet: nothing
        hub.guest(invite.id, .join(name: "  Max "))
        XCTAssertEqual(hub.list().first?.state, "asking")
        XCTAssertTrue(box.toSir.last?.contains(#""name":"Max""#) ?? false)      // Sir's phone asks him
        XCTAssertEqual(instruction("web"), "")

        hub.approve(invite.id, role: "Marketing", listen: false, full: false, mine: "Technik")
        let s = try XCTUnwrap(hub.list().first)
        XCTAssertEqual(s.state, "active")
        XCTAssertNotEqual(s.room, invite.room)                                  // the link's room is dead
        XCTAssertNotEqual(s.key, invite.key)
        let note = instruction("web")
        XCTAssertTrue(note.contains("mit Max geteilt") && note.contains("Marketing") && note.contains("Technik")
                      && note.contains(#"<speak to="Max">"#), note)
        let rows = server.sessionsJSON()
        XCTAssertTrue(rows.contains(#""shared":[{"#) && rows.contains(#""name":"Max""#) && rows.contains(#""role":"Marketing""#), rows)

        hub.guest(invite.id, .say(id: "web", text: "Nimm Variante B."))
        XCTAssertEqual(hub.list().count, 1)
        XCTAssertEqual(instruction("web"), "[Nachricht von Max · Marketing]\nNimm Variante B.")
        hub.guest(invite.id, .say(id: "shop", text: "psst"))                    // not his session
        XCTAssertEqual(hub.list().count, 1)
        XCTAssertEqual(instruction("shop"), "")

        hub.remove(invite.id)
        XCTAssertTrue(hub.list().isEmpty)
        XCTAssertTrue(instruction("web").contains("nicht mehr in dieser Session"))
        XCTAssertFalse(server.sessionsJSON().contains("shared"))
    }

    func testListenerCannotWriteAndInvitesExpire() throws {
        let (invite, _) = try XCTUnwrap(hub.create(session: "web"))
        hub.guest(invite.id, .join(name: "Kunde"))
        hub.approve(invite.id, role: "", listen: true, full: false, mine: nil)
        _ = instruction("web")
        hub.guest(invite.id, .say(id: "web", text: "hallo"))
        XCTAssertEqual(hub.list().count, 1)
        XCTAssertEqual(instruction("web"), "")                                   // "nur zuhören"

        let (old, _) = try XCTUnwrap(hub.create(session: "shop"))
        clock.t += Shares.inviteTTL + 1
        _ = hub.create(session: "shop")                                          // prunes on the way
        XCTAssertFalse(hub.list().contains { $0.id == old.id })
        XCTAssertTrue(hub.list().contains { $0.id == invite.id })                // an active share stays
    }

    func testGuestViewAuthorsAndFrames() {
        let only = server.sessionsJSON(only: "web")
        XCTAssertTrue(only.contains(#""id":"web""#))
        XCTAssertFalse(only.contains(#""id":"shop""#))
        XCTAssertTrue(only.contains(#""reminders":[]"#) && only.contains(#""snapshots":[]"#))

        XCTAssertEqual(Shares.author("[Nachricht von Max · Marketing]\nNimm B.").0, "Max")
        XCTAssertEqual(Shares.author("[Nachricht von Max · Marketing]\nNimm B.").1, "Nimm B.")
        XCTAssertEqual(Shares.author("[Nachricht von Max]\nok").0, "Max")
        XCTAssertNil(Shares.author("Mach weiter").0)

        XCTAssertEqual(RelayFrame.parse(#"{"t":"join","name":"Max"}"#), .join(name: "Max"))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"share","op":"create","id":"web"}"#), .shareCreate(session: "web"))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"share","op":"approve","id":"x","role":"M","listen":true}"#),
                       .shareApprove(id: "x", role: "M", listen: true, full: false, mine: nil))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"share","op":"remove","id":"x"}"#), .shareRemove("x"))
        XCTAssertNil(RelayFrame.parse(#"{"t":"share","op":"create"}"#))
    }
}
