import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsUnpair = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Verbindung") {
                    LabeledContent("Status", value: model.relay.status.label)
                    if let p = model.pairing {
                        LabeledContent("Relay", value: p.relay.host(percentEncoded: false) ?? p.relay.absoluteString)
                        LabeledContent("Raum", value: String(p.room.prefix(8)) + "…")
                    }
                    if model.demo {
                        Text("Demo-Modus: Beispieldaten, keine Verbindung.").foregroundStyle(.secondary)
                    }
                }
                if model.pairing != nil {
                    Section {
                        Button("Neu verbinden") { model.relay.reconnect() }
                    }
                    Section {
                        Button("Verbindung trennen", role: .destructive) { confirmsUnpair = true }
                    } footer: {
                        Text("Entfernt den Schlüssel von diesem iPhone. Zum erneuten Koppeln den QR-Code in Parley auf dem Mac scannen.")
                    }
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
            .confirmationDialog("Verbindung trennen?", isPresented: $confirmsUnpair, titleVisibility: .visible) {
                Button("Verbindung trennen", role: .destructive) {
                    model.unpair()
                    dismiss()
                }
            } message: {
                Text("Das iPhone sieht deine Sessions erst wieder, wenn du es neu koppelst.")
            }
        }
    }
}
