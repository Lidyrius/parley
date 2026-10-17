import Foundation

/// `-demo`: a built-in `sessions` frame (every state, a countdown, a background agent) for
/// screenshots and UI work without a relay. It goes through the real decoder.
enum Demo {
    static let expanded: Set<String> = ["demo-relay"]

    /// `-demoCall <state>`: the call screen without a call, for screenshots.
    enum CallState: String, CaseIterable, Sendable {
        case speaking, listening, idle, incoming, connecting
    }

    /// A speech-like level (syllables in phrases) for the demo waveform.
    static func level(_ state: HostAudio, at date: Date) -> Float {
        let t = date.timeIntervalSinceReferenceDate
        switch state {
        case .speaking:
            let syllables = 0.5 + 0.5 * sin(t * 9.1) * sin(t * 3.7 + 1)
            let phrase = 0.65 + 0.35 * sin(t * 0.9)
            return Float(0.35 + 0.6 * syllables * phrase)
        case .listening:
            return Float(0.25 + 0.3 * (0.5 + 0.5 * sin(t * 6.3) * sin(t * 2.2)))
        case .idle:
            return 0.04
        }
    }

    static func frame(now: Date) -> String {
        let t = Int64(now.ms)
        func ago(_ s: Int64) -> Int64 { t - s * 1000 }
        func stats(_ startedMin: Int64, _ ctx: Int, _ cost: Double, _ turns: Int, _ replies: Int, _ line: String?) -> String {
            let last = line.map { "\"\($0)\"" } ?? "null"
            return #"{"startedAt":\#(ago(startedMin * 60)),"contextPercent":\#(ctx),"costUsd":\#(cost),"turns":\#(turns),"replies":\#(replies),"lastLine":\#(last)}"#
        }
        let sessions = [
            #"{"id":"demo-parley","label":"Parley","project":"vloude","state":"speaking","since":\#(ago(9)),"until":null,"voice":true,"resumable":false,"tasks":[],"host":null,"stats":\#(stats(74, 41, 3.12, 14, 6, "Die Tests laufen wieder grün. Soll ich den Release vorbereiten?"))}"#,
            #"{"id":"demo-shirts","label":"Shirts","project":"ds-shirts","state":"working","since":\#(ago(134)),"until":null,"voice":false,"resumable":false,"tasks":[],"host":null,"stats":\#(stats(38, 22, 1.47, 7, 3, "Ich baue jetzt die Mockups für die neue Kollektion."))}"#,
            #"{"id":"demo-angebote","label":"Angebote","project":"angebotserstellung","state":"waiting","since":\#(ago(48)),"until":\#(t + 252_000),"voice":false,"resumable":true,"tasks":[],"host":null,"stats":\#(stats(21, 18, 0.86, 4, 2, "Ich warte fünf Minuten auf den Build und melde mich dann."))}"#,
            #"{"id":"demo-relay","label":"Relay","project":"parley-relay","state":"background","since":\#(ago(203)),"until":null,"voice":false,"resumable":false,"tasks":[{"type":"subagent","description":"Durable Object gegen das Protokoll testen"}],"host":null,"stats":\#(stats(52, 57, 2.31, 9, 4, "Ein Agent prüft das Protokoll, ich melde mich, sobald er fertig ist."))}"#,
            #"{"id":"demo-edge","label":"Edge Army","project":"pmr","state":"parked","since":\#(ago(611)),"until":null,"voice":false,"resumable":true,"tasks":[],"host":null,"stats":\#(stats(95, 64, 4.02, 18, 7, "Zwei neue Kandidaten gefunden. Weitermachen?"))}"#,
            #"{"id":"demo-website","label":"Website","project":"developaway","state":"queued","since":\#(ago(17)),"until":null,"voice":false,"resumable":false,"tasks":[],"host":null,"stats":\#(stats(12, 9, 0.31, 2, 1, nil))}"#,
            #"{"id":"demo-notizen","label":"Notizen","project":"notes","state":"idle","since":\#(ago(1260)),"until":null,"voice":false,"resumable":true,"tasks":[],"host":null,"stats":\#(stats(140, 33, 0.58, 5, 3, "Alles notiert."))}"#,
            #"{"id":"demo-doku","label":"Doku","project":"docs","state":"stopped","since":\#(ago(180)),"until":null,"voice":false,"resumable":false,"tasks":[],"host":null,"stats":\#(stats(61, 48, 0.94, 6, 2, "Fertig, die Doku ist aktualisiert."))}"#,
        ]
        let today = #"{"costUsd":13.61,"turns":65,"spokenSeconds":754,"rateLimits":[{"kind":"five_hour","percentUsed":42,"resetsAt":null},{"kind":"seven_day","percentUsed":18,"resetsAt":null}]}"#
        return #"{"t":"sessions","at":\#(t),"sessions":[\#(sessions.joined(separator: ","))],"today":\#(today)}"#
    }
}

extension Demo {
    /// The session view's sample history (every kind of entry).
    static let history: [ChatItem] = [
        ChatItem(id: "d1", kind: .user, text: "Bau bitte den Export-Button in die Rechnungsliste ein."),
        ChatItem(id: "d2", kind: .tool, text: "Read · InvoiceList.swift"),
        ChatItem(id: "d3", kind: .tool, text: "Edit · InvoiceList.swift"),
        ChatItem(id: "d4", kind: .tool, text: "Bash · Run the invoice tests"),
        ChatItem(id: "d5", kind: .assistant, text: "Der Button ist drin und exportiert als **CSV**. Alle 24 Tests sind grün."),
        ChatItem(id: "d6", kind: .image, fromUser: false),
        ChatItem(id: "d7", kind: .speak, text: "Der Export ist eingebaut, Sir. Soll ich auch PDF anbieten?"),
        ChatItem(id: "d8", kind: .voice, text: "Ja, mach PDF auch noch."),
    ]
}
