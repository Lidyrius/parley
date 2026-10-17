import SwiftUI
import UIKit

/// The Markdown Claude writes, as blocks the session view lays out like the Claude app:
/// paragraphs, headings, lists, quotes, rules, fenced code and tables. Inline styling (bold,
/// italics, `code`, links) is AttributedString's.
enum Markdown {
    enum Block: Equatable {
        case paragraph(String)
        case heading(Int, String)
        case bullet(String, level: Int)
        case numbered(String, String)          // "3.", text
        case quote(String)
        case code(lang: String, code: String)
        case table(String)                     // the raw rows, shown monospaced
        case rule
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        var fence: (lang: String, lines: [String])?
        var table: [String] = []

        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
            if !table.isEmpty { out.append(.table(table.joined(separator: "\n"))); table = [] }
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if var f = fence {
                if line.hasPrefix("```") {
                    out.append(.code(lang: f.lang, code: f.lines.joined(separator: "\n")))
                    fence = nil
                } else {
                    f.lines.append(raw)
                    fence = f
                }
                continue
            }
            if line.hasPrefix("```") {
                flush()
                fence = (String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), [])
                continue
            }
            if line.hasPrefix("|") {
                if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
                table.append(line)
                continue
            }
            if !table.isEmpty { out.append(.table(table.joined(separator: "\n"))); table = [] }
            if line.isEmpty { flush(); continue }
            if let m = line.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                flush(); out.append(.heading(m.1.count, String(m.2)))
            } else if line.wholeMatch(of: /^(-{3,}|\*{3,}|_{3,})$/) != nil {
                flush(); out.append(.rule)
            } else if let m = raw.firstMatch(of: /^(\s*)[-*•]\s+(.*)$/) {
                flush(); out.append(.bullet(String(m.2), level: m.1.count / 2))
            } else if let m = line.firstMatch(of: /^(\d+[.)])\s+(.*)$/) {
                flush(); out.append(.numbered(String(m.1), String(m.2)))
            } else if line.hasPrefix(">") {
                flush(); out.append(.quote(String(line.drop(while: { $0 == ">" || $0 == " " }))))
            } else {
                paragraph.append(line)
            }
        }
        if let f = fence { out.append(.code(lang: f.lang, code: f.lines.joined(separator: "\n"))) }   // unclosed
        flush()
        return out
    }

    /// Inline Markdown with `code` in the Claude app's colours.
    @MainActor static func inline(_ s: String) -> AttributedString {
        var a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        for run in a.runs where run.inlinePresentationIntent?.contains(.code) == true {
            a[run.range].font = .system(.body, design: .monospaced)
            a[run.range].foregroundColor = Theme.codeText
            a[run.range].backgroundColor = Theme.codeBackground
        }
        return a
    }

    /// Plain text for read-aloud / copy: no fences, markers or link syntax.
    @MainActor static func plain(_ s: String) -> String {
        blocks(s).map { block -> String in
            switch block {
            case .paragraph(let t), .heading(_, let t), .bullet(let t, _), .quote(let t): String(inline(t).characters)
            case .numbered(let n, let t): n + " " + String(inline(t).characters)
            case .code(_, let c), .table(let c): c
            case .rule: ""
            }
        }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

/// One assistant message, laid out like the Claude app: full width, no bubble.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(Markdown.blocks(text).enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(_ block: Markdown.Block) -> some View {
        switch block {
        case .paragraph(let t):
            Text(Markdown.inline(t)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let t):
            Text(Markdown.inline(t)).font(level <= 2 ? .title3.bold() : .headline)
        case .bullet(let t, let level):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(level == 0 ? "•" : "◦").fontWeight(.bold)
                Text(Markdown.inline(t)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 6 + CGFloat(level) * 18)
        case .numbered(let n, let t):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(n).monospacedDigit()
                Text(Markdown.inline(t)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 4)
        case .quote(let t):
            Text(Markdown.inline(t))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
        case .code(let lang, let code):
            CodeBlock(lang: lang, code: code)
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(rows).font(.footnote.monospaced()).padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.codeBlock))
        case .rule:
            Divider()
        }
    }
}

/// A fenced code block: language, copy, full screen — like the Claude app.
struct CodeBlock: View {
    let lang: String
    let code: String
    @State private var copied = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                Text(lang.isEmpty ? "code" : lang).font(.callout.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "square.on.square")
                }
                .accessibilityLabel("Code kopieren")
                Button { expanded = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .accessibilityLabel("Vollbild")
            }
            .font(.body)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.callout.monospaced()).foregroundStyle(Color(light: 0x4D7A3A, dark: 0xA8C97F))
                    .padding(16)
                    .textSelection(.enabled)
            }
        }
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.codeBlock))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.stroke))
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
        .sheet(isPresented: $expanded) {
            NavigationStack {
                ScrollView([.horizontal, .vertical]) {
                    Text(code).font(.callout.monospaced()).padding().textSelection(.enabled)
                }
                .navigationTitle(lang.isEmpty ? "Code" : lang)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Fertig") { expanded = false } }
                    ToolbarItem(placement: .topBarLeading) {
                        Button { UIPasteboard.general.string = code } label: { Image(systemName: "doc.on.doc") }
                    }
                }
            }
        }
    }
}
