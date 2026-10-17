import XCTest
@testable import Parley

// The iPhone's Live Activity: content from GET /sessions, the APNs payloads, and when the host
// starts, updates and ends it.
final class LiveActivityTests: XCTestCase {
    private let sessions = """
    {"sessions":[
      {"id":"w","label":"Shirts","state":"working","since":1000000,"until":null,"stats":{"lastLine":"Ich teste noch."}},
      {"id":"s","label":"Alt","state":"stopped","since":1000000,"until":null},
      {"id":"c","label":"Website","state":"idle","since":2000000,"until":null,"callback":0,"stats":{"lastLine":"Soll ich deployen?"}},
      {"id":"i","label":"","project":"tippfrei","state":"idle","since":3000000,"until":null},
      {"id":"p","label":"Angebote","state":"waiting","since":1500000,"until":1800000},
      {"id":"b","label":"Relay","state":"background","since":1200000,"until":null}
    ],"today":{}}
    """

    func testContentOrdersByWhatSirIsNeededForAndLeavesStoppedOut() {
        let c = LiveActivity.content(fromSessions: sessions)
        XCTAssertEqual(c.alive, 5)
        XCTAssertEqual(c.sessions.map(\.id), ["c", "p", "w", "b"])   // at most 4
        XCTAssertEqual(c.sessions[0].callback, 0)
        XCTAssertEqual(c.sessions[1].until, 1800)                    // ms → s
        XCTAssertEqual(c.sessions[2].since, 1000)
        XCTAssertEqual(c.line, "Soll ich deployen?")                 // the most urgent one's line
        XCTAssertEqual(c.from, "Website")
        XCTAssertEqual(c.wantsSir, ["c"])
        XCTAssertEqual(LiveActivity.content(fromSessions: "nope"), LiveActivity.Content())
        let unnamed = LiveActivity.content(fromSessions: #"{"sessions":[{"id":"i","label":"","project":"tippfrei","state":"idle","since":0}]}"#)
        XCTAssertEqual(unnamed.sessions.first?.label, "tippfrei")
    }

    func testPayloads() throws {
        let c = LiveActivity.content(fromSessions: sessions)
        let now = Date(timeIntervalSince1970: 5000)
        func aps(_ e: LiveActivity.Event) throws -> [String: Any] {
            let o = try XCTUnwrap(JSONSerialization.jsonObject(with: LiveActivity.payload(e, c, now: now)) as? [String: Any])
            return try XCTUnwrap(o["aps"] as? [String: Any])
        }
        let start = try aps(.start)
        XCTAssertEqual(start["event"] as? String, "start")
        XCTAssertEqual(start["timestamp"] as? Int, 5000)
        XCTAssertEqual(start["attributes-type"] as? String, "ParleyAttributes")
        XCTAssertNotNil(start["attributes"] as? [String: Any])
        XCTAssertEqual((start["alert"] as? [String: Any])?["title"] as? String, "Parley unterwegs")
        XCTAssertEqual(start["stale-date"] as? Int, 5000 + 900)
        XCTAssertEqual(start["relevance-score"] as? Double, 100)
        let state = try XCTUnwrap(start["content-state"] as? [String: Any])
        XCTAssertEqual(state["alive"] as? Int, 5)
        XCTAssertEqual((state["sessions"] as? [[String: Any]])?.first?["label"] as? String, "Website")

        let update = try aps(.update)
        XCTAssertNil(update["alert"])
        XCTAssertNil(update["attributes-type"])
        let end = try aps(.end)
        XCTAssertEqual(end["dismissal-date"] as? Int, 5000)
        XCTAssertNil(end["stale-date"])
    }

    // MARK: - the feed

    private func content(_ states: [(String, String)], callback: String? = nil) -> LiveActivity.Content {
        LiveActivity.Content(sessions: states.map { LiveActivity.Row(id: $0.0, label: $0.0, state: $0.1, since: 0,
                                                                     callback: $0.0 == callback ? 0 : nil) },
                             alive: states.count)
    }

    func testStartsWhileAwayWithASessionThenUpdatesOnChangeOnly() {
        var feed = LiveActivityFeed()
        var t = Date(timeIntervalSince1970: 0)
        let one = content([("a", "working")])
        XCTAssertNil(feed.step(one, away: false, canStart: true, canUpdate: false, now: t))     // not away
        XCTAssertNil(feed.step(LiveActivity.Content(), away: true, canStart: true, canUpdate: false, now: t))   // nothing runs
        XCTAssertNil(feed.step(one, away: true, canStart: false, canUpdate: false, now: t))     // no start token yet
        XCTAssertEqual(feed.step(one, away: true, canStart: true, canUpdate: false, now: t), .start(one))
        t += 5
        let two = content([("a", "idle")])
        XCTAssertNil(feed.step(two, away: true, canStart: true, canUpdate: false, now: t))      // no update token yet
        feed.phoneReports(running: true, at: t)
        XCTAssertEqual(feed.step(two, away: true, canStart: true, canUpdate: true, now: t), .update(two, priority: 5))
        t += 5
        XCTAssertNil(feed.step(two, away: true, canStart: true, canUpdate: true, now: t))       // unchanged
        t += LiveActivityFeed.heartbeat
        XCTAssertEqual(feed.step(two, away: true, canStart: true, canUpdate: true, now: t), .update(two, priority: 5))
        t += 5
        let wants = content([("a", "idle")], callback: "a")
        XCTAssertEqual(feed.step(wants, away: true, canStart: true, canUpdate: true, now: t), .update(wants, priority: 10))
        t += 0.5
        XCTAssertNil(feed.step(two, away: true, canStart: true, canUpdate: true, now: t))       // ≥ 1 s apart
        t += 1
        XCTAssertEqual(feed.step(two, away: true, canStart: true, canUpdate: true, now: t), .update(two, priority: 5))
        t += 5
        XCTAssertEqual(feed.step(two, away: false, canStart: true, canUpdate: true, now: t), .end(two))   // Unterwegs off
        XCTAssertFalse(feed.running)
    }

    func testEndsWhenNothingRunsForTwoMinutesAndRenewsBeforeEightHours() {
        var feed = LiveActivityFeed()
        var t = Date(timeIntervalSince1970: 0)
        let one = content([("a", "working")])
        _ = feed.step(one, away: true, canStart: true, canUpdate: true, now: t)
        feed.phoneReports(running: true, at: t)
        let none = LiveActivity.Content()
        t += 60
        XCTAssertEqual(feed.step(none, away: true, canStart: true, canUpdate: true, now: t), .update(none, priority: 5))
        t += LiveActivityFeed.emptyGrace
        XCTAssertEqual(feed.step(none, away: true, canStart: true, canUpdate: true, now: t), .end(none))

        t += 10
        XCTAssertEqual(feed.step(one, away: true, canStart: true, canUpdate: true, now: t), .start(one))
        t += LiveActivityFeed.renewAfter
        XCTAssertEqual(feed.step(one, away: true, canStart: true, canUpdate: true, now: t), .end(one))
        XCTAssertEqual(feed.step(one, away: true, canStart: true, canUpdate: true, now: t), .start(one))   // right away
        feed.phoneReports(running: false, at: t + 5)   // the replaced one's end: not Sir's
        XCTAssertTrue(feed.running)
        XCTAssertFalse(feed.dismissed)
    }

    func testSwipedAwayStaysAwayUntilUnterwegsGoesOffAndOn() {
        var feed = LiveActivityFeed()
        var t = Date(timeIntervalSince1970: 0)
        let one = content([("a", "working")])
        _ = feed.step(one, away: true, canStart: true, canUpdate: false, now: t)
        t += 120
        feed.phoneReports(running: false, at: t)
        XCTAssertTrue(feed.dismissed)
        t += 600
        XCTAssertNil(feed.step(one, away: true, canStart: true, canUpdate: false, now: t))
        XCTAssertNil(feed.step(one, away: false, canStart: true, canUpdate: false, now: t))
        t += 2
        XCTAssertEqual(feed.step(one, away: true, canStart: true, canUpdate: false, now: t), .start(one))
    }

    // MARK: - the phone's frames

    func testActivityFrames() {
        XCTAssertEqual(RelayFrame.parse(#"{"t":"activity","start":"ABCD","env":"development"}"#), .activityStart(token: "abcd", env: "development"))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"activity","token":"beef","env":"production"}"#), .activity(token: "beef", env: "production"))
        XCTAssertEqual(RelayFrame.parse(#"{"t":"activity","token":"","env":"production"}"#), .activity(token: "", env: "production"))
        XCTAssertNil(RelayFrame.parse(#"{"t":"activity","token":"zz"}"#))
        XCTAssertNil(RelayFrame.parse(#"{"t":"activity"}"#))
    }

    func testPhoneHubKeepsTheTokens() {
        let hub = PhoneHub(store: .memory(), log: { _ in })
        XCTAssertNil(hub.activityStartTarget)
        hub.handle(.activityStart(token: "aa", env: "development"))
        hub.handle(.activity(token: "bb", env: "development"))
        XCTAssertEqual(hub.activityStartTarget?.token, "aa")
        XCTAssertEqual(hub.activityTarget?.token, "bb")
        XCTAssertEqual(hub.activityTarget?.env, "development")
        hub.handle(.activity(token: "", env: "development"))
        XCTAssertNil(hub.activityTarget)
    }
}
