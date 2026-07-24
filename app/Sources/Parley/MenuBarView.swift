import SwiftUI

struct MenuBarView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        GlassContainer {
            VStack(alignment: .leading, spacing: 10) {
                Text("Parley").font(.headline)
                Text("Voice layer for Claude Code")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()

                if controller.sessions.isEmpty {
                    Text("No active sessions. Run /parley:voice in a Claude Code session.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(controller.sessions) { s in
                        HStack {
                            Circle().fill(color(for: s.status)).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.project).font(.callout)
                                Text("\(s.pane.isEmpty ? "no pane" : s.pane) · \(s.status)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }

                if let err = controller.lastError {
                    Text(err).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }

                Divider()
                Toggle(isOn: $controller.muted) {
                    Text(controller.muted ? "Stumm — Parley schweigt" : "Stumm schalten")
                }
                .toggleStyle(.switch).controlSize(.small)
                if !controller.muted && FocusStatus.doNotDisturbActive() {
                    Text("Nicht stören aktiv — Parley schweigt automatisch")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Divider()
                HStack {
                    Button("Statistiken…") { StatsPresenter.shared.show() }
                    SettingsLink { Text("Settings…") }
                    Button("Setup…") { OnboardingPresenter.shared.show() }
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
            }
            .padding(14)
            .frame(width: 300)
            .liquidGlass(cornerRadius: 16)
        }
    }

    private func color(for status: String) -> Color {
        switch status {
        case "speaking": return .blue
        case "listening": return .green
        case "transcribing": return .orange
        case "ready": return .teal
        case "queued": return .yellow
        case "muted": return .gray
        default: return .secondary
        }
    }
}
