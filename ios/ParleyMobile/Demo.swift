import Foundation
import SwiftUI

/// `-demo`: a built-in `sessions` frame (every state, a countdown, a background agent) for
/// screenshots and UI work without a relay. It goes through the real decoder.
enum Demo {

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
            #"{"id":"demo-website","label":"Website","project":"developaway","state":"queued","since":\#(ago(17)),"until":null,"callback":0,"voice":false,"resumable":false,"tasks":[],"host":null,"stats":\#(stats(12, 9, 0.31, 2, 1, nil))}"#,
            #"{"id":"demo-notizen","label":"Notizen","project":"notes","state":"idle","since":\#(ago(1260)),"until":null,"voice":false,"resumable":true,"tasks":[],"host":null,"stats":\#(stats(140, 33, 0.58, 5, 3, "Alles notiert."))}"#,
            #"{"id":"demo-doku","label":"Doku","project":"docs","state":"stopped","since":\#(ago(180)),"until":null,"voice":false,"resumable":false,"tasks":[],"host":null,"stats":\#(stats(61, 48, 0.94, 6, 2, "Fertig, die Doku ist aktualisiert."))}"#,
        ]
        let today = #"{"costUsd":13.61,"turns":65,"spokenSeconds":754,"rateLimits":[{"kind":"five_hour","percentUsed":42,"resetsAt":null},{"kind":"seven_day","percentUsed":18,"resetsAt":null}]}"#
        let reminders = #"[{"id":"r1","text":"Lass die Tests laufen und berichte, was rot ist.","to":"Shirts","at":\#(t + 14 * 3_600_000)},{"id":"r2","text":"Deploye auf Staging.","to":"Zentrale","after":"Shirts"}]"#
        return #"{"t":"sessions","at":\#(t),"sessions":[\#(sessions.joined(separator: ","))],"today":\#(today),"reminders":\#(reminders)}"#
    }
}

extension Demo {
    /// The session view's sample history (every kind of entry).
    static let history: [ChatItem] = [
        ChatItem(id: "d1", kind: .user, text: "Bau bitte den Export-Button in die Rechnungsliste ein."),
        ChatItem(id: "d2", kind: .tool, text: "Bash · Find the invoice list"),
        ChatItem(id: "d3", kind: .tool, text: "Bash · Read the export helpers"),
        ChatItem(id: "d4", kind: .assistant, text: "Die Liste rendert `InvoiceList`, der Export fehlt noch. Ich baue ihn als eigene Datei, damit die Liste schlank bleibt."),
        ChatItem(id: "d5", kind: .tool, text: "Write · CSVExport.swift", add: 62, del: 0),
        ChatItem(id: "d6", kind: .tool, text: "Bash · Run the invoice tests"),
        ChatItem(id: "d7", kind: .assistant, text: "Der Button ist drin und exportiert als **CSV**.\n\n**Gebaut:**\n\n- Export-Knopf oben rechts, Branch `feature/export`\n- Spalten wie in der Ansicht, Beträge mit Komma\n\nAusprobieren:\n\n```bash\nswift test --filter CSVExportTests\n```"),
        ChatItem(id: "d8", kind: .image, fromUser: false),
        ChatItem(id: "d9", kind: .speak, text: "Der Export ist eingebaut, Sir. Soll ich auch PDF anbieten?"),
        ChatItem(id: "d10", kind: .voice, text: "Ja, mach PDF auch noch."),
        ChatItem(id: "d11", kind: .tool, text: "Edit · CSVExport.swift", add: 14, del: 2),
        ChatItem(id: "d12", kind: .assistant, text: "PDF kommt dazu, über `PDFKit`, ohne neue Abhängigkeit."),
    ]
}

extension Demo {
    /// The showcase line from 2026-10-17 (real numbers of the day), with plausible word times.
    static let caption = Caption(words: ["Gern,", "Sir,", "der", "Tagesbericht", "als", "Folien.", "Zuerst,", "was", "heute", "dazugekommen", "ist.", "Gut", "neuntausend", "neue", "Zeilen,", "das", "meiste", "auf", "dem", "iPhone.", "Siebenunddreißig", "Commits,", "davon", "sechzehn", "Features.", "So", "oft", "haben", "wir", "heute", "gesprochen.", "Alle", "Tests", "sind", "grün.", "Und", "zum", "Schluss", "ein", "Blick", "auf", "den", "Anrufbildschirm.", "Gefällt", "Ihnen", "das?"],
                                 starts: [0.25, 1.04, 1.77, 2.09, 2.95, 3.27, 4.18, 5.09, 5.41, 5.85, 6.71, 7.44, 7.76, 8.56, 8.94, 9.85, 10.17, 10.67, 10.99, 11.31, 12.22, 13.32, 14.29, 14.73, 15.35, 16.38, 16.64, 16.96, 17.4, 17.72, 18.16, 19.31, 19.69, 20.13, 20.51, 21.3, 21.62, 21.94, 22.5, 22.82, 23.26, 23.58, 23.9, 25.35, 25.91, 26.35], end: 27.08)
    static let slides: [Slide] = [
        Slide(id: "demo-0", at: 4.18, kind: "text", title: "Heute gebaut", text: "**Session-Ansicht** wie in Claude, **Untertitel** und **Folien** im Anruf, **Stumm-Modus**, **Antwort-Vorhersagen**, frühere Sessions **fortsetzen**."),
        Slide(id: "demo-1", at: 7.44, kind: "chart", title: "Neue Zeilen nach Bereich", chart: "pie", labels: ["iPhone", "Mac", "Windows", "Plugin", "Relay"], values: [3515.0, 2858.0, 2732.0, 178.0, 32.0]),
        Slide(id: "demo-2", at: 12.22, kind: "chart", title: "37 Commits heute", chart: "bar", labels: ["Feature", "Fix", "Build", "Doku"], values: [16.0, 11.0, 9.0, 1.0]),
        Slide(id: "demo-3", at: 16.38, kind: "chart", title: "Sprachrunden pro Stunde", chart: "line", labels: ["11 Uhr", "12 Uhr", "13 Uhr", "14 Uhr", "15 Uhr", "16 Uhr"], values: [9.0, 24.0, 21.0, 12.0, 12.0, 6.0]),
        Slide(id: "demo-4", at: 19.31, kind: "metric", title: "Tests Mac und iPhone", metric: "234", note: "Tests grün, keine Fehler"),
        Slide(id: "demo-5", at: 21.3, kind: "image", title: "So sieht ein Anruf jetzt aus"),
    ]

    /// Stand-in for the session's last screenshot (the image slide) in the demo.
    @MainActor static func screenshot() -> UIImage? {
        let view = VStack(spacing: 14) {
            Circle().stroke(Theme.claude, lineWidth: 10).frame(width: 90, height: 90)
                .overlay(Circle().fill(Theme.claude).frame(width: 46, height: 46))
            Text("Parley").font(.system(size: 34, weight: .bold)).foregroundStyle(.white)
            Text("spricht · 2:48").font(.headline).foregroundStyle(Theme.claude)
        }
        .frame(width: 390, height: 300)
        .background(LinearGradient(colors: [Color(hex: 0x3A2A24), Color(hex: 0x1C1C1B)], startPoint: .top, endPoint: .bottom))
        return ImageRenderer(content: view).uiImage
    }
}
