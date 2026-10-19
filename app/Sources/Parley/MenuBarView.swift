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

                if !controller.parked.isEmpty {
                    Divider()
                    Text("Geparkt — zum Fortsetzen").font(.caption).foregroundStyle(.secondary)
                    ForEach(controller.parked) { p in
                        HStack {
                            Circle().fill(.purple).frame(width: 8, height: 8)
                            Text(p.label).font(.callout)
                            Spacer()
                            Button("Fortsetzen") { controller.resume(p.id) }
                                .controlSize(.small)
                        }
                    }
                }

                Divider()
                HStack {
                    Label("Snapshots", systemImage: "square.on.square").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Aktuellen Stand sichern …") { controller.saveSnapshot() }.controlSize(.small)
                }
                ForEach(controller.snapshots, id: \.id) { s in
                    HStack {
                        Text(s.name).font(.callout)
                        Text("\(s.sessions.count)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Öffnen") { controller.openSnapshot(s.id) }.controlSize(.small)
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
                Button("Handy verbinden…") { controller.pairIPhone() }
                if let up = controller.relayConnected {
                    Text(up ? "iPhone: verbunden mit Relay" : "iPhone: Relay nicht erreichbar")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if controller.phoneCall {
                    Label("iPhone: Anruf aktiv", systemImage: "phone.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                if controller.phoneAway {
                    Label("Unterwegs-Modus an", systemImage: "car.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("Unterwegs, wenn der Mac gesperrt ist", isOn: $controller.autoAwayOnLock)
                Toggle("Parley unterbrechen (einfach reinreden)", isOn: $controller.bargeIn)
                Button("Push-Schlüssel wählen…") { controller.choosePushKey() }
                if let key = controller.pushKeyId {
                    Text("Push-Schlüssel: \(key)").font(.caption2).foregroundStyle(.secondary)
                }

                Divider()
                Menu("Entwickler") {
                    Button("Zurücksetzen (Onboarding testen) — Statistiken bleiben") { DevTools.resetKeepingStats() }
                    Button("Onboarding zeigen") { DevTools.showOnboarding() }
                    Divider()
                    Button("Test-Benachrichtigung") { DevTools.testNotification() }
                    Button("Aufnahme-Pill testen") { DevTools.testRecordingPill() }
                    Button("Clips neu rendern") { DevTools.rerenderClips() }
                    Button("Log anzeigen") { DevTools.revealLog() }
                }
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
            .onAppear { controller.refreshResumable() }
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
        case "paused": return .purple
        case "muted": return .gray
        default: return .secondary
        }
    }
}
