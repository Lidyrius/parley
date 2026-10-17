import SwiftUI

/// A session's recent history (v3): what was typed or said, Claude's answers, the lines Parley
/// spoke, tool steps and screenshots — plus a field to write to the session. Polls ~3 s while open.
struct SessionView: View {
    let id: String
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var zoomed: ZoomedImage?
    @State private var sent = 0
    @State private var openGroups: Set<String> = []

    var body: some View {
        let session = model.relay.snapshot?.sessions.first { $0.id == id }
        let items = model.histories[id]
        let pending = model.pending[id] ?? []
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let items, items.isEmpty {
                        Text("Für diese Session gibt es keinen Verlauf (z. B. Codex).")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else if items == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(Self.rows(items ?? [])) { r in
                        switch r {
                        case .item(let item): row(item).id(item.id)
                        case .tools(let tools): toolGroup(tools).id(r.id)
                        }
                    }
                    ForEach(Array(pending.enumerated()), id: \.offset) { _, text in
                        bubble(text, mine: true, caption: "wird zugestellt…").opacity(0.55).id("pending-\(text)")
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(16)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: (items?.last?.id ?? "") + "\(pending.count)") {
                // After the new rows are laid out, else it stops short of the end.
                Task {
                    try? await Task.sleep(for: .milliseconds(80))
                    withAnimation(.snappy) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom) { inputBar(name: session?.name ?? "Session") }
        .navigationTitle(session?.name ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: id) {
            while !Task.isCancelled {
                model.loadHistory(id)
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .sensoryFeedback(.success, trigger: sent)
        .fullScreenCover(item: $zoomed) { z in ImageViewer(image: z.image) }
    }

    @ViewBuilder
    private func row(_ item: ChatItem) -> some View {
        switch item.kind {
        case .user:
            bubble(item.text ?? "", mine: true)
        case .voice:
            bubble(item.text ?? "", mine: true, caption: "Antwort über Parley")
        case .assistant:
            Text(Self.markdown(item.text ?? ""))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
        case .speak:
            Label {
                Text(item.text ?? "").italic()
            } icon: {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Theme.claude)
            }
            .font(.callout)
            .padding(.horizontal, 4)
        case .tool:
            EmptyView()   // folded into tool groups (rows)
        case .image:
            image(item)
        case .other:
            EmptyView()
        }
    }

    /// Consecutive tool steps fold into one row ("3 Schritte · Bash, Edit"), like Claude Code.
    enum Row: Identifiable, Equatable {
        case item(ChatItem)
        case tools([ChatItem])
        var id: String {
            switch self {
            case .item(let i): i.id
            case .tools(let t): "tools-" + (t.first?.id ?? "")
            }
        }
    }

    static func rows(_ items: [ChatItem]) -> [Row] {
        var out: [Row] = []
        for item in items {
            if item.kind == .tool, case .tools(let run)? = out.last {
                out[out.count - 1] = .tools(run + [item])
            } else {
                out.append(item.kind == .tool ? .tools([item]) : .item(item))
            }
        }
        return out
    }

    /// "Bash, Edit" — the distinct tools of a run, in order.
    static func toolNames(_ tools: [ChatItem]) -> String {
        var seen: [String] = []
        for t in tools {
            let name = t.text?.components(separatedBy: " · ").first ?? ""
            if !name.isEmpty, !seen.contains(name) { seen.append(name) }
        }
        return seen.joined(separator: ", ")
    }

    private func toolGroup(_ tools: [ChatItem]) -> some View {
        let key = tools.first?.id ?? ""
        let open = openGroups.contains(key)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) {
                    if open { openGroups.remove(key) } else { openGroups.insert(key) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "hammer")
                    Text(tools.count == 1 ? "1 Schritt" : "\(tools.count) Schritte").fontWeight(.semibold)
                        + Text(" · " + Self.toolNames(tools))
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(open ? "Schritte ausblenden" : "Schritte anzeigen")
            if open {
                ForEach(tools) { t in
                    Text(t.text ?? "")
                        .font(.caption.monospaced())
                        .padding(.leading, 22)
                        .textSelection(.enabled)
                }
                .transition(.opacity)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card.opacity(0.6)))
    }

    private func bubble(_ text: String, mine: Bool, caption: String? = nil) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(text)
                .textSelection(.enabled)
                .padding(12)
                .foregroundStyle(.white)
                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.claude))
            if let caption { Text(caption).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }

    private func image(_ item: ChatItem) -> some View {
        Group {
            if let ui = model.images[item.id] {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onTapGesture { zoomed = ZoomedImage(id: item.id, image: ui) }
                    .accessibilityLabel(item.fromUser ? "Bild von dir" : "Screenshot")
                    .accessibilityAddTraits(.isButton)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.card)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .overlay { Image(systemName: "photo").font(.title).foregroundStyle(.tertiary) }
                    .task { model.loadImage(session: id, key: item.id) }
            }
        }
        .frame(maxWidth: 300, maxHeight: 320)
        .frame(maxWidth: .infinity, alignment: item.fromUser ? .trailing : .leading)
    }

    private func inputBar(name: String) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Nachricht an \(name)", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 20).fill(Theme.card))
            Button {
                model.say(draft, to: id)
                draft = ""
                sent += 1
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(model.relay.canSend || model.demo))
            .accessibilityLabel("Senden")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Inline markdown (bold, code, links), line breaks kept.
    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

private struct ZoomedImage: Identifiable {
    let id: String
    let image: UIImage
}

/// Full screen, pinch to zoom, tap ✕ to close.
private struct ImageViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(MagnifyGesture().onChanged { scale = max(1, base * $0.magnification) }.onEnded { _ in base = scale })
                .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5; base = scale } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.largeTitle).symbolRenderingMode(.hierarchical)
            }
            .tint(.white)
            .padding()
            .accessibilityLabel("Schließen")
        }
    }
}
