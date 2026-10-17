import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsUnpair = false
    @AppStorage(CallController.speakerKey) private var speakerByDefault = true

    var body: some View {
        @Bindable var model = model
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
                Section {
                    Toggle(isOn: $model.away) {
                        Label("Unterwegs-Modus", systemImage: "car.fill")
                    }
                    Toggle(isOn: $model.silent) {
                        Label("Stumm", systemImage: "bell.slash.fill")
                    }
                    .disabled(!model.away)
                    Toggle(isOn: $speakerByDefault) {
                        Label("Lautsprecher beim Anrufstart", systemImage: "speaker.wave.2.fill")
                    }
                } header: {
                    Text("Anrufe")
                } footer: {
                    Text("Unterwegs klingeln Updates als Anruf auf diesem iPhone, statt auf dem Mac gesprochen zu werden. Mit „Stumm“ kommt stattdessen eine Mitteilung; tippe darauf und antworte schriftlich. Anrufe starten auf dem Lautsprecher (AirPods und Auto bleiben, wie sie sind). Anrufen geht jederzeit mit „Hey Siri, Parley anrufen“ – auch in CarPlay. Während des Anrufs holst du Parley mit „Hey Parley“.")
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
