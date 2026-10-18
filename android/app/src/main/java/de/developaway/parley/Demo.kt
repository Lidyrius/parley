package de.developaway.parley

/**
 * `adb shell am start -n de.developaway.parley.android/de.developaway.parley.MainActivity --es demo overview`
 * (or `speaking`, `listening`, `idle`, `incoming`, `connecting`, `session`): sample data for
 * screenshots and UI work without a relay, as the iPhone's `-demo` (ios/ParleyMobile/Demo.swift).
 * It goes through the real decoder.
 */
object Demo {
    fun frame(now: Long): String {
        fun ago(s: Long) = now - s * 1000
        fun stats(startedMin: Long, ctx: Int, cost: Double, turns: Int, replies: Int, line: String?) =
            """{"startedAt":${ago(startedMin * 60)},"contextPercent":$ctx,"costUsd":$cost,"turns":$turns,"replies":$replies,"lastLine":${line?.let { "\"$it\"" } ?: "null"}}"""
        val sessions = listOf(
            """{"id":"demo-parley","label":"Parley","project":"vloude","state":"speaking","since":${ago(9)},"voice":true,"resumable":false,"tasks":[],"stats":${stats(74, 41, 3.12, 14, 6, "Die Tests laufen wieder grün. Soll ich den Release vorbereiten?")}}""",
            """{"id":"demo-shirts","label":"Shirts","project":"ds-shirts","state":"working","since":${ago(134)},"voice":false,"resumable":false,"tasks":[],"stats":${stats(38, 22, 1.47, 7, 3, "Ich baue jetzt die Mockups für die neue Kollektion.")}}""",
            """{"id":"demo-angebote","label":"Angebote","project":"angebotserstellung","state":"waiting","since":${ago(48)},"until":${now + 252_000},"voice":false,"resumable":true,"tasks":[],"stats":${stats(21, 18, 0.86, 4, 2, "Ich warte fünf Minuten auf den Build und melde mich dann.")}}""",
            """{"id":"demo-relay","label":"Relay","project":"parley-relay","state":"background","since":${ago(203)},"voice":false,"resumable":false,"tasks":[{"type":"subagent","description":"Durable Object gegen das Protokoll testen"}],"stats":${stats(52, 57, 2.31, 9, 4, "Ein Agent prüft das Protokoll, ich melde mich, sobald er fertig ist.")}}""",
            """{"id":"demo-edge","label":"Edge Army","project":"pmr","state":"parked","since":${ago(611)},"voice":false,"resumable":true,"tasks":[],"stats":${stats(95, 64, 4.02, 18, 7, "Zwei neue Kandidaten gefunden. Weitermachen?")}}""",
            """{"id":"demo-website","label":"Website","project":"developaway","state":"queued","since":${ago(17)},"callback":0,"voice":false,"resumable":false,"tasks":[],"stats":${stats(12, 9, 0.31, 2, 1, null)}}""",
            """{"id":"demo-notizen","label":"Notizen","project":"notes","state":"idle","since":${ago(1260)},"voice":false,"resumable":true,"tasks":[],"stats":${stats(140, 33, 0.58, 5, 3, "Alles notiert.")}}""",
            """{"id":"demo-doku","label":"Doku","project":"docs","state":"stopped","since":${ago(180)},"voice":false,"resumable":false,"tasks":[],"stats":${stats(61, 48, 0.94, 6, 2, "Fertig, die Doku ist aktualisiert.")}}""",
        )
        val today = """{"costUsd":13.61,"turns":65,"spokenSeconds":754,"rateLimits":[{"kind":"five_hour","percentUsed":42},{"kind":"seven_day","percentUsed":18}]}"""
        val reminders = """[{"id":"r1","text":"Lass die Tests laufen und berichte, was rot ist.","to":"Shirts","at":${now + 14 * 3_600_000}},{"id":"r2","text":"Deploye auf Staging.","to":"Zentrale","after":"Shirts"}]"""
        return """{"t":"sessions","at":$now,"sessions":[${sessions.joinToString(",")}],"today":$today,"reminders":$reminders}"""
    }

    val history = listOf(
        ChatItem("d1", "user", "Bau bitte den Export-Button in die Rechnungsliste ein.", fromUser = true),
        ChatItem("d2", "tool", "Bash · Find the invoice list"),
        ChatItem("d3", "tool", "Bash · Read the export helpers"),
        ChatItem("d4", "assistant", "Die Liste rendert `InvoiceList`, der Export fehlt noch. Ich baue ihn als eigene Datei, damit die Liste schlank bleibt."),
        ChatItem("d5", "tool", "Write · CSVExport.swift", add = 62, del = 0),
        ChatItem("d6", "tool", "Bash · Run the invoice tests"),
        ChatItem("d7", "assistant", "Der Button ist drin und exportiert als **CSV**.\n\n**Gebaut:**\n\n- Export-Knopf oben rechts, Branch `feature/export`\n- Spalten wie in der Ansicht, Beträge mit Komma\n\nAusprobieren:\n\n```bash\nswift test --filter CSVExportTests\n```"),
        ChatItem("d9", "speak", "Der Export ist eingebaut, Sir. Soll ich auch PDF anbieten?"),
        ChatItem("d10", "voice", "Ja, mach PDF auch noch.", fromUser = true),
        ChatItem("d11", "tool", "Edit · CSVExport.swift", add = 14, del = 2),
        ChatItem("d12", "assistant", "PDF kommt dazu, über `PDFKit`, ohne neue Abhängigkeit."),
    )

    val caption = Caption(
        "Gern, Sir, der Tagesbericht als Folien. Zuerst, was heute dazugekommen ist. Gut neuntausend neue Zeilen, das meiste auf dem iPhone.".split(" "),
        listOf(0.25, 1.04, 1.77, 2.09, 2.95, 3.27, 4.18, 5.09, 5.41, 5.85, 6.71, 7.44, 7.76, 8.56, 8.94, 9.85, 10.17, 10.67, 10.99, 11.31),
        12.0,
    )
}
