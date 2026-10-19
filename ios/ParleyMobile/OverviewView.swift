import SwiftUI

/// The main screen (design C2, docs/design/screens/ios/01-uebersicht): status and switches in one
/// row, today's figures as one card, the sessions as a grid or a list — a tap opens a sheet.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showsSettings = false
    @State private var showsSnapshots = false
    /// The session whose sheet is open.
    @State private var detail: Session?
    /// Raster (default) or Liste, remembered.
    @AppStorage("sessionsAsList") private var asList = false

    var body: some View {
        @Bindable var model = model
        let relay = model.relay
        NavigationStack(path: $model.path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    StatusHeader(relay: relay, away: $model.away, silent: $model.silent)
                    if let failure = model.call.failure {
                        CallFailureBanner(text: failure) { model.call.failure = nil }
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if model.call.isBusy {
                        CallParleyButton(call: model.call, canCall: relay.canSend, action: model.callParley)
                    }
                    if model.pairing != nil || model.demo || model.guests.isEmpty { content(relay) }
                    GuestSection { model.open(session: $0) }
                }
                .animation(.snappy, value: model.call.failure)
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
                // Exactly the screen's width: a row that grows too wide (both switches, large
                // text) can't make the page pan sideways — it only scrolls down.
                .containerRelativeFrame(.horizontal, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .background(Theme.background)
            .navigationTitle("Parley")
            .toolbar {
                // Snapshots (docs/design/screens/ios/50-snapshots): a labelled pill beside the gear.
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsSnapshots = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.on.square")
                            Text("Snapshots")
                        }
                        .font(.subheadline.weight(.semibold))
                        .fixedSize()
                    }
                    .disabled(!model.isPaired)
                }
                if #available(iOS 26, *) { ToolbarSpacer(.fixed, placement: .topBarTrailing) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Einstellungen")
                }
            }
            .refreshable {
                relay.reconnect()
                try? await Task.sleep(for: .milliseconds(600))
            }
            .sheet(isPresented: $showsSettings) { SettingsView() }
            .sheet(isPresented: $showsSnapshots) { SnapshotsSheet() }
            .sheet(item: Binding(get: { model.joinRequests.first }, set: { _ in })) { ApproveJoinView(request: $0) }
            .alert("Freigabe beendet", isPresented: Binding(get: { model.guestNotice != nil }, set: { if !$0 { model.guestNotice = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.guestNotice ?? "") }
            .sheet(item: $detail) { d in
                let live = relay.snapshot?.sessions.first { $0.id == d.id } ?? d
                SessionSheet(session: live, skew: relay.skew,
                             openHistory: { show(d.id, compose: false) },
                             message: { show(d.id, compose: true) },
                             canShare: model.guestShare(of: d.id) == nil)
            }
            .navigationDestination(for: String.self) { SessionView(id: $0) }
        }
    }

    @ViewBuilder
    private func content(_ relay: Relay) -> some View {
        switch relay.status {
        case .hostOffline:
            Notice(title: "Mac offline", symbol: "laptopcomputer",
                   text: "Parley auf dem Mac ist gerade nicht mit dem Relay verbunden. Sobald er wieder online ist, erscheinen hier deine Sessions.")
        case .unknownRoom:
            Notice(title: "Mac noch nicht verbunden", symbol: "laptopcomputer",
                   text: "Parley auf dem Mac hat sich noch nicht beim Relay gemeldet. Öffne Parley auf dem Mac – die Verbindung entsteht dann von selbst.")
        case .rejected:
            Notice(title: "Bitte neu koppeln", symbol: "lock.slash",
                   text: "Das Relay hat die Kopplung abgelehnt, oder sie stammt aus einer älteren Version. Wähle in Parley auf dem Mac „Handy verbinden…“ und koppele neu.") {
                Button("Neu koppeln") { model.unpair() }.buttonStyle(.borderedProminent)
            }
        case .unreachable:
            Notice(title: "Keine Verbindung", symbol: "wifi.exclamationmark",
                   text: "Das Relay ist gerade nicht erreichbar. Parley versucht es automatisch weiter.") {
                Button("Erneut versuchen") { relay.reconnect() }.buttonStyle(.bordered)
            }
        case .connected, .connecting:
            if let snapshot = relay.snapshot {
                if let today = snapshot.today { TodayCard(today: today) }
                sessions(snapshot.sessions, skew: relay.skew, canSend: relay.canSend)
                if !snapshot.reminders.isEmpty { RemindersCard(list: snapshot.reminders, skew: relay.skew) }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Verbinde mit dem Relay…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            }
        }
    }

    @ViewBuilder
    private func sessions(_ list: [Session], skew: Double, canSend: Bool) -> some View {
        let actions = SessionActions(open: { detail = $0 }, resume: model.resume, callBack: model.callParley, canSend: canSend)
        VStack(alignment: .leading, spacing: 12) {
            SessionsHead(count: list.filter { $0.state != .stopped }.count, asList: $asList,
                         canCall: canSend || model.demo, inCall: model.call.isBusy) {
                if model.call.isBusy { model.call.showsScreen = true } else { model.callParley() }
            }
            if list.isEmpty {
                Notice(title: "Keine Sessions", symbol: "waveform",
                       text: "Sobald eine Claude-Code- oder Codex-Session über Parley spricht, erscheint sie hier.")
            } else if asList {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                        if i > 0 { Divider().padding(.leading, 54) }
                        SessionRow(session: s, skew: skew, actions: actions)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .background(CardBackground())
            } else {
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    ForEach(rows(list)) { row in
                        GridRow(alignment: .top) {
                            ForEach(row.items) { s in SessionTile(session: s, skew: skew, actions: actions) }
                            ForEach(row.items.count..<columns, id: \.self) { _ in
                                Color.clear.gridCellUnsizedAxes(.vertical)
                            }
                        }
                    }
                }
            }
        }
        .animation(.snappy, value: asList)
    }

    /// The sheet's "Verlauf öffnen" / "Nachricht": the session view (with the keyboard for a message).
    private func show(_ id: String, compose: Bool) {
        detail = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))   // let the sheet go first
            if compose { model.compose = id }
            model.open(session: id)
        }
    }

    /// Two cards a row; one at accessibility text sizes, three on wide screens.
    private var columns: Int {
        typeSize.isAccessibilitySize ? 1 : sizeClass == .regular ? 3 : 2
    }

    private struct Row: Identifiable {
        let items: [Session]
        var id: String { items.map(\.id).joined(separator: "|") }
    }

    private func rows(_ list: [Session]) -> [Row] {
        stride(from: 0, to: list.count, by: columns).map { Row(items: Array(list[$0..<min($0 + columns, list.count)])) }
    }
}

/// "Sessions 7", the grid / list switch, and "Anrufen".
private struct SessionsHead: View {
    let count: Int
    @Binding var asList: Bool
    let canCall: Bool
    let inCall: Bool
    let call: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Sessions").font(.title3.bold())
                Text("\(count)").font(.title3).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 2) {
                choice("square.grid.2x2.fill", "Raster", on: !asList) { asList = false }
                choice("list.bullet", "Liste", on: asList) { asList = true }
            }
            .padding(3)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            Spacer(minLength: 8)
            Button(action: call) {
                Label(inCall ? "Zum Anruf" : "Anrufen", systemImage: "phone.fill")
                    .labelStyle(.titleOnly)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Theme.claude))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canCall)
            .opacity(canCall ? 1 : 0.45)
            .accessibilityLabel(inCall ? "Zum Anruf" : "Parley anrufen")
        }
    }

    private func choice(_ symbol: String, _ name: String, on: Bool, _ pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(on ? .primary : .secondary)
                .frame(width: 30, height: 24)
                .background(Capsule().fill(on ? Color(light: 0xFFFFFF, dark: 0x48484A) : .clear)
                    .shadow(color: .black.opacity(on ? 0.08 : 0), radius: 2, y: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Today's figures as one card: cost · updates · spoken, then the 5-h limit and the week as bars.
private struct TodayCard: View {
    let today: Today

    var body: some View {
        let limits = Self.limits(today)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                figure(Fmt.money(today.costUsd), "Kosten heute", .leading)
                Spacer(minLength: 8)
                figure("\(today.turns)", "Updates", .leading)
                Spacer(minLength: 8)
                figure("\(Int((today.spokenSeconds / 60).rounded())) min", "gesprochen", .trailing)
            }
            if !limits.isEmpty {
                VStack(spacing: 7) {
                    ForEach(limits, id: \.name) { l in
                        HStack(spacing: 10) {
                            Text(l.name).font(.footnote).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                            ProgressBar(fraction: l.percent / 100, color: Theme.claude)
                            Text(Fmt.percent(l.percent)).font(.footnote.weight(.medium)).monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .padding(16)
        .background(CardBackground())
    }

    private func figure(_ value: String, _ label: String, _ align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 1) {
            Text(value).font(.title2.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    /// "5-h-Limit" and "Woche", as the host reports them.
    static func limits(_ d: Today) -> [(name: String, percent: Double)] {
        let names = ["five_hour": "5-h-Limit", "seven_day": "Woche"]
        return d.rateLimits.compactMap { r in
            guard let name = r.kind.flatMap({ names[$0] }), let p = r.percentUsed else { return nil }
            return (name, p)
        }
    }
}

/// The host's Wiedervorlagen ("Shirts · morgen 09:00 · Lass die Tests laufen"), soonest first.
/// Cancelled by voice through the Zentrale ("streich die Erinnerung für Shirts").
struct RemindersCard: View {
    let list: [ReminderRow]
    let skew: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wiedervorlagen").font(.title3.bold())
            VStack(alignment: .leading, spacing: 14) {
                ForEach(list) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: r.to == "Sir" ? "bell" : r.after == nil ? "clock" : "arrow.turn.down.right")
                            .foregroundStyle(Theme.claude)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(r.to == "Sir" ? "Für dich" : r.to).font(.subheadline.weight(.semibold))
                                Spacer(minLength: 8)
                                Text(Self.when(r, skew: skew)).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Text(r.text).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
        }
    }

    /// "heute 17:00", "morgen 09:00", "Mo., 20.10. 09:00" — or "wenn Shirts fertig ist".
    static func when(_ r: ReminderRow, skew: Double) -> String {
        guard let at = r.at else { return "wenn \(r.after ?? "es") fertig ist" }
        let date = Date(timeIntervalSince1970: (at - skew) / 1000)
        let time = date.formatted(date: .omitted, time: .shortened)
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "heute \(time)" }
        if cal.isDateInTomorrow(date) { return "morgen \(time)" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.twoDigits).hour().minute())
    }
}

/// The connection pill ("Verbunden") and the Unterwegs / Stumm switches, in one row.
private struct StatusHeader: View {
    let relay: Relay
    @Binding var away: Bool
    @Binding var silent: Bool

    var body: some View {
        let status = relay.status
        // One row (with both switches ~360 of 370 pt); stacked when large text no longer fits.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                pill(status)
                Spacer(minLength: 4)
                awayToggle
                if away { silentToggle }
            }
            VStack(alignment: .leading, spacing: 8) {
                pill(status)
                HStack(spacing: 8) {
                    awayToggle
                    if away { silentToggle }
                }
            }
            // Very large text: one per row — never wider than the screen.
            VStack(alignment: .leading, spacing: 8) {
                pill(status)
                awayToggle
                if away { silentToggle }
            }
        }
    }

    private func pill(_ status: ConnectionStatus) -> some View {
        HStack(spacing: 7) {
            Circle().fill(status.color).frame(width: 8, height: 8)
            Text(status == .connected ? "Verbunden" : status.label).font(.subheadline.weight(.semibold))
        }
        .fixedSize()   // never squeezed: too narrow → the second row
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(status.color.opacity(0.14)))
        .accessibilityElement(children: .combine)
    }

    private var awayToggle: some View {
        Toggle(isOn: $away) {
            Label("Unterwegs", systemImage: "car.fill")
        }
        .toggleStyle(PillToggleStyle())
        .accessibilityHint("Updates klingeln als Anruf auf dem iPhone")
    }

    private var silentToggle: some View {
        Toggle(isOn: $silent) {
            Label("Stumm", systemImage: "bell.slash.fill")
        }
        .toggleStyle(PillToggleStyle())
        .accessibilityHint("Statt eines Anrufs kommt eine Mitteilung, du antwortest schriftlich")
    }
}

/// Empty, offline and error states.
private struct Notice<Actions: View>: View {
    let title: String
    let symbol: String
    let text: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(text)
        } actions: {
            actions()
        }
        .padding(.top, 40)
    }
}

extension Notice where Actions == EmptyView {
    init(title: String, symbol: String, text: String) {
        self.init(title: title, symbol: symbol, text: text) { EmptyView() }
    }
}

#Preview("Demo") {
    RootView().environment(AppModel(arguments: ["-demo"]))
}

/// "Parley anrufen" — the overview's one big action; during a call, the way back to it.
private struct CallParleyButton: View {
    let call: CallController
    let canCall: Bool
    let action: () -> Void
    @ScaledMetric(relativeTo: .title3) private var iconSize: CGFloat = 44

    var body: some View {
        if call.isBusy {
            Button { call.showsScreen = true } label: {
                HStack(spacing: 14) {
                    RingView(session: Session(id: "call", state: call.phase.isActive ? .speaking : .queued), skew: 0, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(call.phase == .ringing ? "Eingehender Anruf" : "Anruf läuft").font(.headline)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(Self.subtitle(call.phase, at: context.date))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Spacer(minLength: 8)
                    Text("Zurück").font(.subheadline.weight(.semibold)).foregroundStyle(SessionState.idle.ink)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(SessionState.idle.color.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(SessionState.idle.color.opacity(0.45)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Öffnet den Anruf")
        } else {
            Button(action: action) {
                HStack(spacing: 14) {
                    Image(systemName: "phone.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(canCall ? Theme.claude : .secondary)
                        .frame(width: iconSize, height: iconSize)
                        .background(Circle().fill(canCall ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(Theme.background)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Parley anrufen").font(.title3.bold())
                        Text(canCall ? "oder „Hey Siri, Parley anrufen“" : "Geht, sobald der Mac verbunden ist")
                            .font(.subheadline)
                            .opacity(canCall ? 0.85 : 1)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(canCall ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
                    if canCall {
                        shape.fill(LinearGradient(colors: [Theme.claudeLight, Theme.claude], startPoint: .top, endPoint: .bottom))
                            .shadow(color: Theme.claude.opacity(0.3), radius: 12, y: 5)
                    } else {
                        shape.fill(Theme.card).overlay(shape.strokeBorder(Theme.stroke))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canCall)
            .sensoryFeedback(.impact(weight: .medium), trigger: call.phase) { old, new in old == .none && new != .none }
        }
    }

    private static func subtitle(_ phase: CallPhase, at date: Date) -> String {
        switch phase {
        case .active(let since): "mit Parley · " + Fmt.clock(date.timeIntervalSince(since) * 1000)
        case .ringing: "Tippe, um ranzugehen"
        default: "Verbinde…"
        }
    }
}

/// A failed call, said once on the overview.
private struct CallFailureBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "phone.down.fill").foregroundStyle(Theme.danger)
            Text(text).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            .accessibilityLabel("Schließen")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.danger.opacity(0.10)))
        .task {
            try? await Task.sleep(for: .seconds(8))
            dismiss()
        }
    }
}

/// A capsule switch for the header (the Unterwegs-Modus): filled in Claude orange when on.
struct PillToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .labelStyle(Tight())
                .fixedSize()
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(configuration.isOn ? .white : .secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Capsule().fill(configuration.isOn ? Theme.claude : Theme.card))
                .overlay(Capsule().strokeBorder(configuration.isOn ? .clear : Theme.stroke))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: configuration.isOn)
        .sensoryFeedback(.selection, trigger: configuration.isOn)
        .accessibilityValue(configuration.isOn ? "an" : "aus")
        .accessibilityAddTraits(.isToggle)
    }

    /// Symbol and word close together: status, Unterwegs and Stumm fit one row (~360 of 370 pt).
    private struct Tight: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 5) { configuration.icon; configuration.title }
        }
    }
}
