import Foundation
import Testing
@testable import ParleyMobile

struct FrameTests {
    /// What the macOS host's GET /sessions encodes (app/Sources/Parley/Sessions.swift), plus `t` and `at`.
    let full = """
    {"t":"sessions","at":1760000000000,
     "sessions":[
      {"id":"s1","label":"Parley","project":"vloude","state":"waiting","since":1759999950000,"until":1760000252000,
       "voice":false,"resumable":true,"tasks":[{"type":"subagent","description":"Tests"}],"host":"local_abc",
       "stats":{"startedAt":1759996400000,"contextPercent":41.6,"costUsd":3.1234,"turns":14,"replies":6,"lastLine":"Fertig."}},
      {"id":"s2","label":"Shirts","project":"ds-shirts","state":"working","since":1759999866000,"until":null,
       "voice":true,"resumable":false,"tasks":[],"host":null,
       "stats":{"startedAt":null,"contextPercent":null,"costUsd":null,"turns":0,"replies":0,"lastLine":null}}
     ],
     "today":{"costUsd":13.61,"turns":65,"spokenSeconds":754,
              "rateLimits":[{"kind":"five_hour","percentUsed":42.4,"resetsAt":"2026-10-16T18:00:00Z"},{"kind":null,"percentUsed":null,"resetsAt":null}]}}
    """

    @Test func decodesAFullSessionsFrame() throws {
        guard case .sessions(let snap)? = Frame.decode(full) else { Issue.record("not a sessions frame"); return }
        #expect(snap.at == 1_760_000_000_000)
        #expect(snap.sessions.map(\.id) == ["s1", "s2"])

        let s = snap.sessions[0]
        #expect(s.label == "Parley" && s.project == "vloude")
        #expect(s.state == .waiting)
        #expect(s.since == 1_759_999_950_000 && s.until == 1_760_000_252_000)
        #expect(s.resumable == true && s.voice == false)
        #expect(s.tasks == [BackgroundTask(type: "subagent", description: "Tests")])
        #expect(s.host == "local_abc")
        #expect(s.stats == Stats(startedAt: 1_759_996_400_000, contextPercent: 41.6, costUsd: 3.1234, turns: 14, replies: 6, lastLine: "Fertig."))

        #expect(snap.sessions[1].until == nil)
        #expect(snap.sessions[1].stats?.startedAt == nil)

        let today = try #require(snap.today)
        #expect(today.costUsd == 13.61 && today.turns == 65 && today.spokenSeconds == 754)
        #expect(today.rateLimits.count == 2)
        #expect(today.rateLimits[0] == RateLimit(kind: "five_hour", percentUsed: 42.4, resetsAt: "2026-10-16T18:00:00Z"))
    }

    @Test func decodesAMinimalFrame() throws {
        guard case .sessions(let snap)? = Frame.decode(#"{"t":"sessions","sessions":[{"id":"x"}]}"#) else {
            Issue.record("not a sessions frame"); return
        }
        #expect(snap.at == nil && snap.today == nil)
        #expect(snap.sessions == [Session(id: "x")])
        #expect(snap.sessions[0].name == "x")
        #expect(snap.sessions[0].canResume == false)
    }

    @Test func emptyFrameStillDecodes() {
        #expect(Frame.decode(#"{"t":"sessions"}"#) == .sessions(Snapshot()))
    }

    @Test func toleratesWrongTypesAndUnknownValues() throws {
        let text = #"""
        {"t":"sessions","at":"soon","today":{"turns":"many","rateLimits":7},
         "sessions":[{"id":"a","state":"dancing","since":"x","voice":"yes","tasks":[{"type":1},"junk"],"stats":[]},
                     {"label":"no id"}, 42, {"id":"b","state":"parked","future":{"x":1}}]}
        """#
        guard case .sessions(let snap)? = Frame.decode(text) else { Issue.record("not a sessions frame"); return }
        #expect(snap.at == nil)
        #expect(snap.today == Today())
        #expect(snap.sessions.map(\.id) == ["a", "b"])       // rows without an id are dropped
        #expect(snap.sessions[0].state == .idle)             // unknown state reads as idle
        #expect(snap.sessions[0].voice == false)
        #expect(snap.sessions[0].tasks == [BackgroundTask()]) // a junk element is skipped
        #expect(snap.sessions[0].stats == nil)
        #expect(snap.sessions[1].canResume)                  // parked without `resumable`
    }

    @Test func decodesPeer() {
        #expect(Frame.decode(#"{"t":"peer","host":true}"#) == .peer(host: true))
        #expect(Frame.decode(#"{"t":"peer","host":false}"#) == .peer(host: false))
        #expect(Frame.decode(#"{"t":"peer"}"#) == .peer(host: false))
    }

    @Test func unknownTypesAreKeptAsOther() {
        #expect(Frame.decode(#"{"t":"audio-start","codec":"opus"}"#) == .other("audio-start"))
    }

    // MARK: - Protocol v2

    @Test(arguments: HostAudio.allCases)
    func decodesAudioStates(_ state: HostAudio) {
        #expect(Frame.decode(#"{"t":"audio","state":"\#(state.rawValue)"}"#) == .audio(state, label: nil))
    }

    @Test func audioFrameIsLenient() {
        // An optional label (not in the contract) is taken when a host sends one.
        #expect(Frame.decode(#"{"t":"audio","state":"speaking","label":" Tippfrei "}"#) == .audio(.speaking, label: "Tippfrei"))
        #expect(Frame.decode(#"{"t":"audio","state":"idle","label":""}"#) == .audio(.idle, label: nil))
        #expect(Frame.decode(#"{"t":"audio","state":"idle","label":5,"x":[1]}"#) == .audio(.idle, label: nil))
        // A state it does not know (or none) is ignored rather than guessed.
        #expect(Frame.decode(#"{"t":"audio","state":"singing"}"#) == .other("audio"))
        #expect(Frame.decode(#"{"t":"audio"}"#) == .other("audio"))
        #expect(Frame.decode(#"{"t":"audio","state":3}"#) == .other("audio"))
    }

    @Test func decodesRing() {
        #expect(Frame.decode(#"{"t":"ring","label":"Shirts"}"#) == .ring(label: "Shirts"))
        #expect(Frame.decode(#"{"t":"ring","label":"  "}"#) == .ring(label: nil))
        #expect(Frame.decode(#"{"t":"ring"}"#) == .ring(label: nil))
        #expect(Frame.decode(#"{"t":"ring","label":null}"#) == .ring(label: nil))
    }

    @Test func encodesCallControl() {
        #expect(Outgoing.call(started: true) == #"{"down":24000,"state":"start","t":"call"}"#)
        #expect(Outgoing.call(started: false) == #"{"state":"end","t":"call"}"#)
        #expect(Outgoing.wake == #"{"t":"wake"}"#)
        #expect(Outgoing.away(true) == #"{"on":true,"t":"away"}"#)
        #expect(Outgoing.away(false) == #"{"on":false,"t":"away"}"#)
        #expect(Outgoing.push(token: "00ffab", env: .production) == #"{"env":"production","t":"push","token":"00ffab"}"#)
        #expect(Outgoing.push(token: "01", env: .development) == #"{"env":"development","t":"push","token":"01"}"#)
        #expect(Outgoing.alertPush(token: "ab", env: .production) == #"{"env":"production","kind":"alert","t":"push","token":"ab"}"#)
        #expect(Outgoing.silent(true) == #"{"on":true,"t":"silent"}"#)
        #expect(Outgoing.history(id: "s1") == #"{"id":"s1","t":"history"}"#)
        #expect(Outgoing.history(id: "s1", before: "a#0") == #"{"before":"a#0","id":"s1","t":"history"}"#)
        #expect(Outgoing.image(id: "s1", key: "u#0") == #"{"id":"s1","key":"u#0","t":"image"}"#)
        #expect(Outgoing.say(id: "s1", text: "Mach \"weiter\"") == #"{"id":"s1","t":"say","text":"Mach \"weiter\""}"#)
    }

    /// What the phone sends must read back the same through a generic JSON parser (the host's).
    @Test func outgoingIsValidJSON() throws {
        let away = try #require(JSONSerialization.jsonObject(with: Data(Outgoing.away(true).utf8)) as? [String: Any])
        #expect(away["t"] as? String == "away" && away["on"] as? Bool == true)
        let push = try #require(JSONSerialization.jsonObject(with: Data(Outgoing.push(token: "ab", env: .development).utf8)) as? [String: Any])
        #expect(push["env"] as? String == "development" && push["token"] as? String == "ab")
        let hello = try #require(JSONSerialization.jsonObject(with: Data(Outgoing.hello(device: "Sydney’s \"iPhone\"").utf8)) as? [String: Any])
        #expect(hello["device"] as? String == "Sydney’s \"iPhone\"")
    }

    @Test(arguments: ["pong", "", "[]", #"{"type":"sessions"}"#, #"{"t":5}"#])
    func ignoresNonMessages(_ text: String) {
        #expect(Frame.decode(text) == nil)
    }

    @Test func encodesOutgoingMessages() {
        #expect(Outgoing.hello(device: "iPhone") == #"{"device":"iPhone","t":"hello"}"#)
        #expect(Outgoing.resume(id: "abc/1") == #"{"id":"abc/1","t":"resume"}"#)
    }

    @Test func demoFrameDecodes() throws {
        guard case .sessions(let snap)? = Frame.decode(Demo.frame(now: .now)) else { Issue.record("demo frame broken"); return }
        #expect(snap.sessions.count == 8)
        #expect(Set(snap.sessions.map(\.state)).count == 8)
        #expect(snap.sessions.contains { $0.state == .waiting && $0.until != nil })
        #expect(snap.sessions.contains { $0.state == .background && !$0.tasks.isEmpty })
        #expect(snap.today?.rateLimits.count == 2)
    }

    @Test func historyAndImageFrames() {
        let h = Frame.decode(#"{"t":"history","id":"s1","items":[{"id":"a#0","k":"assistant","text":"Fertig.","at":1},{"id":"r#0","k":"image","who":"assistant"},{"id":"v#0","k":"voice","text":"Ja"},{"id":"x#0","k":"новое"},{"k":"user"},7]}"#)
        #expect(h == .history(id: "s1", items: [
            ChatItem(id: "a#0", kind: .assistant, text: "Fertig.", at: 1),
            ChatItem(id: "r#0", kind: .image),
            ChatItem(id: "v#0", kind: .voice, text: "Ja"),
            ChatItem(id: "x#0", kind: .other),
        ], before: nil, more: false))
        #expect(Frame.decode(#"{"t":"history","id":"s1","before":"a#0","more":true,"items":[]}"#) == .history(id: "s1", items: [], before: "a#0", more: true))
        #expect(Frame.decode(#"{"t":"history","items":[]}"#) == .other("history"))
        #expect(Frame.decode(#"{"t":"image","key":"r#0","mime":"image/jpeg","data":"/9j/"}"#) == .image(key: "r#0", data: Data([0xFF, 0xD8, 0xFF])))
        #expect(Frame.decode(#"{"t":"image","key":"r#0"}"#) == .image(key: "r#0", data: nil))
    }

    @Test func toolStepsFoldIntoGroups() {
        func i(_ id: String, _ k: ChatItem.Kind, _ t: String? = nil, _ add: Int? = nil, _ del: Int? = nil) -> ChatItem {
            ChatItem(id: id, kind: k, text: t, add: add, del: del)
        }
        let rows = SessionView.rows([i("u", .user, "Los"), i("t1", .tool, "Bash · a"), i("t2", .tool, "Write · b", 62, 0),
                                     i("t3", .tool, "Bash · c"), i("a", .assistant, "Fertig"), i("t4", .tool, "Bash · Delete probe")])
        #expect(rows.map(\.id) == ["u", "tools-t1", "a", "tools-t4"])
        guard case .tools(let run) = rows[1], case .tools(let one) = rows[3] else { Issue.record("no tool group"); return }
        #expect(SessionView.summary(run) == "2 Befehle ausgeführt, eine Datei erstellt")
        #expect(SessionView.diff(run)?.add == 62 && SessionView.diff(run)?.del == 0)
        #expect(SessionView.summary(one) == "Ausgeführt Delete probe")
        #expect(SessionView.diff(one) == nil)
        #expect(SessionView.endsTurn(rows, at: 2))
        #expect(!SessionView.endsTurn(rows, at: 0))
    }

    @Test func markdownBlocks() {
        let b = Markdown.blocks("Hallo **Sir**\nweiter.\n\n## Titel\n- eins\n  - zwei\n1. erstens\n> Zitat\n\n```bash\nls -la\n```\n| a | b |\n|---|---|\n---")
        #expect(b == [.paragraph("Hallo **Sir** weiter."), .heading(2, "Titel"), .bullet("eins", level: 0), .bullet("zwei", level: 1),
                      .numbered("1.", "erstens"), .quote("Zitat"), .code(lang: "bash", code: "ls -la"), .table("| a | b |\n|---|---|"), .rule])
        #expect(Markdown.blocks("```\nunclosed") == [.code(lang: "", code: "unclosed")])
        #expect(Markdown.plain("**Fett** und `code`") == "Fett und code")
    }

    @Test func historyPagesMerge() {
        func items(_ ids: String...) -> [ChatItem] { ids.map { ChatItem(id: $0) } }
        let loaded = items("a", "b", "c", "d")
        #expect(AppModel.merge(loaded, page: items("x", "y"), before: "a").map(\.id) == ["x", "y", "a", "b", "c", "d"])   // older in front
        #expect(AppModel.merge(loaded, page: items("x"), before: "b").map(\.id) == ["a", "b", "c", "d"])                  // stale page
        #expect(AppModel.merge(loaded, page: items("c", "d", "e"), before: nil).map(\.id) == ["a", "b", "c", "d", "e"])   // newest: tail replaced
        #expect(AppModel.merge(loaded, page: items("q", "r"), before: nil).map(\.id) == ["q", "r"])                       // no overlap
    }

    @Test func captionFrameAndSubtitleLines() throws {
        let f = Frame.decode(#"{"t":"caption","words":["Hallo","Sir.","Alles","fertig."],"at":[0.1,0.5,1.2,1.5],"end":2.0}"#)
        guard case .caption(let c) = f else { Issue.record("no caption"); return }
        #expect(c.index(at: 0) == -1 && c.index(at: 0.6) == 1 && c.index(at: 9) == 3)
        #expect(c.chunks == [0..<2, 2..<4])
        #expect(Frame.decode(#"{"t":"caption","words":["a"],"at":[],"end":1}"#) == .other("caption"))
        let long = Caption(words: (1...15).map { "w\($0)" }, starts: (0..<15).map(Double.init), end: 15)
        #expect(long.chunks == [0..<12, 12..<15])
        #expect(Demo.caption.words.count == Demo.caption.starts.count)
    }
}

