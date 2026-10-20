import Foundation
import Testing
@testable import ParleyMobile

struct FormatTests {
    let at = 1_760_000_000_000.0

    @Test(arguments: [(0.0, "0:00"), (999, "0:00"), (61_000, "1:01"), (252_000, "4:12"), (3_725_000, "1:02:05"), (-5_000, "0:00")])
    func clock(_ ms: Double, _ text: String) {
        #expect(Fmt.clock(ms) == text)
    }

    @Test func timers() {
        let waiting = Session(id: "w", state: .waiting, since: at - 48_000, until: at + 252_000)
        #expect(Fmt.timer(waiting, at: at) == "noch 4:12")
        #expect(Fmt.timer(waiting, at: at + 400_000) == "noch 0:00")

        #expect(Fmt.timer(Session(id: "s", state: .stopped, since: at - 180_000), at: at) == "vor 3 min")
        #expect(Fmt.timer(Session(id: "s", state: .stopped, since: at - 5_000), at: at) == "vor 1 min")

        #expect(Fmt.timer(Session(id: "r", state: .working, since: at - 134_000), at: at) == "seit 2:14")
        // Waiting without an end counts up like every other state.
        #expect(Fmt.timer(Session(id: "p", state: .waiting, since: at - 10_000), at: at) == "seit 0:10")
    }

    /// The overview's cards (design C2): corner time, state wording, the one action.
    @Test func cards() {
        let at = 1_000_000.0
        #expect(Fmt.cornerTime(Session(id: "a", state: .working, since: at - 138_000), at: at) == "2:18")
        #expect(Fmt.cornerTime(Session(id: "a", state: .waiting, since: at - 60_000, until: at + 247_000), at: at) == "4:07")
        #expect(Fmt.cornerTime(Session(id: "a", state: .stopped, since: at - 180_000), at: at) == "vor 3 min")
        #expect(Fmt.cardState(Session(id: "a", state: .queued, callback: 0), at: at) == "wartet auf Rückruf")
        #expect(Fmt.cardState(Session(id: "a", state: .queued, callback: at + 42_000), at: at) == "ruft in 0:42 an")
        #expect(SessionAction(Session(id: "a", state: .queued, callback: 0)) == .callBack(now: false))
        #expect(SessionAction(Session(id: "a", state: .parked)) == .resume)
        #expect(SessionAction(Session(id: "a", state: .working)) == nil)
    }

    @Test func spans() {
        #expect(Fmt.span(0) == "0 min")
        #expect(Fmt.span(59 * 60_000) == "59 min")
        #expect(Fmt.span(72 * 60_000) == "1 h 12 min")
        #expect(Fmt.span(-1) == "0 min")
    }

    @Test func facts() {
        let stats = Stats(startedAt: at - 74 * 60_000, contextPercent: 41.6, costUsd: 3.1, turns: 14, replies: 6)
        #expect(Fmt.facts(Session(id: "a", stats: stats), at: at) == [
            Fact(label: "Laufzeit", value: "1 h 14 min"),
            Fact(label: "Kontext", value: "42 %"),
            Fact(label: "Kosten", value: "$3.10"),
            Fact(label: "Updates", value: "14 · 6 Antw."),
        ])
        #expect(Fmt.facts(Session(id: "b", stats: Stats()), at: at) == [Fact(label: "Updates", value: "0 · 0 Antw.")])
        #expect(Fmt.facts(Session(id: "c"), at: at).isEmpty)
    }

    @Test func stateLabels() {
        #expect(Fmt.stateLabel(Session(id: "a", state: .working)) == "arbeitet")
        #expect(Fmt.stateLabel(Session(id: "a", state: .listening)) == "hört zu")
        #expect(Fmt.stateLabel(Session(id: "a", state: .background)) == "Agent im Hintergrund")
        let agent = BackgroundTask(type: "subagent", description: "x")
        let shell = BackgroundTask(type: "shell", description: "y")
        #expect(Fmt.stateLabel(Session(id: "a", state: .background, tasks: [agent, agent])) == "2 Agents im Hintergrund")
        #expect(Fmt.stateLabel(Session(id: "a", state: .background, tasks: [shell])) == "Job im Hintergrund")
        #expect(Fmt.stateLabel(Session(id: "a", state: .background, tasks: [agent, shell])) == "2 Jobs im Hintergrund")
    }

    @Test func todayParts() {
        let today = Today(costUsd: 13.614, turns: 65, spokenSeconds: 754, rateLimits: [
            RateLimit(kind: "five_hour", percentUsed: 42.4),
            RateLimit(kind: "seven_day", percentUsed: 18),
            RateLimit(kind: "opus_weekly", percentUsed: 3),   // unknown kinds are left out, as in the mod
            RateLimit(kind: "five_hour", percentUsed: nil),
        ])
        #expect(Fmt.todayParts(today) == [
            Fact(label: "Kosten", value: "$13.61"),
            Fact(label: "Updates", value: "65"),
            Fact(label: "gesprochen", value: "13 min"),
            Fact(label: "5-h-Limit", value: "42 %"),
            Fact(label: "Woche", value: "18 %"),
        ])
    }

    @Test func countdownFraction() {
        let s = Session(id: "w", state: .waiting, since: at, until: at + 100_000)
        #expect(s.remaining(at: at) == 1)
        #expect(s.remaining(at: at + 25_000) == 0.75)
        #expect(s.remaining(at: at + 200_000) == 0)
        #expect(Session(id: "x", state: .working).remaining(at: at) == nil)
    }

    @Test func groupsNeedsSirFirstThenNewest() {
        let list = [Session(id: "p", state: .parked, since: 5), Session(id: "w1", state: .working, since: 1),
                    Session(id: "s", state: .stopped, since: 9), Session(id: "q", state: .queued, since: 2),
                    Session(id: "b", state: .background, since: 3), Session(id: "c", state: .idle, since: 1, callback: 0)]
        #expect(SessionGroup.sorted(list).map(\.id) == ["q", "c", "b", "w1", "p", "s"])
    }

    @Test func ringPerState() {
        #expect(RingKind(Session(id: "a", state: .speaking)) == .live)
        #expect(RingKind(Session(id: "a", state: .queued, voice: true)) == .live)
        #expect(RingKind(Session(id: "a", state: .working)) == .spin(fraction: 0.28, period: 1.6))
        #expect(RingKind(Session(id: "a", state: .queued)) == .spin(fraction: 0.12, period: 4))
        #expect(RingKind(Session(id: "a", state: .background)) == .background(jobs: 0))
        #expect(RingKind(Session(id: "a", state: .background, tasks: [.init(), .init(), .init()])) == .background(jobs: 3))
        #expect(RingKind(Session(id: "a", state: .waiting, until: at)) == .countdown)
        #expect(RingKind(Session(id: "a", state: .waiting)) == .stopped)   // as the mod: no end, no countdown
        #expect(RingKind(Session(id: "a", state: .parked)) == .parked)
        #expect(RingKind(Session(id: "a", state: .idle)) == .idle)
        #expect(RingKind(Session(id: "a", state: .stopped)) == .stopped)
    }

    @Test func names() {
        #expect(Session(id: "1234567890", label: "Parley", project: "vloude").name == "Parley")
        #expect(Session(id: "1234567890", project: "vloude").name == "vloude")
        #expect(Session(id: "1234567890").name == "12345678")
    }

    @Test func connectionStatus() {
        #expect(Relay.status(link: .connected, hostOnline: true, failure: nil) == .connected)
        #expect(Relay.status(link: .connected, hostOnline: false, failure: nil) == .hostOffline)
        #expect(Relay.status(link: .connected, hostOnline: nil, failure: nil) == .connecting)
        #expect(Relay.status(link: .connecting, hostOnline: nil, failure: .unauthorized) == .rejected)
        #expect(Relay.status(link: .connecting, hostOnline: nil, failure: .unknownRoom) == .unknownRoom)
        #expect(Relay.status(link: .connecting, hostOnline: nil, failure: .unreachable) == .unreachable)
        #expect(Relay.status(link: .idle, hostOnline: nil, failure: nil) == .connecting)
        #expect(ConnectionStatus.connected.label == "Mac verbunden")
        #expect(ConnectionStatus.hostOffline.label == "Mac offline")
        #expect(ConnectionStatus.connecting.label == "Verbinde…")
    }

    @Test func skewTakesTheFreshestPlausibleSample() {
        #expect(Relay.skew(sample: -800, best: nil) == -800)
        #expect(Relay.skew(sample: -9_000, best: -800) == -800)    // a replayed older frame
        #expect(Relay.skew(sample: -200, best: -800) == -200)
        #expect(Relay.skew(sample: -3_600_000, best: nil) == nil)  // hours old: not a clock offset
        #expect(Relay.skew(sample: 5_000, best: nil) == 5_000)     // phone clock behind
    }
}
