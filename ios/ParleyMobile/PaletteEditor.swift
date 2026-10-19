import SwiftUI

/// Einstellungen → Entwickler → Palette bauen: every colour of a palette, light and dark, with a
/// live preview of both modes. Saved palettes show under "Eigene" in the palette picker.
struct PaletteEditor: View {
    @State private var draft: Palette
    @State private var dark = false
    @Environment(\.dismiss) private var dismiss
    private let isNew: Bool

    /// A new palette starts as a copy of `base`; an existing one is edited in place.
    init(base: Palette, isNew: Bool) {
        var p = base
        if isNew {
            p.id = "custom-" + UUID().uuidString.prefix(8).lowercased()
            p.name = "Eigene Palette"
            p.note = "Nach \(base.name)"
        }
        _draft = State(initialValue: p)
        self.isNew = isNew
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    PaletteBoard(palette: draft, dark: false)
                    PaletteBoard(palette: draft, dark: true)
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            } footer: {
                Text("Links hell, rechts dunkel – so sieht die App mit dieser Palette aus.")
            }
            Section("Name") {
                TextField("Name", text: $draft.name)
                TextField("Beschreibung", text: $draft.note)
                Toggle("Immer dunkel", isOn: $draft.alwaysDark)
            }
            Section {
                Picker("Modus", selection: $dark) {
                    Text("Hell").tag(false)
                    Text("Dunkel").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(draft.alwaysDark)
                color("Hintergrund", \.background)
                color("Karten", \.card)
                color("Blase / Code", \.raised)
                color("Akzent (spricht)", \.accent)
                color("Wartet", \.waiting)
                color("Arbeitet", \.working)
                color("Im Hintergrund", \.purple)
                color("Bereit", \.idle)
                color("Gestoppt", \.stopped)
                color("Rot (Auflegen, Fehler)", \.red)
            } header: {
                Text("Farben")
            } footer: {
                Text("Im Farbwähler unter „Regler“ lässt sich auch ein Hex-Wert eingeben.")
            }
            if !draft.clashes.isEmpty {
                Section("Hinweise") {
                    ForEach(draft.clashes, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
            }
            if !isNew {
                Section {
                    Button("Palette löschen", role: .destructive) {
                        Appearance.shared.delete(draft.id)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(isNew ? "Neue Palette" : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Sichern") {
                    Appearance.shared.save(draft)
                    dismiss()
                }
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    /// One role's colour in the mode being edited (the night-light kind: always the dark one).
    private func color(_ title: String, _ role: WritableKeyPath<Palette, Shade>) -> some View {
        let darkSide = dark || draft.alwaysDark
        let binding = Binding<Color>(
            get: { Color(hex: darkSide ? draft[keyPath: role].dark : draft[keyPath: role].light) },
            set: { c in
                if darkSide { draft[keyPath: role].dark = c.hex } else { draft[keyPath: role].light = c.hex }
                if draft.alwaysDark { draft[keyPath: role].light = draft[keyPath: role].dark }
            })
        return ColorPicker(selection: binding, supportsOpacity: false) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "#%06X", darkSide ? draft[keyPath: role].dark : draft[keyPath: role].light))
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A small mock of the app in one mode: the call button, two session tiles, a chat bubble,
/// the state colours and Parley's orb — drawn from the palette's own values, not the app's.
struct PaletteBoard: View {
    let palette: Palette
    let dark: Bool

    private func c(_ s: Shade) -> Color { Color(hex: dark || palette.alwaysDark ? s.dark : s.light) }
    private var isDark: Bool { dark || palette.alwaysDark }

    var body: some View {
        let accentHex = isDark ? palette.accent.dark : palette.accent.light
        let onAccent = Color(hex: Shade.luminance(accentHex) > 0.5 ? 0x000000 : 0xFFFFFF)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Parley").font(.headline.bold())
                Spacer()
                ParticleOrb(style: .jarvis, color: c(palette.accent), size: 30) { date in
                    0.25 + 0.2 * abs(sin(date.timeIntervalSinceReferenceDate * 5))
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "phone.fill").font(.caption2.bold())
                Text("Parley anrufen").font(.caption.bold())
                Spacer(minLength: 0)
            }
            .foregroundStyle(onAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c(palette.accent)))
            HStack(spacing: 6) {
                tile("spricht", palette.accent)
                tile("arbeitet", palette.working)
            }
            HStack(spacing: 6) {
                tile("wartet", palette.waiting)
                tile("bereit", palette.idle)
            }
            Text("Wie sieht das aus?")
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(c(palette.raised)))
                .frame(maxWidth: .infinity, alignment: .trailing)
            HStack(spacing: 5) {
                ForEach(Array([palette.accent, palette.working, palette.idle, palette.waiting, palette.purple, palette.stopped].enumerated()),
                        id: \.offset) { _, s in Circle().fill(c(s)).frame(width: 9, height: 9) }
                Spacer(minLength: 0)
                Circle().fill(c(palette.red)).frame(width: 18, height: 18)
                    .overlay(Image(systemName: "phone.down.fill").font(.system(size: 8)).foregroundStyle(palette.red.onColor))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(c(palette.background)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .environment(\.colorScheme, isDark ? .dark : .light)
        .accessibilityHidden(true)
    }

    private func tile(_ label: String, _ s: Shade) -> some View {
        let ring = c(s)
        let inkHex = isDark ? s.dark : Shade.mix(s.light, 0x000000, 0.22)
        return VStack(alignment: .leading, spacing: 4) {
            Circle().strokeBorder(ring, lineWidth: 2.5).frame(width: 16, height: 16)
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(Color(hex: inkHex))
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(c(palette.card)))
    }
}
