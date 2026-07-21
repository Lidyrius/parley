import SwiftUI
import AppKit

// Liquid Glass statistics dashboard. Signature elements: the "Zeit gespart" hero and the
// Intent-Mix bar (from the classifier) — both specific to Parley, not a generic KPI grid.
struct StatsView: View {
    @ObservedObject var store: StatsStore
    @State private var scope: Scope = .session

    enum Scope: String, CaseIterable { case session = "Diese Sitzung", total = "Gesamt" }
    private var data: StatsData { scope == .session ? store.session : store.total }

    // Intent colors — the one place we spend color, tied to what the categories mean.
    private static let intentOrder = [
        "FEATURE", "BUG", "RESEARCH", "QUESTION", "CONTINUE", "STOP",
        "FEATURE_RESEARCH", "BUG_FEATURE", "OTHER",
    ]
    private func color(_ intent: String) -> Color {
        switch intent {
        case "FEATURE": .blue; case "BUG": .orange; case "RESEARCH": .mint
        case "QUESTION": .cyan; case "CONTINUE": .green; case "STOP": .secondary
        case "FEATURE_RESEARCH": .indigo; case "BUG_FEATURE": .pink; default: .purple
        }
    }
    private func label(_ intent: String) -> String {
        switch intent {
        case "FEATURE": "Feature"; case "BUG": "Bug"; case "RESEARCH": "Research"
        case "QUESTION": "Frage"; case "CONTINUE": "Weiter"; case "STOP": "Stopp"
        case "FEATURE_RESEARCH": "Feat+Rech"; case "BUG_FEATURE": "Bug+Feat"; default: "Sonstiges"
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                hero
                intentMix
                grid
                projects
                credits
            }
            .padding(20)
        }
        .frame(width: 460, height: 640)
        .background(background)
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis.ascending").foregroundStyle(.tint)
                Text("Statistiken").font(.title2.weight(.semibold))
                Spacer()
            }
            Picker("", selection: $scope) {
                ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // Hero: time saved — the emotional headline.
    private var hero: some View {
        VStack(spacing: 4) {
            Text("Zeit gespart").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(duration(data.timeSavedSeconds))
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .foregroundStyle(.tint)
                .contentTransition(.numericText())
            Text("gegenüber Tippen (⌀ 40 WPM)").font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .liquidGlass(cornerRadius: 20)
    }

    // Signature: distribution of what you asked for.
    @ViewBuilder private var intentMix: some View {
        let items = Self.intentOrder.map { ($0, data.intents[$0] ?? 0) }
        let sum = max(1, items.reduce(0) { $0 + $1.1 })
        VStack(alignment: .leading, spacing: 8) {
            Text("Was du gesagt hast").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(items, id: \.0) { intent, n in
                        if n > 0 {
                            color(intent)
                                .frame(width: max(3, geo.size.width * CGFloat(n) / CGFloat(sum)))
                        }
                    }
                    if items.allSatisfy({ $0.1 == 0 }) {
                        Color.secondary.opacity(0.15)
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 12)
            HStack(spacing: 12) {
                ForEach(items.filter { $0.1 > 0 }, id: \.0) { intent, n in
                    HStack(spacing: 4) {
                        Circle().fill(color(intent)).frame(width: 7, height: 7)
                        Text("\(label(intent)) \(n)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if items.allSatisfy({ $0.1 == 0 }) {
                    Text("Noch keine Turns").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 16)
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            tile("Turns", int(data.turns), "arrow.triangle.2.circlepath")
            tile("Sitzungen", int(data.sessions), "rectangle.stack")
            tile("Wörter gesprochen", int(data.userWords), "person.wave.2")
            tile("Wörter von Parley", int(data.parleyWords), "waveform")
            tile("Deine Sprechzeit", duration(data.userSpeakingSeconds), "mic")
            tile("Zeichen (TTS)", int(data.charsSpoken), "textformat")
        }
    }

    private func tile(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: symbol).font(.caption).foregroundStyle(.tint)
                Spacer()
            }
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold))
                .contentTransition(.numericText())
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 14)
    }

    @ViewBuilder private var projects: some View {
        let top = data.projectTurns.sorted { $0.value > $1.value }.prefix(3)
        if !top.isEmpty {
            let maxN = max(1, top.first?.value ?? 1)
            VStack(alignment: .leading, spacing: 8) {
                Text("Top-Projekte").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                ForEach(Array(top), id: \.key) { name, n in
                    HStack(spacing: 8) {
                        Text(name).font(.callout).lineLimit(1)
                        Spacer()
                        Capsule().fill(.tint.opacity(0.25))
                            .frame(width: 60 * CGFloat(n) / CGFloat(maxN) + 4, height: 6)
                        Text("\(n)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlass(cornerRadius: 16)
        }
    }

    private var credits: some View {
        let free = StatsData.freeCharsPerMonth
        let withinFree = data.estimatedDollarsThisMonth == 0
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Google TTS diesen Monat").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text("\(int(data.charsThisMonth)) / \(int(free)) Zeichen frei")
                    .font(.callout.weight(.medium))
            }
            Spacer()
            Text(withinFree ? "gratis" : String(format: "≈ $%.2f", data.estimatedDollarsThisMonth))
                .font(.system(.title3, design: .rounded).weight(.semibold)).foregroundStyle(.tint)
        }
        .padding(16)
        .liquidGlass(cornerRadius: 16)
    }

    private var background: some View {
        ZStack {
            Rectangle().fill(.background)
            LinearGradient(colors: [.accentColor.opacity(0.12), .clear], startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        }
    }

    // MARK: formatting

    private func int(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = "."
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    private func duration(_ s: Double) -> String {
        if s < 60 { return "\(Int(s)) Sek" }
        if s < 3600 { return "\(Int((s / 60).rounded())) Min" }
        return String(format: "%.1f Std", s / 3600).replacingOccurrences(of: ".", with: ",")
    }
}

@MainActor
final class StatsPresenter {
    static let shared = StatsPresenter()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Parley — Statistiken"
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.center()
            w.contentView = NSHostingView(rootView: StatsView(store: StatsStore.shared))
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
