import SwiftUI

struct MenuBarView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Vloude").font(.headline)
            Text("Voice layer for Claude Code").font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 240)
    }
}
