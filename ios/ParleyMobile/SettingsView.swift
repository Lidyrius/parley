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
                Section("Darstellung") {
                    NavigationLink {
                        PalettePicker()
                    } label: {
                        LabeledContent {
                            Text(Theme.palette.name)
                        } label: {
                            Label("Farbpalette", systemImage: "paintpalette.fill")
                        }
                    }
                    NavigationLink {
                        RingPicker()
                    } label: {
                        LabeledContent {
                            Text(Appearance.shared.ringStyle.name)
                        } label: {
                            Label("Anruf-Animation", systemImage: "phone.arrow.down.left.fill")
                        }
                    }
                    NavigationLink {
                        RevealPicker()
                    } label: {
                        LabeledContent {
                            Text(Appearance.shared.lineReveal.name)
                        } label: {
                            Label("Diagramm-Aufbau", systemImage: "chart.xyaxis.line")
                        }
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

/// Einstellungen → Farbpalette: every palette with a light and a dark preview.
struct PalettePicker: View {
    private let appearance = Appearance.shared

    var body: some View {
        List {
            Section {
                ForEach(Palette.all) { p in
                    let picked = p.id == appearance.paletteID
                    Button {
                        withAnimation(.easeInOut(duration: 0.35)) { appearance.paletteID = p.id }
                    } label: {
                        HStack(spacing: 14) {
                            PalettePreview(palette: p)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.name).font(.headline).foregroundStyle(.primary)
                                Text(p.note).font(.subheadline).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(picked ? Theme.claude : Color.secondary.opacity(0.4))
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)   // the row's text stays black/white, not the accent
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            } footer: {
                Text("Gilt für die ganze App, hell und dunkel. In jeder Palette bleiben die Zustände klar unterscheidbar: spricht, wartet, arbeitet, bereit.")
            }
        }
        .navigationTitle("Farbpalette")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A palette at a glance: light and dark side by side, each a card with the accent and state dots.
private struct PalettePreview: View {
    let palette: Palette

    var body: some View {
        HStack(spacing: 0) {
            half(dark: false)
            half(dark: true)
        }
        .frame(width: 88, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .accessibilityHidden(true)
    }

    private func half(dark: Bool) -> some View {
        let pick = { (s: Shade) in Color(hex: dark ? s.dark : s.light) }
        return ZStack {
            pick(palette.background)
            VStack(spacing: 5) {
                Circle().fill(pick(palette.accent)).frame(width: 15, height: 15)
                HStack(spacing: 3) {
                    ForEach(Array([palette.waiting, palette.working, palette.idle].enumerated()), id: \.offset) { _, s in
                        Circle().fill(pick(s)).frame(width: 5, height: 5)
                    }
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(pick(palette.card)))
        }
    }
}

/// Einstellungen → Diagramm-Aufbau: the five ways a line chart builds up, each playing in a loop.
struct RevealPicker: View {
    private let appearance = Appearance.shared

    var body: some View {
        List {
            Section {
                ForEach(LineReveal.allCases) { r in
                    let picked = r == appearance.lineReveal
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { appearance.lineReveal = r }
                    } label: {
                        HStack(spacing: 14) {
                            RevealPreview(reveal: r)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.name).font(.headline).foregroundStyle(.primary)
                                Text(r.note).font(.subheadline).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(picked ? Theme.claude : Color.secondary.opacity(0.4))
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            } footer: {
                Text("So bauen sich Liniendiagramme auf, wenn Parley im Anruf eine Folie zeigt.")
            }
        }
        .navigationTitle("Diagramm-Aufbau")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A small line chart replaying its build-up every few seconds.
private struct RevealPreview: View {
    let reveal: LineReveal
    @State private var progress = 0.0

    var body: some View {
        LineChart(labels: [], values: [5, 11, 9, 20, 25, 35, 41], reveal: reveal, progress: progress, compact: true)
            .frame(width: 96, height: 58)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
            .accessibilityHidden(true)
            .task {
                while !Task.isCancelled {
                    progress = 0
                    try? await Task.sleep(for: .milliseconds(400))
                    withAnimation(.easeInOut(duration: 1.8)) { progress = 1 }
                    try? await Task.sleep(for: .seconds(3.6))
                }
            }
    }
}

/// Einstellungen → Anruf-Animation: the five ways an incoming call moves, each playing live.
struct RingPicker: View {
    private let appearance = Appearance.shared

    var body: some View {
        List {
            Section {
                ForEach(RingStyle.allCases) { r in
                    let picked = r == appearance.ringStyle
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { appearance.ringStyle = r }
                    } label: {
                        HStack(spacing: 14) {
                            RingingStage(style: r, color: Theme.claude, ring: 30) {
                                ZStack {
                                    Circle().fill(Theme.claude.opacity(0.12)).frame(width: 38, height: 38)
                                    Image(systemName: "phone.fill").font(.footnote).foregroundStyle(Theme.claude)
                                }
                            }
                            .frame(width: 96, height: 72)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.background))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
                            .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.name).font(.headline).foregroundStyle(.primary)
                                Text(r.note).font(.subheadline).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(picked ? Theme.claude : Color.secondary.opacity(0.4))
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            } footer: {
                Text("So klingelt Parley im Anruf-Bildschirm. Beim Annehmen zieht sich die Animation in den Ring zurück und geht in den Anruf über.")
            }
        }
        .navigationTitle("Anruf-Animation")
        .navigationBarTitleDisplayMode(.inline)
    }
}
