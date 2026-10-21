import SwiftUI

// The menu bar's window, laid out like the iPhone app's overview (docs/design/screens/ios/01-uebersicht):
// title and status pills, today's numbers, the sessions with their one action, "Anrufen" — and below
// it what only the Mac has: snapshots, shares, options, developer tools.
struct MenuBarView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var guests = GuestHub.shared
    var demo: MenuBoard?
    @State private var board = MenuBoard()
    @State private var options = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let today = board.today { TodayCard(today: today) }
            sessions
            if !controller.snapshots.isEmpty || !controller.shared.isEmpty { extras }
            if let note = guests.notice {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let err = controller.lastError {
                Text(err).font(.caption2).foregroundStyle(MenuTheme.red).lineLimit(2)
            }
            optionsSection
            footer
        }
        .padding(16)
        .frame(width: 380)
        .background(MenuTheme.background)
        .task {
            if let demo { board = demo; return }
            controller.refreshResumable()
            while !Task.isCancelled {
                board = MenuBoard(json: controller.server.sessionsJSON())
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text("Parley").font(.system(size: 28, weight: .bold))
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape").font(.system(size: 15, weight: .medium))
                        .foregroundStyle(MenuTheme.accent)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(MenuTheme.card))
                }
                .buttonStyle(.plain)
                .help("Einstellungen")
            }
            HStack(spacing: 8) {
                connection
                Spacer(minLength: 0)
                if controller.phoneAway {
                    Pill(title: "Unterwegs", symbol: "car.fill", on: true) {}
                        .help("Unterwegs-Modus — am iPhone umschalten")
                        .allowsHitTesting(false)
                }
                Pill(title: "Stumm", symbol: controller.muted ? "bell.slash.fill" : "bell.slash", on: controller.muted) {
                    controller.muted.toggle()
                }
            }
        }
    }

    private var connection: some View {
        let (text, color): (String, Color) = controller.phoneCall ? ("Im Anruf", MenuTheme.idle)
            : controller.relayConnected == true ? ("Verbunden", MenuTheme.idle)
            : controller.relayConnected == false ? ("Offline", MenuTheme.stopped) : ("Kein iPhone", MenuTheme.stopped)
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.callout.weight(.medium))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.16)))
    }

    // MARK: - sessions

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sessions").font(.title3.weight(.semibold))
                Text("\(board.sessions.count + guests.shares.count)").font(.title3).foregroundStyle(.secondary)
                Spacer()
                Button("Anrufen") { controller.callFromMac() }
                    .buttonStyle(AccentButton())
                    .disabled(controller.phoneAway)
                    .help(controller.phoneAway ? "Unterwegs: Parley spricht nur übers iPhone" : "Mit Parley sprechen — Mikrofon des Macs")
            }
            if board.sessions.isEmpty && guests.shares.isEmpty {
                Text("Keine Session. Starte /parley:voice in Claude Code.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(MenuTheme.card))
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(board.sessions.enumerated()), id: \.element.id) { i, s in
                            if i > 0 { Divider().padding(.leading, 52) }
                            SessionRow(session: s, resume: { controller.resume(s.id) })
                        }
                        ForEach(Array(guests.shares.enumerated()), id: \.element.id) { i, g in
                            if i > 0 || !board.sessions.isEmpty { Divider().padding(.leading, 52) }
                            GuestRow(share: g, row: guests.rows[g.id], hub: guests)
                        }
                    }
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(MenuTheme.card))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    // MARK: - snapshots and shares

    private var extras: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !controller.snapshots.isEmpty {
                Label("Snapshots", systemImage: "square.on.square").font(.caption).foregroundStyle(.secondary)
                ForEach(controller.snapshots, id: \.id) { s in
                    HStack {
                        Text(s.name).font(.callout)
                        Text("\(s.sessions.count)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Öffnen") { controller.openSnapshot(s.id) }.controlSize(.small)
                    }
                }
            }
            if !controller.shared.isEmpty {
                Label("Geteilt", systemImage: "person.2").font(.caption).foregroundStyle(.secondary)
                ForEach(controller.shared, id: \.id) { s in
                    HStack {
                        Text("\(s.guest?.name ?? "Gast") · \(s.label)").font(.callout)
                        if s.state == "asking" { Text("fragt an").font(.caption).foregroundStyle(MenuTheme.waiting) }
                        Spacer()
                        Button("Entfernen") { controller.shares.remove(s.id); controller.refreshResumable() }.controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - options and footer

    private var optionsSection: some View {
        DisclosureGroup(isExpanded: $options) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Unterwegs, wenn der Mac gesperrt ist", isOn: $controller.autoAwayOnLock)
                Toggle("Unterbrechen (einfach reinreden)", isOn: $controller.bargeIn)
                Toggle("Ohne Floskeln (keine Ansagen, keine Bestätigung)", isOn: $controller.brief)
                if !controller.muted && FocusStatus.doNotDisturbActive() {
                    Text("Nicht stören aktiv — Parley schweigt automatisch").font(.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Push-Schlüssel wählen…") { controller.choosePushKey() }
                    if let key = controller.pushKeyId { Text(key).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .toggleStyle(.switch).controlSize(.small)
            .padding(.top, 6)
        } label: {
            Text("Optionen").font(.callout.weight(.medium))
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            FooterButton(title: "iPhone", symbol: "iphone") { controller.pairIPhone() }
            FooterButton(title: "Statistik", symbol: "chart.bar") { StatsPresenter.shared.show() }
            FooterButton(title: "Beitreten", symbol: "person.badge.plus") { guests.askToJoin() }
                .help("Einer geteilten Session beitreten (Einladungslink)")
            FooterButton(title: "Setup", symbol: "wand.and.stars") { OnboardingPresenter.shared.show() }
            Menu {
                Button("Zurücksetzen (Onboarding testen) — Statistiken bleiben") { DevTools.resetKeepingStats() }
                Button("Onboarding zeigen") { DevTools.showOnboarding() }
                Divider()
                Button("Test-Benachrichtigung") { DevTools.testNotification() }
                Button("Aufnahme-Pill testen") { DevTools.testRecordingPill() }
                Button("Clips neu rendern") { DevTools.rerenderClips() }
                Button("Log anzeigen") { DevTools.revealLog() }
            } label: {
                Image(systemName: "hammer")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Entwickler")
            Spacer()
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Parley beenden")
        }
        .font(.callout)
    }
}

// MARK: - the board (GET /sessions, the phone's overview data)

struct MenuBoard {
    struct Row: Decodable, Identifiable {
        struct Task: Decodable { var type: String? }
        struct Tag: Decodable { var name: String }
        struct Stats: Decodable { var lastLine: String? }
        var id: String
        var label: String
        var project: String
        var state: String
        var since: Double
        var until: Double?
        var callback: Double?
        var resumable: Bool?
        var tasks: [Task]?
        var shared: [Tag]?
        var asking: String?
        var stats: Stats?
        var name: String { label.isEmpty ? project : label }
    }
    struct Today: Decodable {
        struct Limit: Decodable { var kind: String?; var percentUsed: Double? }
        var costUsd: Double
        var turns: Int
        var spokenSeconds: Int
        var rateLimits: [Limit]
    }
    private struct Wire: Decodable { var sessions: [Row]; var today: Today? }

    var sessions: [Row] = []
    var today: Today?

    init() {}
    init(sessions: [Row], today: Today?) { self.sessions = sessions; self.today = today }
    init(json: String) {
        guard let w = try? JSONDecoder().decode(Wire.self, from: Data(json.utf8)) else { return }
        sessions = w.sessions
        today = w.today
    }
}

// `Parley --render-menu out.png [dark]`: the window with sample sessions, as a PNG (screenshots).
@MainActor
enum MenuSnapshot {
    static func render(to path: String, dark: Bool) {
        let now = Date().timeIntervalSince1970 * 1000
        func row(_ id: String, _ state: String, ago: Double, line: String? = nil, resumable: Bool = false,
                 callback: Double? = nil, until: Double? = nil, tasks: Int = 0, shared: [String] = []) -> MenuBoard.Row {
            MenuBoard.Row(id: id, label: id, project: id, state: state, since: now - ago * 1000, until: until, callback: callback,
                          resumable: resumable, tasks: Array(repeating: .init(type: "subagent"), count: tasks),
                          shared: shared.map { .init(name: $0) }, asking: nil, stats: .init(lastLine: line))
        }
        let board = MenuBoard(sessions: [
            row("Parley", "speaking", ago: 13),
            row("Shirts", "working", ago: 138, line: "Ich baue jetzt die Mockups für die neue Kollektion."),
            row("Angebote", "waiting", ago: 30, line: "Ich warte fünf Minuten auf den Build und melde mich.", resumable: true, until: now + 247_000),
            row("SEO-Landing", "background", ago: 207, line: "Ein Agent prüft das Protokoll, ich melde mich.", tasks: 1, shared: ["Marco"]),
            row("Edge Army", "parked", ago: 615, line: "Zwei neue Kandidaten gefunden. Weiter?", resumable: true),
            row("Website", "parked", ago: 21, callback: 0),
        ], today: .init(costUsd: 13.61, turns: 65, spokenSeconds: 780,
                        rateLimits: [.init(kind: "five_hour", percentUsed: 42), .init(kind: "seven_day", percentUsed: 18)]))
        let app = NSApplication.shared
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: MenuBarView(controller: AppController.shared, demo: board))
        host.appearance = app.appearance
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - pieces

enum MenuTheme {
    // The Claude palette (ios/ParleyMobile/Theme.swift).
    static let background = dynamic(0xFAF9F5, 0x191918)
    static let card = dynamic(0xFFFFFF, 0x262624)
    static let raised = dynamic(0xF0EEE6, 0x30302E)
    static let accent = hex(0xD97757)
    static let waiting = hex(0xD9A43B)
    static let working = hex(0x5B8DEF)
    static let purple = hex(0x9B87F5)
    static let idle = hex(0x4EBA65)
    static let stopped = hex(0x8B8A85)
    static let red = hex(0xE5484D)

    static func state(_ s: String) -> Color {
        switch s {
        case "speaking", "listening", "transcribing": accent
        case "queued", "waiting": waiting
        case "working": working
        case "background": purple
        case "idle": idle
        default: stopped
        }
    }

    private static func ns(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    private static func hex(_ v: Int) -> Color { Color(nsColor: ns(v)) }
    private static func dynamic(_ light: Int, _ dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light) })
    }
}

private struct TodayCard: View {
    let today: MenuBoard.Today

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                fact(String(format: "$%.2f", today.costUsd), "Kosten heute")
                Spacer()
                fact("\(today.turns)", "Updates")
                Spacer()
                fact("\(Int((Double(today.spokenSeconds) / 60).rounded())) min", "gesprochen", trailing: true)
            }
            ForEach(Array(limits.enumerated()), id: \.offset) { _, l in
                HStack(spacing: 10) {
                    Text(l.name).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(MenuTheme.raised)
                            Capsule().fill(MenuTheme.accent).frame(width: g.size.width * min(1, max(0, l.percent / 100)))
                        }
                    }
                    .frame(height: 6)
                    Text("\(Int(l.percent.rounded())) %").font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(MenuTheme.card))
    }

    private var limits: [(name: String, percent: Double)] {
        let names = ["five_hour": "5-h-Limit", "seven_day": "Woche"]
        return today.rateLimits.compactMap { r in
            guard let n = r.kind.flatMap({ names[$0] }), let p = r.percentUsed else { return nil }
            return (n, p)
        }
    }

    private func fact(_ value: String, _ label: String, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .bold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SessionRow: View {
    let session: MenuBoard.Row
    let resume: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let at = context.date.timeIntervalSince1970 * 1000
            HStack(alignment: .top, spacing: 12) {
                StateRing(state: session.state, background: !(session.tasks ?? []).isEmpty)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(session.name).font(.headline).lineLimit(1)
                            .foregroundStyle(session.state == "stopped" ? .secondary : .primary)
                        Text(stateText(at: at)).font(.callout).lineLimit(1)
                            .foregroundStyle(session.callback != nil ? MenuTheme.waiting : MenuTheme.state(session.state))
                        Spacer(minLength: 4)
                        Text(corner(at: at)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if let line = session.stats?.lastLine, !line.isEmpty, !live {
                        Text("„\(line)“").font(.callout).italic().foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let tags = session.shared, !tags.isEmpty {
                        Label(tags.map(\.name).joined(separator: ", "), systemImage: "person.2.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if session.callback == nil, session.resumable == true {
                        Button("Fortsetzen", action: resume).buttonStyle(AccentButton()).padding(.top, 2)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(live ? MenuTheme.accent.opacity(0.08) : .clear)
        }
    }

    private var live: Bool { ["speaking", "listening", "transcribing"].contains(session.state) }

    private func stateText(at: Double) -> String {
        if let cb = session.callback { return cb == 0 ? "wartet auf Rückruf" : "ruft in \(clock(max(0, cb - at))) an" }
        if let name = session.asking { return "Rückfrage an \(name)" }
        switch session.state {
        case "speaking": return "spricht"
        case "listening": return "hört zu"
        case "transcribing": return "transkribiert"
        case "queued": return "Warteschlange"
        case "working": return "arbeitet"
        case "background":
            let n = session.tasks?.count ?? 0
            return n > 1 ? "\(n) im Hintergrund" : "Agent im Hintergrund"
        case "waiting": return "pausiert"
        case "parked": return "geparkt"
        case "idle": return "bereit"
        default: return "gestoppt"
        }
    }

    private func corner(at: Double) -> String {
        if session.state == "waiting", let until = session.until { return clock(until - at) }
        if session.state == "stopped" { return "vor \(max(1, Int(((at - session.since) / 60_000).rounded()))) min" }
        return clock(at - session.since)
    }

    private func clock(_ ms: Double) -> String {
        let s = max(0, Int(ms / 1000))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Someone else's session this Mac joined: its row (once in), "Anrufen" / "Annehmen" / "Auflegen",
/// or the join's check code while Sir decides.
private struct GuestRow: View {
    let share: GuestShare
    let row: MenuBoard.Row?
    @ObservedObject var hub: GuestHub

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StateRing(state: share.active ? row?.state ?? "idle" : "queued", background: false)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row?.name ?? share.label).font(.headline).lineLimit(1)
                    Text(share.active ? "geteilt von \(share.host)" : "wartet auf \(share.host)").font(.callout)
                        .foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Menu {
                        Button("Verlassen", role: .destructive) { hub.leave(share.id) }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                if !share.active {
                    Text("Code \(share.code) — schick ihn \(share.host), damit er dich hereinlässt.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if let line = row?.stats?.lastLine, !line.isEmpty {
                    Text("„\(line)“").font(.callout).italic().foregroundStyle(.secondary).lineLimit(1)
                }
                if share.active {
                    HStack(spacing: 8) {
                        if hub.inCall == share.id {
                            Button("Auflegen") { hub.endCall() }.buttonStyle(AccentButton(color: MenuTheme.red))
                        } else if hub.ringing[share.id] != nil {
                            Button("Annehmen") { hub.call(share.id) }.buttonStyle(AccentButton(color: MenuTheme.idle))
                            Button("Ablehnen") { hub.decline(share.id) }.buttonStyle(.plain).foregroundStyle(.secondary)
                        } else {
                            Button("Anrufen") { hub.call(share.id) }.buttonStyle(AccentButton())
                                .disabled(hub.inCall != nil || share.listen)
                                .help(share.listen ? "Nur zuhören — hier kannst du nichts sagen" : "Mit Parley über diese Session sprechen")
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

/// The app's state ring, simplified: a pulse while live, a spinning arc while working or queued,
/// an orbiting dot in the background, a plain ring otherwise.
private struct StateRing: View {
    let state: String
    let background: Bool

    var body: some View {
        let color = MenuTheme.state(state)
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle().stroke(color.opacity(0.2), lineWidth: 2.5)
                switch state {
                case "speaking", "listening", "transcribing":
                    Circle().stroke(color, lineWidth: 2.5)
                    let r = 5 + 2.5 * (0.5 - 0.5 * cos(2 * .pi * t / 1.4))
                    Circle().fill(color).frame(width: 2 * r, height: 2 * r)
                case "working", "queued":
                    Circle().trim(from: 0, to: 0.3).stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(360 * (t / (state == "working" ? 1.2 : 3)).truncatingRemainder(dividingBy: 1)))
                case "background":
                    Circle().fill(color).frame(width: 6, height: 6)
                        .offset(y: -12).rotationEffect(.degrees(360 * (t / 2.4).truncatingRemainder(dividingBy: 1)))
                    Circle().fill(color).frame(width: 6, height: 6)
                case "parked", "stopped":
                    HStack(spacing: 3) { Capsule().frame(width: 3, height: 9); Capsule().frame(width: 3, height: 9) }
                        .foregroundStyle(color)
                default:
                    Circle().stroke(color, lineWidth: 2.5)
                }
            }
            .frame(width: 24, height: 24)
        }
        .frame(width: 28, height: 28)
        .opacity(state == "stopped" ? 0.7 : 1)
    }
}

private struct Pill: View {
    let title: String
    let symbol: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.callout.weight(.medium)).fixedSize()
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(on ? .white : .primary)
                .background(Capsule().fill(on ? MenuTheme.accent : MenuTheme.card))
        }
        .buttonStyle(.plain)
    }
}

private struct AccentButton: ButtonStyle {
    var color = MenuTheme.accent
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(Capsule().fill(color.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)))
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Label(title, systemImage: symbol).fixedSize() }
            .buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(MenuTheme.card))
    }
}
