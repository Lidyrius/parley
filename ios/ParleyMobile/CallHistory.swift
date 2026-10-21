import SwiftUI

/// `-demoHistory open|typing`: the call screen with its history open (and the message box in
/// use), for screenshots.
enum CallHistoryDemo {
    static let mode: String? = {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-demoHistory"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }()
}

/// The history in a call (swipe the subtitles up) — Sir's words in bubbles, Parley's in full, tool steps
/// folded into one quiet line, and the line being spoken right now at the end, highlighted.
struct CallTranscript: View {
    let items: [ChatItem]?
    var pending: [String] = []
    let live: String?
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: close) {
                Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 40, height: 5)
                    .frame(maxWidth: .infinity).padding(.vertical, 10).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Verlauf schließen")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if items == nil { ProgressView().frame(maxWidth: .infinity).padding(.top, 30) }
                    ForEach(Self.rows(items ?? []), id: \.id) { row in
                        switch row.kind {
                        case .user:
                            Text(row.text)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.userBubble))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.leading, 40)
                        case .tool:
                            Label(row.text, systemImage: "gearshape.2")
                                .font(.footnote).foregroundStyle(.secondary)
                        default:
                            Text(Self.markdown(row.text)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    ForEach(Array(pending.enumerated()), id: \.offset) { _, text in
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(text)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.userBubble))
                            Text("wird zugestellt…").font(.caption2).foregroundStyle(.secondary)
                        }
                        .opacity(0.6)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.leading, 40)
                    }
                    if let live {
                        HStack(alignment: .top, spacing: 10) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.claude).frame(width: 4)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("JETZT").font(.caption2.weight(.bold)).foregroundStyle(Theme.claude)
                                Text(live).font(.title3.weight(.medium))
                            }
                        }
                        .id("live")
                    }
                }
                .padding(.bottom, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)   // pulling the history down ends the writing
        }
    }

    private struct Row { let id: String; let kind: ChatItem.Kind; let text: String }

    /// Consecutive tool steps → one line ("3 Schritte").
    private static func rows(_ items: [ChatItem]) -> [Row] {
        var out: [Row] = []
        var tools = 0
        func flush(_ id: String) {
            if tools > 0 { out.append(Row(id: "t" + id, kind: .tool, text: tools == 1 ? "1 Schritt" : "\(tools) Schritte")) }
            tools = 0
        }
        for item in items {
            if item.kind == .tool { tools += 1; continue }
            guard let text = item.text, !text.isEmpty, item.kind != .image else { continue }
            flush(item.id)
            out.append(Row(id: item.id, kind: item.kind == .voice ? .user : item.kind, text: text))
        }
        flush("end")
        return out
    }

    private static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
