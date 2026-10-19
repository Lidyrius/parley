import SwiftUI

/// "Snapshots" (docs/design/screens/ios/50-snapshots, variant A): keep the running sessions under a
/// name and open them all again with one tap — on the Mac, in the background. The host keeps the
/// list; it comes with every `sessions` frame.
struct SnapshotsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Route] = []
    @State private var deleting: SavedSnapshot?

    enum Route: Hashable { case save, opened(SavedSnapshot) }

    var body: some View {
        let relay = model.relay
        let list = relay.snapshot?.snapshots ?? []
        let live = relay.snapshot?.sessions.filter { $0.state != .stopped } ?? []
        let canSend = relay.canSend || model.demo
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Ein Snapshot merkt sich Name, Session-ID und Ordner jeder Session.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button { path.append(.save) } label: {
                        Label("Aktuellen Stand sichern", systemImage: "square.on.square")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.onAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Capsule().fill(Theme.claude))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend || live.isEmpty)
                    .opacity(canSend && !live.isEmpty ? 1 : 0.45)
                    if list.isEmpty {
                        Text("Noch keine Snapshots. Sichern Sie den aktuellen Stand, um ihn später mit einem Tipp wieder zu öffnen.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .padding(.top, 6)
                    } else {
                        SectionLabel(text: "Gesichert · \(list.count)")
                        ForEach(list) { s in
                            SnapshotCard(snapshot: s, now: relay.hostNow(.now), canOpen: canSend,
                                         open: { model.openSnapshot(s); path.append(.opened(s)) },
                                         delete: { deleting = s })
                        }
                    }
                }
                .padding(16)
                .containerRelativeFrame(.horizontal, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .background(Theme.background)
            .navigationTitle("Snapshots")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .save: SaveSnapshotView(sessions: live) { path.removeAll() }
                case .opened(let s): OpenedSnapshotView(snapshot: s)
                }
            }
            .confirmationDialog("„\(deleting?.name ?? "")“ löschen?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Löschen", role: .destructive) {
                    if let s = deleting { model.deleteSnapshot(s.id) }
                    deleting = nil
                }
            } message: {
                Text("Die Sessions selbst bleiben, wie sie sind.")
            }
        }
    }
}

private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            .padding(.leading, 4)
    }
}

private struct SnapshotCard: View {
    let snapshot: SavedSnapshot
    let now: Double
    let canOpen: Bool
    let open: () -> Void
    let delete: () -> Void

    var body: some View {
        let n = snapshot.sessions.count
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snapshot.name).font(.headline)
                Text(n == 1 ? "1 Session" : "\(n) Sessions").font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Menu {
                    Button("Löschen", systemImage: "trash", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 32, height: 24).contentShape(Rectangle())
                }
                .accessibilityLabel("Mehr")
            }
            Text(snapshot.sessions.map(\.name).joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Button(action: open) {
                    Label("Öffnen", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(Theme.claude))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canOpen)
                .opacity(canOpen ? 1 : 0.45)
                Spacer()
                Text(Fmt.snapshotDate(snapshot.at, now: now)).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(CardBackground())
    }
}

/// "Snapshot sichern": a name, and which running sessions (all ticked to begin with).
private struct SaveSnapshotView: View {
    @Environment(AppModel.self) private var model
    let sessions: [Session]
    let done: () -> Void
    @State private var name = ""
    @State private var off: Set<String> = []
    @FocusState private var focused: Bool

    var body: some View {
        let chosen = sessions.filter { !off.contains($0.id) }
        let canSave = !name.trimmingCharacters(in: .whitespaces).isEmpty && !chosen.isEmpty
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Name, z. B. Kunde Müller", text: $name)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { if canSave { save(chosen) } }
                    .padding(.horizontal, 16).padding(.vertical, 13)
                    .background(CardBackground(radius: 14))
                SectionLabel(text: "Diese Sessions · \(chosen.count) von \(sessions.count)")
                VStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { i, s in
                        if i > 0 { Divider().padding(.leading, 52) }
                        let on = !off.contains(s.id)
                        Button {
                            if on { off.insert(s.id) } else { off.remove(s.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .font(.title2)
                                    .foregroundStyle(on ? Theme.claude : Color.secondary.opacity(0.5))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                    if !s.project.isEmpty {
                                        Text(s.project).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .background(CardBackground())
                Text("Gemerkt werden Name, Session-ID und Ordner. Derselbe Name ersetzt den alten Snapshot.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding(16)
            .containerRelativeFrame(.horizontal, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .background(Theme.background)
        .navigationTitle("Snapshot sichern")
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Abbrechen", action: done) }
            ToolbarItem(placement: .confirmationAction) {
                Button("Sichern") { save(chosen) }.disabled(!canSave)
            }
        }
        .onAppear { focused = true }
    }

    private func save(_ chosen: [Session]) {
        model.saveSnapshot(name: name, ids: chosen.map(\.id))
        done()
    }
}

/// After "Öffnen": what became of each session, as the host reports it.
private struct OpenedSnapshotView: View {
    @Environment(AppModel.self) private var model
    let snapshot: SavedSnapshot

    var body: some View {
        let results = model.opened[snapshot.id]
        let n = snapshot.sessions.count
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(n == 1 ? "1 Session öffnet sich auf dem Mac im Hintergrund." : "\(n) Sessions öffnen sich auf dem Mac im Hintergrund.")
                    .font(.subheadline).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.sessions.enumerated()), id: \.offset) { i, item in
                        if i > 0 { Divider().padding(.leading, 56) }
                        row(item.name, results.map { r in r.first { $0.id == item.id }?.kind ?? .missing })
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .background(CardBackground())
            }
            .padding(16)
            .containerRelativeFrame(.horizontal, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .background(Theme.background)
        .navigationTitle(snapshot.name)
        .animation(.snappy, value: results)
    }

    /// `kind` nil: the host hasn't answered yet.
    private func row(_ name: String, _ kind: SnapshotResult.Kind?) -> some View {
        let (symbol, text, color): (String, String, Color) = switch kind {
        case nil: ("", "wird geöffnet …", .secondary)
        case .running: ("checkmark", "läuft schon", SessionState.idle.color)
        case .resumed: ("arrow.clockwise", "wird fortgesetzt", SessionState.working.color)
        case .started: ("plus", "nicht gefunden – neu im Ordner gestartet", SessionState.waiting.color)
        case .missing: ("exclamationmark", "Ordner fehlt", Theme.danger)
        }
        return HStack(spacing: 12) {
            ZStack {
                if kind == nil {
                    ProgressView()
                } else {
                    Circle().fill(color)
                    Image(systemName: symbol).font(.footnote.weight(.bold)).foregroundStyle(.white)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.semibold))
                Text(text).font(.subheadline).foregroundStyle(kind == nil ? Color.secondary : color)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}

extension Fmt {
    /// A snapshot's date (host epoch ms, `now` on the host clock): "heute 14:02", "gestern", "12.10.".
    static func snapshotDate(_ at: Double, now: Double, calendar: Calendar = .current) -> String {
        let day = Date(timeIntervalSince1970: at / 1000), today = Date(timeIntervalSince1970: now / 1000)
        if calendar.isDate(day, inSameDayAs: today) {
            let c = calendar.dateComponents([.hour, .minute], from: day)
            return String(format: "heute %d:%02d", c.hour ?? 0, c.minute ?? 0)
        }
        if let y = calendar.date(byAdding: .day, value: -1, to: today), calendar.isDate(day, inSameDayAs: y) { return "gestern" }
        let c = calendar.dateComponents([.day, .month], from: day)
        return "\(c.day ?? 0).\(c.month ?? 0)."
    }
}
