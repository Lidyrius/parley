import AVFAudio
import SwiftUI

/// A session's history (v3), laid out like the Claude app's chat: Claude's text full width,
/// your messages in grey bubbles, tool steps folded into one line ("2 Befehle ausgeführt ›",
/// with +/− for file edits), screenshots, copy / read-aloud under each answer, a jump to the
/// newest, and the message box. Polls ~3 s while open; older pages load at the top.
struct SessionView: View {
    let id: String
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var zoomed: ZoomedImage?
    @State private var sent = 0
    @State private var openGroups: Set<String> = []
    /// Paging: only once the view settled at the bottom (else the top row's first layout
    /// would page at once); the row to stay on when an older page lands in front.
    @State private var canPage = false
    @State private var keep: String?
    @State private var atBottom = true
    @State private var copied: String?
    @FocusState private var typing: Bool
    @State private var voice = AVSpeechSynthesizer()
    @ScaledMetric(relativeTo: .subheadline) private var toolSize: CGFloat = 14.5   // Claude's tool lines run a touch smaller

    var body: some View {
        let session = model.relay.snapshot?.sessions.first { $0.id == id }
        let items = model.histories[id]
        let pending = model.pending[id] ?? []
        let rows = Self.rows(items ?? [])
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if let items, items.isEmpty {
                        Text("Für diese Session gibt es keinen Verlauf (z. B. Codex).")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else if items == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    if model.hasOlder.contains(id) {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .onAppear {
                                guard canPage, !model.loadingOlder.contains(id) else { return }
                                keep = rows.first?.id
                                model.loadOlder(id)
                            }
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                        switch r {
                        case .item(let item): row(item, actions: Self.endsTurn(rows, at: i)).id(item.id)
                        case .tools(let tools): toolGroup(tools).id(r.id)
                        }
                    }
                    ForEach(Array(pending.enumerated()), id: \.offset) { _, text in
                        bubble(text, caption: "wird zugestellt…").opacity(0.55).id("pending-\(text)")
                    }
                    Color.clear.frame(height: 1).id("end")
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .bottom) {
                if !atBottom {
                    Button {
                        withAnimation(.snappy) { proxy.scrollTo("end", anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(.regularMaterial))
                            .overlay(Circle().stroke(Theme.stroke))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .accessibilityLabel("Zum Ende springen")
                }
            }
            .animation(.snappy, value: atBottom)
            .onChange(of: items?.first?.id) {
                // An older page went in front: stay on the row that was on top.
                guard let keep else { return }
                self.keep = nil
                Task {
                    try? await Task.sleep(for: .milliseconds(30))
                    proxy.scrollTo(keep, anchor: .top)
                }
            }
            .onChange(of: items == nil) {
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    canPage = true
                }
            }
            .onChange(of: (items?.last?.id ?? "") + "\(pending.count)") {
                // Follow new rows only when at the end (after layout, else it stops short).
                guard atBottom || pending.count > 0 else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(80))
                    withAnimation(.snappy) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom) { inputBar(session) }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar(session) }
        .task {
            // Opened for "Nachricht" (the overview's sheet): the keyboard comes up at once.
            guard model.compose == id else { return }
            model.compose = nil
            try? await Task.sleep(for: .milliseconds(400))
            typing = true
        }
        .task(id: id) {
            while !Task.isCancelled {
                model.loadHistory(id)
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .sensoryFeedback(.success, trigger: sent)
        .sensoryFeedback(.success, trigger: copied) { _, new in new != nil }
        .fullScreenCover(item: $zoomed) { z in ImageViewer(image: z.image) }
        .onDisappear { voice.stopSpeaking(at: .immediate) }
    }

    // MARK: - header

    @ToolbarContentBuilder
    private func toolbar(_ session: Session?) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(session?.name ?? "Session").font(.headline).lineLimit(1)
                if let session {
                    Text(Fmt.stateLabel(session)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        if let session, Self.busy.contains(session.state) {
            ToolbarItem(placement: .topBarTrailing) {
                ProgressView().tint(.primary).accessibilityLabel(Fmt.stateLabel(session))
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let session, session.canResume {
                    Button { model.resume(id) } label: { Label("Fortsetzen", systemImage: "play.fill") }
                }
                Button { model.loadHistory(id) } label: { Label("Neu laden", systemImage: "arrow.clockwise") }
                if let last = model.histories[id]?.last(where: { $0.kind == .assistant })?.text {
                    Button { copy(last, key: "menu") } label: { Label("Letzte Antwort kopieren", systemImage: "doc.on.doc") }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .tint(.primary)
            .accessibilityLabel("Mehr")
        }
    }

    private static let busy: Set<SessionState> = [.speaking, .listening, .transcribing, .queued, .working, .background]

    // MARK: - rows

    @ViewBuilder
    private func row(_ item: ChatItem, actions: Bool) -> some View {
        switch item.kind {
        case .user:
            bubble(item.text ?? "")
        case .voice:
            bubble(item.text ?? "", caption: "Antwort über Parley")
        case .assistant:
            VStack(alignment: .leading, spacing: 12) {
                MarkdownView(text: item.text ?? "")
                if actions { messageActions(item) }
            }
        case .speak:
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text(item.text ?? "").italic().foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(Theme.claude)
                }
                if actions { messageActions(item) }
            }
        case .tool:
            EmptyView()   // folded into tool groups (rows)
        case .image:
            image(item)
        case .other:
            EmptyView()
        }
    }

    /// Copy and read aloud, under the last message of each answer — like the Claude app.
    private func messageActions(_ item: ChatItem) -> some View {
        let text = answerText(before: item)
        return HStack(spacing: 22) {
            Button { copy(text, key: item.id) } label: {
                Image(systemName: copied == item.id ? "checkmark" : "square.on.square")
            }
            .accessibilityLabel("Antwort kopieren")
            Button { readAloud(text) } label: { Image(systemName: "play") }
                .accessibilityLabel("Vorlesen")
        }
        .font(.body)
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
    }

    /// The answer an action row belongs to: Claude's text plus the spoken line after it.
    private func answerText(before item: ChatItem) -> String {
        let items = model.histories[id] ?? []
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return item.text ?? "" }
        var parts: [String] = []
        var j = i
        while j >= 0, items[j].kind == .assistant || items[j].kind == .speak {
            parts.insert(items[j].kind == .assistant ? Markdown.plain(items[j].text ?? "") : (items[j].text ?? ""), at: 0)
            j -= 1
        }
        return parts.joined(separator: "\n\n")
    }

    private func copy(_ text: String, key: String) {
        UIPasteboard.general.string = text
        copied = key
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copied == key { copied = nil }
        }
    }

    private func readAloud(_ text: String) {
        if voice.isSpeaking { voice.stopSpeaking(at: .immediate); return }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "de-DE")
        voice.speak(u)
    }

    /// The copy / read-aloud row goes under the last of Claude's lines before you speak again.
    nonisolated static func endsTurn(_ rows: [Row], at i: Int) -> Bool {
        guard case .item(let item) = rows[i], item.kind == .assistant || item.kind == .speak else { return false }
        for next in rows[(i + 1)...] {
            switch next {
            case .item(let n) where n.kind == .user || n.kind == .voice: return true
            case .item(let n) where n.kind == .assistant || n.kind == .speak: return false
            default: continue   // tools, images in between
            }
        }
        return true
    }

    private func bubble(_ text: String, caption: String? = nil) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(text)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.userBubble))
            if let caption {
                Label(caption, systemImage: "waveform").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 44)
    }

    private func image(_ item: ChatItem) -> some View {
        Group {
            if let ui = model.images[item.id] {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke))
                    .onTapGesture { zoomed = ZoomedImage(id: item.id, image: ui) }
                    .accessibilityLabel(item.fromUser ? "Bild von dir" : "Screenshot")
                    .accessibilityAddTraits(.isButton)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.card)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .overlay { Image(systemName: "photo").font(.title).foregroundStyle(.tertiary) }
                    .task { model.loadImage(session: id, key: item.id) }
            }
        }
        .frame(maxWidth: 300, maxHeight: 340)
        .frame(maxWidth: .infinity, alignment: item.fromUser ? .trailing : .leading)
    }

    // MARK: - tool steps

    /// Consecutive tool steps fold into one row, like the Claude app.
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

    nonisolated static func rows(_ items: [ChatItem]) -> [Row] {
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

    private enum Step: CaseIterable {
        case command, read, create, edit, search, web, tool

        init(_ name: String) {
            switch name {
            case "Bash", "BashOutput", "PowerShell": self = .command
            case "Read", "NotebookRead": self = .read
            case "Write": self = .create
            case "Edit", "MultiEdit", "NotebookEdit": self = .edit
            case "Grep", "Glob", "LS": self = .search
            case "WebFetch", "WebSearch": self = .web
            default: self = .tool
            }
        }

        /// "Ausgeführt" — the single step's verb.
        var done: String {
            switch self {
            case .command: "Ausgeführt"
            case .read: "Gelesen"
            case .create: "Erstellt"
            case .edit: "Bearbeitet"
            case .search: "Gesucht"
            case .web: "Abgerufen"
            case .tool: "Verwendet"
            }
        }

        /// "einen Befehl ausgeführt" / "2 Befehle ausgeführt".
        func count(_ n: Int) -> String {
            switch self {
            case .command: n == 1 ? "einen Befehl ausgeführt" : "\(n) Befehle ausgeführt"
            case .read: n == 1 ? "eine Datei gelesen" : "\(n) Dateien gelesen"
            case .create: n == 1 ? "eine Datei erstellt" : "\(n) Dateien erstellt"
            case .edit: n == 1 ? "eine Datei bearbeitet" : "\(n) Dateien bearbeitet"
            case .search: n == 1 ? "einmal gesucht" : "\(n)-mal gesucht"
            case .web: n == 1 ? "eine Seite abgerufen" : "\(n) Seiten abgerufen"
            case .tool: n == 1 ? "ein Tool verwendet" : "\(n) Tools verwendet"
            }
        }
    }

    nonisolated private static func split(_ t: ChatItem) -> (name: String, detail: String?) {
        let parts = (t.text ?? "").components(separatedBy: " · ")
        return (parts[0], parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : nil)
    }

    /// "Ausgeführt Delete probe customer…" for one step; "Eine Datei erstellt, einen Befehl
    /// ausgeführt" for several (kinds in order of first use).
    nonisolated static func summary(_ tools: [ChatItem]) -> String {
        if tools.count == 1, let t = tools.first {
            let (name, detail) = split(t)
            return "\(Step(name).done) \(detail ?? name)"
        }
        var order: [Step] = []
        var counts: [Step: Int] = [:]
        for t in tools {
            let step = Step(split(t).name)
            if counts[step] == nil { order.append(step) }
            counts[step, default: 0] += 1
        }
        let text = order.map { $0.count(counts[$0]!) }.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Lines added / removed by the run's file edits; nil when none edited a file.
    nonisolated static func diff(_ tools: [ChatItem]) -> (add: Int, del: Int)? {
        let edits = tools.filter { $0.add != nil || $0.del != nil }
        guard !edits.isEmpty else { return nil }
        return (edits.reduce(0) { $0 + ($1.add ?? 0) }, edits.reduce(0) { $0 + ($1.del ?? 0) })
    }

    /// One Text, so it wraps like a sentence: "Eine Datei erstellt, … +62 −0 ›".
    private func summaryLine(_ tools: [ChatItem], open: Bool) -> some View {
        var line = AttributedString(Self.summary(tools) + "  ")
        line.font = .system(size: toolSize)
        if let d = Self.diff(tools) {
            var add = AttributedString(" +\(d.add) ")
            add.foregroundColor = Theme.diffAdd
            add.backgroundColor = Theme.diffAddBackground
            var del = AttributedString(" −\(d.del) ")
            del.foregroundColor = Theme.diffDel
            del.backgroundColor = Theme.diffDelBackground
            for var part in [add, del] {
                part.font = .system(size: toolSize * 0.85).monospacedDigit()
                line += part
            }
            var gap = AttributedString("  ")
            gap.font = .system(size: toolSize)
            line += gap
        }
        return Text(line) + Text(Image(systemName: open ? "chevron.down" : "chevron.right"))
            .font(.system(size: toolSize * 0.9, weight: .semibold))
    }

    private func toolGroup(_ tools: [ChatItem]) -> some View {
        let key = tools.first?.id ?? ""
        let open = openGroups.contains(key)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) {
                    if open { openGroups.remove(key) } else { openGroups.insert(key) }
                }
            } label: {
                summaryLine(tools, open: open)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(open ? "Schritte ausblenden" : "Schritte anzeigen")
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(tools) { t in
                        let (name, detail) = Self.split(t)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(name).fontWeight(.medium)
                            if let detail { Text(detail).font(.footnote.monospaced()).lineLimit(3) }
                            if t.add != nil || t.del != nil { DiffBadge(add: t.add ?? 0, del: t.del ?? 0) }
                        }
                        .textSelection(.enabled)
                    }
                }
                .font(.subheadline)
                .padding(.leading, 14)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.stroke).frame(width: 2) }
                .transition(.opacity)
            }
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - message box

    private func inputBar(_ session: Session?) -> some View {
        let canSend = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (model.relay.canSend || model.demo)
        return VStack(alignment: .leading, spacing: 12) {
            TextField("Nachricht an \(session?.name ?? "die Session")", text: $draft, axis: .vertical)
                .focused($typing)
                .lineLimit(1...6)
            HStack(spacing: 10) {
                if let session {
                    HStack(spacing: 6) {
                        Circle().fill(session.state.color).frame(width: 8, height: 8)
                        Text(session.name).fontWeight(.medium)
                        Text(Fmt.stateLabel(session)).foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.userBubble))
                }
                Spacer(minLength: 0)
                Button {
                    model.say(draft, to: id)
                    draft = ""
                    sent += 1
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Theme.claude.opacity(canSend ? 1 : 0.45)))
                }
                .disabled(!canSend)
                .accessibilityLabel("Senden")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Theme.stroke))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 2)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}

/// "+62 −0" — green and red on tinted backgrounds, as in the Claude app.
private struct DiffBadge: View {
    let add: Int
    let del: Int

    var body: some View {
        HStack(spacing: 0) {
            Text("+\(add)").foregroundStyle(Theme.diffAdd).padding(.horizontal, 5).padding(.vertical, 2).background(Theme.diffAddBackground)
            Text("−\(del)").foregroundStyle(Theme.diffDel).padding(.horizontal, 5).padding(.vertical, 2).background(Theme.diffDelBackground)
        }
        .font(.caption.monospacedDigit())
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityLabel("\(add) Zeilen hinzugefügt, \(del) entfernt")
    }
}

struct ZoomedImage: Identifiable {
    let id: String
    let image: UIImage
}

/// Full screen, pinch to zoom, double-tap, ✕ to close.
struct ImageViewer: View {
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
