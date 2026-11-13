import SwiftUI

/// The overview's top left: the host this phone talks to — its name, with its connection's
/// colour. A tap opens the hosts.
struct HostChip: View {
    let name: String
    let status: ConnectionStatus
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(status.color).frame(width: 8, height: 8)
                Text(name).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
            }
            // "Snapshots" and the gear keep their place: a long name is cut, and — a bar item —
            // it keeps subheadline's size at every text size (a long press shows it large).
            .font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: 112)
        }
        .accessibilityShowsLargeContentViewer { Label(name, systemImage: "desktopcomputer") }
        .accessibilityLabel(status.label(host: name))
        .accessibilityHint("Zeigt die Hosts: wechseln, hinzufügen, umbenennen")
    }
}

/// "Hosts": the Macs, PCs and servers this phone is paired with. A tap makes one the active
/// host — the overview then shows its sessions —, "Host hinzufügen" pairs a further one (the same
/// scanner as the first), and each can be renamed or removed. During a call the host stays.
struct HostsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showsScanner = false
    @State private var renaming: HostPairing?
    @State private var name = ""
    @State private var removing: HostPairing?

    var body: some View {
        let hosts = model.hosts.hosts, active = model.hosts.active?.id
        let busy = model.call.isBusy
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Ein Host ist der Mac, PC oder Server, auf dem Parley läuft. Die Übersicht zeigt immer einen.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if busy {
                        Label("Im Anruf bleibt der Host. Zum Wechseln erst auflegen.", systemImage: "phone.fill")
                            .font(.subheadline)
                            .foregroundStyle(SessionState.idle.ink)
                            .padding(.horizontal, 14).padding(.vertical, 11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SessionState.idle.color.opacity(0.14)))
                    }
                    VStack(spacing: 0) {
                        ForEach(hosts) { h in
                            row(h, active: h.id == active, busy: busy)
                            Divider().padding(.leading, 54)
                        }
                        Button { showsScanner = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill").font(.title2)
                                Text("Host hinzufügen").font(.body.weight(.semibold))
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(Theme.claude)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                        .opacity(busy ? 0.45 : 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .background(CardBackground())
                    Text("Jeder Host hat seine eigenen Sessions, Snapshots und Wiedervorlagen. Geteilte Sessions bleiben beim Wechsel, wie sie sind.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .padding(16)
                .containerRelativeFrame(.horizontal, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .background(Theme.background)
            .navigationTitle("Hosts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .task {   // `-demoAddHost` (screenshots): the scanner, once the sheet is up
            guard ProcessInfo.processInfo.arguments.contains("-demoAddHost") else { return }
            try? await Task.sleep(for: .seconds(1))
            showsScanner = true
        }
        .fullScreenCover(isPresented: $showsScanner, onDismiss: askName) { ScannerSheet() }
        // A host added by a link opened elsewhere (the system camera): its name is asked here too.
        .onChange(of: model.naming?.id, initial: true) { _, _ in if !showsScanner { askName() } }
        .alert("Host benennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name, z. B. Server", text: $name)
            Button("Sichern") {
                if let h = renaming { model.renameHost(h.id, to: name) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("So heißt er oben in der Übersicht.")
        }
        .confirmationDialog("„\(removing?.name ?? "")“ entfernen?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Entfernen", role: .destructive) {
                if let h = removing { model.removeHost(h.id) }
                if model.hosts.hosts.isEmpty { dismiss() }
            }
        } message: {
            Text("Sein Schlüssel verlässt dieses iPhone. Seine Sessions sind erst nach erneutem Koppeln wieder zu sehen.")
        }
    }

    private func row(_ h: HostPairing, active: Bool, busy: Bool) -> some View {
        let status = model.relay.status
        return HStack(spacing: 0) {
            Button {
                model.activate(h.id)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: active ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(active ? Theme.claude : Color.secondary.opacity(0.5))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                        if active {
                            HStack(spacing: 6) {
                                Circle().fill(status.color).frame(width: 7, height: 7)
                                Text(status.word).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 14)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy && !active)
            .opacity(busy && !active ? 0.45 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(h.name)
            .accessibilityValue(active ? "aktiv, \(status.word)" : "")
            .accessibilityHint(active ? "" : busy ? "Im Anruf nicht wählbar" : "Wechselt zu diesem Host")
            .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
            Menu {
                Button("Umbenennen", systemImage: "pencil") { rename(h) }
                Button("Entfernen", systemImage: "trash", role: .destructive) { removing = h }
                    .disabled(busy && active)   // its call would end
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(Color.secondary)
                    .frame(width: 48, height: 48).contentShape(Rectangle())
            }
            .accessibilityLabel("Mehr zu \(h.name)")
        }
    }

    private func rename(_ h: HostPairing) {
        name = h.name
        renaming = h
    }

    /// A host just added beside the others: what should it be called? (Its link's name, or
    /// "Host 2", stands in the field.)
    private func askName() {
        guard let h = model.naming else { return }
        model.naming = nil
        rename(h)
    }
}
