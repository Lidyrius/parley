import SwiftUI

/// The main screen: the mod's `/parley` overview (design C) on the phone.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var expanded: Set<String>
    @State private var showsSettings = false

    init(expanded: Set<String> = []) {
        _expanded = State(initialValue: expanded)
    }

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
                    CallParleyButton(call: model.call, canCall: relay.canSend, action: model.callParley)
                    content(relay)
                }
                .animation(.snappy, value: model.call.failure)
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Theme.background)
            .navigationTitle("Parley")
            .toolbar {
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
            Notice(title: "Kopplung abgelehnt", symbol: "lock.slash",
                   text: "Das Relay kennt den Schlüssel dieses iPhones nicht. Wähle in Parley auf dem Mac „iPhone verbinden…“ und koppele neu.") {
                Button("Neu koppeln") { model.unpair() }.buttonStyle(.borderedProminent)
            }
        case .unreachable:
            Notice(title: "Keine Verbindung", symbol: "wifi.exclamationmark",
                   text: "Das Relay ist gerade nicht erreichbar. Parley versucht es automatisch weiter.") {
                Button("Erneut versuchen") { relay.reconnect() }.buttonStyle(.bordered)
            }
        case .connected, .connecting:
            if let snapshot = relay.snapshot {
                sessions(snapshot.sessions, skew: relay.skew, canSend: relay.canSend, resume: relay.resume)
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
    private func sessions(_ list: [Session], skew: Double, canSend: Bool, resume: @escaping (String) -> Void) -> some View {
        if list.isEmpty {
            Notice(title: "Keine Sessions", symbol: "waveform",
                   text: "Sobald eine Claude-Code- oder Codex-Session über Parley spricht, erscheint sie hier.")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Sessions").font(.title3.bold())
                    Text("\(list.filter { $0.state != .stopped }.count) aktiv").foregroundStyle(.secondary)
                }
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    ForEach(rows(list)) { row in
                        GridRow(alignment: .top) {
                            let opened = row.items.contains { expanded.contains($0.id) }
                            ForEach(row.items) { s in
                                SessionCard(session: s, skew: skew, canResume: canSend, fillsRow: !opened,
                                            isExpanded: binding(s.id), onResume: { resume(s.id) },
                                            onOpen: { model.open(session: s.id) })
                            }
                            ForEach(row.items.count..<columns, id: \.self) { _ in
                                Color.clear.gridCellUnsizedAxes(.vertical)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Two tiles a row like the mod; one at accessibility text sizes, three on wide screens.
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

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) },
                set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }
}

/// Connection pill, the Unterwegs-Modus switch, and today's totals ("**$13.61** Kosten · …").
private struct StatusHeader: View {
    let relay: Relay
    @Binding var away: Bool
    @Binding var silent: Bool

    var body: some View {
        let status = relay.status
        VStack(alignment: .leading, spacing: 10) {
            // Side by side; stacked when large text no longer fits one line.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    pill(status)
                    Spacer(minLength: 8)
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
            }

            if let today = relay.snapshot?.today, status == .connected || status == .connecting {
                Text(Self.line(today))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pill(_ status: ConnectionStatus) -> some View {
        HStack(spacing: 8) {
            Circle().fill(status.color).frame(width: 8, height: 8)
            Text(status.label).font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 12)
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

    /// Breaks only between the pairs: each value stays glued to its label.
    static func line(_ today: Today) -> AttributedString {
        var out = AttributedString.run("Heute   ", .secondary)
        for (i, f) in Fmt.todayParts(today).enumerated() {
            if i > 0 { out += .run("  ·  ", .secondary) }
            out += .run(f.value.replacingOccurrences(of: " ", with: "\u{00A0}"), bold: true)
            out += .run("\u{00A0}" + f.label, .secondary)
        }
        return out
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
                        .background(Circle().fill(canCall ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.background)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Parley anrufen").font(.title3.bold())
                        Text(canCall ? "oder „Hey Siri, Parley anrufen“" : "Geht, sobald der Mac verbunden ist")
                            .font(.subheadline)
                            .opacity(canCall ? 0.85 : 1)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(canCall ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
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
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(configuration.isOn ? .white : .secondary)
                .padding(.horizontal, 12)
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
}
