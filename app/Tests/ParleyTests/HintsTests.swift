import XCTest
@testable import Parley

// Protocol v10: Hinweise (the alerts file) and the remote desktop channels through the relay.
final class HintsTests: XCTestCase {
    func testParseLinesAndIds() {
        let lines = Hints.parse("[saf] Login bei Google verloren\r\n\n  Backup hängt  \n[saf] Login bei Google verloren\n[] leer\n[dev]\n[a b] c\n")
        XCTAssertEqual(lines, [
            Hints.Line(id: "7110458bb999c553", text: "Login bei Google verloren", desktop: "saf"),
            Hints.Line(id: "7528bf5590836676", text: "Backup hängt", desktop: nil),   // id of the trimmed line
            Hints.Line(id: Hints.id("[] leer"), text: "[] leer", desktop: nil),
            Hints.Line(id: Hints.id("[dev]"), text: "[dev]", desktop: nil),
            Hints.Line(id: Hints.id("[a b] c"), text: "[a b] c", desktop: nil),
        ])
    }

    func testUpdateKeepsSinceAndPushesOnlyNewLines() {
        var seen: [String: Int64] = [:]
        let a = Hints.parse("eins\nzwei")
        var r = Hints.update(&seen, a, now: 1000)
        XCTAssertEqual(r.new.map(\.text), ["eins", "zwei"])
        r = Hints.update(&seen, Hints.parse("zwei\ndrei"), now: 2000)
        XCTAssertEqual(r.new.map(\.text), ["drei"])
        XCTAssertEqual(r.alerts.map(\.since), [1000, 2000])
        r = Hints.update(&seen, Hints.parse("eins"), now: 3000)   // gone and back: pushes again
        XCTAssertEqual(r.new.map(\.text), ["eins"])
        XCTAssertEqual(r.alerts.map(\.since), [3000])
    }

    func testConfig() {
        let raw: [String: Any] = ["alertsFile": " ~/alerts.txt ", "alertsCheck": "keepalive.sh once",
                                  "vnc": ["saf": ["url": "ws://10.0.0.1:6080/websockify", "password": "pw"],
                                          "mac": ["url": "tcp://127.0.0.1:5900"], "bad": ["password": "x"]]]
        let c = HintsConfig.from { raw[$0] }
        XCTAssertEqual(c.alertsFile, "~/alerts.txt")
        XCTAssertEqual(c.alertsCheck, "keepalive.sh once")
        XCTAssertEqual(c.desktops, ["mac", "saf"])
        XCTAssertEqual(c.vnc["mac"], HostDesktop(url: "tcp://127.0.0.1:5900", password: ""))
        XCTAssertEqual(HintsConfig.from { _ in nil }, HintsConfig())
    }

    func testSessionsJSONCarriesAlertsOnlyWhenThere() throws {
        let reg = SessionRegistry(now: { Date() }, phase: { "idle" }, daily: DailyStats(now: { Date() }))
        XCTAssertFalse(reg.json().contains("alerts"))
        XCTAssertFalse(reg.json().contains("desktops"))
        reg.alerts = [Hints.Alert(id: "abc", text: "Login weg", since: 5, desktop: "saf")]
        reg.alertsChecking = true
        reg.desktops = ["saf"]
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reg.json().utf8)) as? [String: Any])
        XCTAssertEqual((obj["alerts"] as? [[String: Any]])?.first?["desktop"] as? String, "saf")
        XCTAssertEqual(obj["alertsChecking"] as? Bool, true)
        XCTAssertEqual(obj["desktops"] as? [String], ["saf"])
        XCTAssertFalse(reg.json(only: "x").contains("alerts"))   // never to a guest
    }

    func testPhoneFrames() {
        XCTAssertEqual(RelayFrame.parse(#"{"t":"alerts","op":"check"}"#), .alertsCheck)
        XCTAssertNil(RelayFrame.parse(#"{"t":"alerts","op":"other"}"#))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"vnc","op":"open","ch":"abcd1234","desktop":"saf"}"#), .vnc(.open(ch: "abcd1234", desktop: "saf")))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"vnc","ch":"abcd1234","d":"AQID"}"#), .vnc(.data(ch: "abcd1234", Data([1, 2, 3]))))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"vnc","op":"close","ch":"abcd1234"}"#), .vnc(.close(ch: "abcd1234")))
        XCTAssertNil(RelayFrame.parse(#"{"t":"vnc","op":"open","ch":"short","desktop":"saf"}"#))
        XCTAssertNil(RelayFrame.parse(#"{"t":"vnc","op":"close","ch":"abcd-1234"}"#))
        XCTAssertNil(RelayFrame.parse(#"{"t":"vnc","op":"close","ch":"\#(String(repeating: "a", count: 33))"}"#))
        XCTAssertNil(RelayFrame.parse(#"{"t":"vnc","ch":"abcd1234","d":"not base64!"}"#))
        XCTAssertNil(RelayFrame.parse(#"{"t":"vnc","op":"open","ch":"abcd1234"}"#))
    }

    func testHostFrames() throws {
        XCTAssertEqual(VncFrame.opened("abcd1234", password: "p/w"), #"{"ch":"abcd1234","ok":true,"op":"open","password":"p/w","t":"vnc"}"#)
        XCTAssertEqual(VncFrame.failed("abcd1234", error: "Unbekannter Desktop"), #"{"ch":"abcd1234","error":"Unbekannter Desktop","ok":false,"op":"open","t":"vnc"}"#)
        XCTAssertEqual(VncFrame.closed("abcd1234"), #"{"ch":"abcd1234","op":"close","t":"vnc"}"#)
        let bytes = Data((0..<(VncFrame.chunk * 2 + 10)).map { UInt8($0 & 0xff) })
        let frames = VncFrame.data("abcd1234", bytes)
        XCTAssertEqual(frames.count, 3)
        let back = try frames.map { f -> Data in
            let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(f.utf8)) as? [String: Any])
            XCTAssertNil(o["op"])
            return try XCTUnwrap(Data(base64Encoded: o["d"] as? String ?? ""))
        }
        XCTAssertEqual(back.map(\.count), [VncFrame.chunk, VncFrame.chunk, 10])
        XCTAssertEqual(back.reduce(Data(), +), bytes)
    }

    // A fake desktop: ready at once, records what the phone sent.
    private final class FakeLink: DesktopLink, @unchecked Sendable {
        var sent: [Data] = []
        var cancelled = false
        var end: (@Sendable (String?) -> Void)?
        func start(queue: DispatchQueue, ready: @escaping @Sendable () -> Void, data: @escaping @Sendable (Data) -> Void,
                   end: @escaping @Sendable (String?) -> Void) {
            self.end = end
            ready()
            data(Data([9]))
        }
        func send(_ data: Data) { sent.append(data) }
        func cancel() { cancelled = true }
    }

    private final class Box: @unchecked Sendable { var frames: [String] = []; var links: [FakeLink] = []; var t = Date() }

    func testTunnels() {
        let box = Box()
        let tunnels = VncTunnels(send: { box.frames.append($0) },
                                 desktops: { ["saf": HostDesktop(url: "tcp://x:1", password: "pw")] },
                                 connect: { _ in let l = FakeLink(); box.links.append(l); return l },
                                 now: { box.t })
        tunnels.sync { tunnels.handleOnQueue(.open(ch: "unknown1", desktop: "nope")) }
        XCTAssertEqual(box.frames.last, VncFrame.failed("unknown1", error: "Diesen Desktop gibt es hier nicht."))

        tunnels.sync { tunnels.handleOnQueue(.open(ch: "chan0001", desktop: "saf")) }
        XCTAssertEqual(Array(box.frames.suffix(2)), [VncFrame.opened("chan0001", password: "pw")] + VncFrame.data("chan0001", Data([9])))
        tunnels.sync { tunnels.handleOnQueue(.data(ch: "chan0001", Data([1, 2]))) }
        XCTAssertEqual(box.links[0].sent, [Data([1, 2])])

        tunnels.sync { tunnels.handleOnQueue(.open(ch: "chan0002", desktop: "saf")) }
        tunnels.sync { tunnels.handleOnQueue(.open(ch: "chan0003", desktop: "saf")) }   // a third closes the oldest
        XCTAssertTrue(box.links[0].cancelled)
        XCTAssertTrue(box.frames.contains(VncFrame.closed("chan0001")))
        XCTAssertEqual(tunnels.count, 2)

        tunnels.sync { box.links[1].end?(nil) }   // the desktop closes chan0002
        XCTAssertEqual(tunnels.count, 1)
        XCTAssertEqual(box.frames.last, VncFrame.closed("chan0002"))

        box.t = box.t.addingTimeInterval(VncTunnels.idleLimit)   // 10 min without phone data
        tunnels.sync { tunnels.sweep() }
        XCTAssertEqual(tunnels.count, 0)
        XCTAssertEqual(box.frames.last, VncFrame.closed("chan0003"))
    }
}
