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
        let relay = model.relay
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    StatusHeader(relay: relay)
                    content(relay)
                }
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
                                            isExpanded: binding(s.id), onResume: { resume(s.id) })
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

/// Connection pill and today's totals ("**$13.61** Kosten · **65** Updates · …").
private struct StatusHeader: View {
    let relay: Relay

    var body: some View {
        let status = relay.status
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(status.color).frame(width: 8, height: 8)
                Text(status.label).font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(status.color.opacity(0.14)))
            .accessibilityElement(children: .combine)

            if let today = relay.snapshot?.today, status == .connected || status == .connecting {
                Text(Self.line(today))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
