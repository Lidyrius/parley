import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsUnpair = false
    @AppStorage(CallController.speakerKey) private var speakerByDefault = true
    @AppStorage(CallController.autoHangUpKey) private var autoHangUp = false
    @AppStorage(CallController.bargeInKey) private var bargeIn = true
    /// Unlocked by tapping "Version" five times.
    @AppStorage("developer") private var developer = false
    @State private var versionTaps = 0
    @State private var appIcon = AppIconChoice.current

    /// "Aus", "30 s", "1 Min.", "90 s", "2 Min." …
    static func roundLabel(_ s: Int) -> String {
        s == 0 ? "Aus" : s % 60 == 0 ? "\(s / 60) Min." : "\(s) s"
    }

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
                    Toggle(isOn: $autoHangUp) {
                        Label("Nach dem Gespräch auflegen", systemImage: "phone.down.circle")
                    }
                    Toggle(isOn: $bargeIn) {
                        Label("Parley unterbrechen", systemImage: "hand.raised")
                    }
                    Picker(selection: $model.roundSeconds) {
                        ForEach(AppModel.roundChoices, id: \.self) { Text(Self.roundLabel($0)).tag($0) }
                    } label: {
                        Label("Fragerunde", systemImage: "rectangle.stack.badge.person.crop")
                    }
                } header: {
                    Text("Anrufe")
                } footer: {
                    Text("Unterwegs klingeln Updates als Anruf auf diesem iPhone, statt auf dem Mac gesprochen zu werden. Mit „Stumm“ kommt stattdessen eine Mitteilung; tippe darauf und antworte schriftlich. Anrufe starten auf dem Lautsprecher (AirPods und Auto bleiben, wie sie sind). „Nach dem Gespräch auflegen“: Hat Parley zu Ende gesprochen, legt es sofort auf – gut, wenn danach wieder Musik laufen soll. Aus, bleibt Parley dran und du redest einfach weiter. Anrufen geht jederzeit mit „Hey Siri, Parley anrufen“ – auch in CarPlay. Während des Anrufs holst du Parley mit „Hey Parley“. „Parley unterbrechen“: Fang einfach an zu reden, während Parley spricht (oder sag „Stopp“) – Parley verstummt sofort und hört zu. „Fragerunde“: Nach einem Anruf wartet ein neues Update so lange auf die anderen, solange noch eine Session arbeitet – dann kommt alles in einem Anruf. Arbeitet keine andere, klingelt es sofort; dein eigener Rückruf-Timer wartet nie. Automatisch: Einstellungen → Fokus → z. B. „Fahren“ → Fokusfilter → Parley schaltet Unterwegs mit dem Fokus ein und aus; oder in Kurzbefehle → Automation (CarPlay verbunden, Zuhause verlassen) die Aktion „Unterwegs“.")
                }
                Section("Darstellung") {
                    AppIconRow(selection: $appIcon)
                    Picker("Erscheinungsbild", selection: Binding(get: { Appearance.shared.scheme },
                                                                   set: { Appearance.shared.scheme = $0 })) {
                        ForEach(SchemeChoice.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(Theme.palette.alwaysDark)   // the night light stays dark
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
                        OrbPicker()
                    } label: {
                        LabeledContent {
                            Text(Appearance.shared.orbStyle.name)
                        } label: {
                            Label("Parley im Anruf", systemImage: "sparkles")
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
                if developer {
                    Section {
                        NavigationLink {
                            OrbTunerList()
                        } label: {
                            Label("Kugel-Regler", systemImage: "slider.horizontal.3")
                        }
                        NavigationLink {
                            RingTunerList()
                        } label: {
                            Label("Anruf-Regler", systemImage: "slider.horizontal.below.circle.lefthalf.filled")
                        }
                        NavigationLink {
                            PaletteEditor(base: Theme.palette, isNew: true)
                        } label: {
                            Label("Palette bauen", systemImage: "paintbrush.pointed.fill")
                        }
                        ForEach(Appearance.shared.customPalettes) { p in
                            NavigationLink {
                                PaletteEditor(base: p, isNew: false)
                            } label: {
                                Label(p.name, systemImage: "swatchpalette")
                            }
                        }
                        Toggle(isOn: $developer) {
                            Label("Entwicklermodus", systemImage: "hammer.fill")
                        }
                    } header: {
                        Text("Entwickler")
                    }
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                        .contentShape(Rectangle())
                        .onTapGesture {
                            versionTaps += 1
                            if versionTaps >= 5 { withAnimation { developer = true }; versionTaps = 0 }
                        }
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
        .tint(Theme.control)   // switches on every settings page: a near-white accent turns grey
    }
}

/// Einstellungen → Farbpalette: every palette with a light and a dark preview.
struct PalettePicker: View {
    private let appearance = Appearance.shared

    var body: some View {
        List {
            Section {
                ForEach(Palette.all) { row($0) }
            } footer: {
                Text("Gilt für die ganze App, hell und dunkel; Nachtlicht bleibt immer dunkel. In jeder Palette bleiben die Zustände klar unterscheidbar: spricht, wartet, arbeitet, bereit.")
            }
            if !appearance.customPalettes.isEmpty {
                Section {
                    ForEach(appearance.customPalettes) { row($0) }
                } header: {
                    Text("Eigene")
                } footer: {
                    Text("Gebaut im Entwicklermodus; dort lassen sie sich bearbeiten und löschen.")
                }
            }
            Section {
                ForEach(Palette.classics) { row($0) }
            } header: {
                Text("Klassiker")
            } footer: {
                Text("Die bekannten Editor-Paletten von vorher.")
            }
        }
        .navigationTitle("Farbpalette")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ p: Palette) -> some View {
        let picked = p.id == appearance.paletteID
        return Button {
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
        let pick = { (s: Shade) in Color(hex: dark || palette.alwaysDark ? s.dark : s.light) }
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
        .testCall()
    }
}

/// Einstellungen → Parley im Anruf: the five particle orbs, each moving live.
struct OrbPicker: View {
    private let appearance = Appearance.shared

    var body: some View {
        List {
            Section {
                ForEach(OrbStyle.allCases) { o in
                    let picked = o == appearance.orbStyle
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { appearance.orbStyle = o }
                    } label: {
                        HStack(spacing: 14) {
                            OrbPreview(style: o)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(o.name).font(.headline).foregroundStyle(.primary)
                                Text(o.note).font(.subheadline).foregroundStyle(.secondary)
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
                Text("So sieht Parley im Anruf aus. Die Teilchen bewegen sich von selbst und reagieren auf die Stimme – beim Sprechen auf Parleys, beim Zuhören auf deine.")
            }
        }
        .navigationTitle("Parley im Anruf")
        .navigationBarTitleDisplayMode(.inline)
        .testCall()
    }
}

/// A small orb that "speaks" now and then, so the previews show how each reacts to a voice.
private struct OrbPreview: View {
    let style: OrbStyle

    var body: some View {
        ParticleOrb(style: style, color: Theme.claude, size: 76) { date in
            let t = date.timeIntervalSinceReferenceDate
            let talking = t.truncatingRemainder(dividingBy: 6) < 3.5
            return talking ? 0.35 + 0.3 * abs(sin(t * 7.3)) * abs(cos(t * 3.1)) : 0
        }
        .frame(width: 96, height: 80)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.background))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
    }
}

extension View {
    /// A "Probeanruf" button in the toolbar: the call screen rings with the picked look; answering
    /// shows Parley speaking for a few seconds, any button ends it.
    func testCall() -> some View { modifier(TestCall()) }
}

private struct TestCall: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.call.startTest()
                        showing = model.call.isTest
                    } label: {
                        Text("Probeanruf")
                    }
                    .disabled(model.call.phase != .none)
                }
            }
            .fullScreenCover(isPresented: $showing) {
                CallView()
            }
            .onChange(of: model.call.phase) { _, phase in
                if phase == .none { showing = false }
            }
    }
}

/// Einstellungen → Entwickler → Kugel-Regler: the five orbs, each with its own knobs.
struct OrbTunerList: View {
    var body: some View {
        List(OrbStyle.allCases) { style in
            NavigationLink {
                KnobTuner(title: style.name, knobs: Knobs.list(style)) { talking in
                    ParticleOrb(style: style, color: Theme.claude, size: 190) { date in KnobTuner<EmptyView>.voice(date, talking) }
                }
            } label: {
                LabeledContent(style.name, value: "\(Knobs.list(style).count) Regler")
            }
        }
        .navigationTitle("Kugel-Regler")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Einstellungen → Entwickler → Anruf-Regler: the five ringing motions, each with its own knobs.
struct RingTunerList: View {
    var body: some View {
        List(RingStyle.allCases) { style in
            NavigationLink {
                KnobTuner(title: style.name, knobs: Knobs.list(style), toggleLabel: "Klingeln") { ringing in
                    RingingStage(style: style, color: Theme.claude, active: ringing, ring: 84) {
                        ParticleOrb(style: Appearance.shared.orbStyle, color: Theme.claude, size: 126)
                    }
                }
            } label: {
                LabeledContent(style.name, value: "\(Knobs.list(style).count) Regler")
            }
        }
        .navigationTitle("Anruf-Regler")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Knobs with a live preview pinned on top (it stays in view while the sliders scroll). The
/// toggle under the preview runs the preview (speaking / ringing); a changed value shows in the
/// accent, swipe a row to set it back.
struct KnobTuner<Preview: View>: View {
    let title: String
    let knobs: [Knob]
    var toggleLabel = "Sprechen simulieren"
    @ViewBuilder let preview: (Bool) -> Preview
    @State private var on = true
    private let appearance = Appearance.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                preview(on)
                    .frame(maxWidth: .infinity)
                    .frame(height: 240)
                Toggle(toggleLabel, isOn: $on)
                    .font(.subheadline)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            .background(Theme.card)
            .clipped()
            .overlay(alignment: .bottom) { Divider() }
            Form {
                ForEach(sections, id: \.self) { section in
                    Section(section) {
                        ForEach(knobs.filter { $0.section == section }) { slider($0) }
                    }
                }
                Section {
                    Button("Alle auf Standard") {
                        withAnimation { for k in knobs { appearance.tuning.values[k.id] = nil } }
                    }
                    .disabled(!knobs.contains { appearance.tuning.values[$0.id] != nil })
                } footer: {
                    Text("Wirkt sofort im Anruf. Eine Zeile zur Seite wischen setzt nur diesen Wert zurück.")
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .testCall()
    }

    private var sections: [String] {
        knobs.reduce(into: [String]()) { if !$0.contains($1.section) { $0.append($1.section) } }
    }

    private func slider(_ k: Knob) -> some View {
        let value = Binding<Double>(get: { appearance.tuning[k] },
                                    set: { appearance.tuning.values[k.id] = k.whole ? $0.rounded() : $0 })
        let changed = appearance.tuning.values[k.id] != nil
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(k.label).font(.subheadline)
                Spacer()
                Text(k.whole ? String(Int(value.wrappedValue)) : String(format: "%.3g", value.wrappedValue))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(changed ? Theme.claude : .secondary)
            }
            if k.whole {
                Slider(value: value, in: k.range, step: 1)
            } else {
                Slider(value: value, in: k.range)
            }
        }
        .swipeActions {
            Button("Standard") { appearance.tuning.values[k.id] = nil }
        }
    }

    /// A voice for the preview: speaking in bursts, or silent.
    static func voice(_ date: Date, _ talking: Bool) -> Double {
        guard talking else { return 0 }
        let t = date.timeIntervalSinceReferenceDate
        return t.truncatingRemainder(dividingBy: 6) < 4 ? 0.3 + 0.35 * abs(sin(t * 7.3)) * abs(cos(t * 3.1)) : 0
    }
}

/// The app's icon on the Home Screen: Porzellan · Indigo (the primary) or an alternate.
enum AppIconChoice: String, CaseIterable, Identifiable {
    case porzellan, indigo, graphit, petrol

    var id: Self { self }

    var name: String {
        switch self {
        case .porzellan: "Porzellan"
        case .indigo: "Indigo"
        case .graphit: "Graphit"
        case .petrol: "Petrol"
        }
    }

    /// The alternate icon (ios/AppIcons), nil = the primary.
    var iconName: String? { self == .porzellan ? nil : "AppIcon-" + name }
    var preview: String { "IconPreview" + name }

    static var current: Self {
        let set = UIApplication.shared.alternateIconName
        return allCases.first { $0.iconName == set } ?? .porzellan
    }
}

/// The four icons side by side; a tap switches at once (iOS confirms with its own short note).
private struct AppIconRow: View {
    @Binding var selection: AppIconChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("App-Symbol", systemImage: "app.badge")
            HStack(spacing: 0) {
                ForEach(AppIconChoice.allCases) { choice in
                    Button { pick(choice) } label: {
                        VStack(spacing: 6) {
                            Image(choice.preview)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 58, height: 58)
                                .padding(3)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                                        .strokeBorder(selection == choice ? Theme.claude : .clear, lineWidth: 2.5)
                                }
                            Text(choice.name)
                                .font(.caption)
                                .foregroundStyle(selection == choice ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("App-Symbol \(choice.name)")
                    .accessibilityAddTraits(selection == choice ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 4)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func pick(_ choice: AppIconChoice) {
        guard choice != selection, UIApplication.shared.supportsAlternateIcons else { return }
        let before = selection
        selection = choice
        Task {
            do { try await UIApplication.shared.setAlternateIconName(choice.iconName) } catch { selection = before }
        }
    }
}

