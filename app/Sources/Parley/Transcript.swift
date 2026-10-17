import Foundation
import ImageIO
import UniformTypeIdentifiers

// A session's history for the phone (protocol v3, docs/IPHONE.md): read from Claude Code's own
// transcript (~/.claude/projects/<folder>/<session id>.jsonl), newest part only. Screenshots and
// pasted images become `image` items; their pixels go out one by one, downscaled, on request.
enum Transcript {
    struct Item: Codable, Equatable {
        var id: String       // "<entry uuid>#<n>" — stable across reads
        var k: String        // user | voice | assistant | speak | tool | image
        var text: String?
        var who: String?     // image: "user" | "assistant"
        var at: Double?      // epoch ms
        var add: Int?        // tool: lines a Write / Edit added
        var del: Int?        //       and removed
    }

    static let maxItems = 60
    static let maxText = 2500
    static let maxFrame = 200 * 1024     // relay limit is 256 KB
    static let tailBytes = 3 << 20

    static var projects: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// The transcript of `session` (a Claude Code session id), nil for Codex / unknown ids.
    static func file(for session: String, root: URL = projects) -> URL? {
        guard !session.isEmpty, !session.contains("/"), !session.contains("..") else { return nil }
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.map { $0.appendingPathComponent("\(session).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The last `bytes` of the file as whole JSON lines (the first, partial one dropped).
    static func tailLines(_ url: URL, bytes: Int = tailBytes) -> [Data] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? h.seek(toOffset: start)
        var lines = (try? h.readToEnd() ?? Data())?.split(separator: UInt8(ascii: "\n")) ?? []
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines.map { Data($0) }
    }

    // MARK: - items

    static func items(_ lines: [Data]) -> [Item] { Array(parse(lines).suffix(maxItems)) }

    /// One page of history: the newest (`before` nil, from the 3 MB tail) or the items right
    /// before the item `before`. `more` = there is older history still.
    static func page(_ url: URL, before: String?) -> (items: [Item], more: Bool) {
        guard let before else {
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
            let all = parse(tailLines(url))
            return (Array(all.suffix(maxItems)), all.count > maxItems || size > tailBytes)
        }
        // ponytail: an older page parses the whole file (~0.5 s for 30 MB); read it in windows if that shows.
        let all = parse(tailLines(url, bytes: .max))
        guard let i = all.firstIndex(where: { $0.id == before }) else { return ([], false) }
        let from = max(0, i - maxItems)
        return (Array(all[from..<i]), from > 0)
    }

    static func parse(_ lines: [Data]) -> [Item] {
        var out: [Item] = []
        for line in lines {
            guard let e = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let type = e["type"] as? String, type == "user" || type == "assistant",
                  e["isSidechain"] as? Bool != true, e["isCompactSummary"] as? Bool != true,
                  let uuid = e["uuid"] as? String,
                  let msg = e["message"] as? [String: Any] else { continue }
            let at = (e["timestamp"] as? String).flatMap(parseDate).map { $0.timeIntervalSince1970 * 1000 }
            var n = 0
            func add(_ k: String, _ text: String? = nil, who: String? = nil, diff: (Int, Int)? = nil) {
                out.append(Item(id: "\(uuid)#\(n)", k: k, text: text.map(clip), who: who, at: at, add: diff?.0, del: diff?.1))
                n += 1
            }
            if type == "assistant" {
                for b in msg["content"] as? [[String: Any]] ?? [] {
                    switch b["type"] as? String {
                    case "text":
                        let (body, spoken) = split(b["text"] as? String ?? "")
                        if !body.isEmpty { add("assistant", body) }
                        if let spoken { add("speak", spoken) }
                    case "tool_use":
                        let name = b["name"] as? String ?? "", input = b["input"] as? [String: Any] ?? [:]
                        add("tool", tool(name, input), diff: diff(name, input))
                    default: break
                    }
                }
                continue
            }
            // user: a typed message, a voice reply (Stop hook feedback), images, tool results.
            if let s = msg["content"] as? String {
                if e["isMeta"] as? Bool == true {
                    if let voice = voiceReply(s) { add("voice", voice) }
                } else if let text = userText(s) {
                    add("user", text)
                }
                continue
            }
            for b in msg["content"] as? [[String: Any]] ?? [] {
                switch b["type"] as? String {
                case "text" where e["isMeta"] as? Bool != true:
                    if let text = userText(b["text"] as? String ?? "") { add("user", text) }
                case "image":
                    add("image", who: "user")
                case "tool_result":
                    for c in b["content"] as? [[String: Any]] ?? [] where c["type"] as? String == "image" {
                        add("image", who: "assistant")
                    }
                default: break
                }
            }
        }
        return out
    }

    /// `{"t":"history","id":…,"items":[…],"more":…}` (+ `before` for an older page), oldest
    /// items dropped until it fits a relay frame (then there is more).
    static func historyFrame(session: String, items: [Item], before: String? = nil, more: Bool = false) -> String {
        struct Wire: Encodable { let t = "history"; let id: String; let before: String?; let more: Bool; let items: [Item] }
        var items = items, more = more
        while true {
            let data = (try? JSONEncoder().encode(Wire(id: session, before: before, more: more, items: items))) ?? Data()
            if data.count <= maxFrame || items.isEmpty { return String(decoding: data, as: UTF8.self) }
            items.removeFirst(max(1, items.count / 4))
            more = true
        }
    }

    // MARK: - past sessions (POST /past — the Zentrale looks one up to resume it)

    struct Past: Codable, Equatable {
        var id: String
        var title: String        // the session's title, else its last prompt
        var cwd: String
        var lastPrompt: String?
        var lastAt: Double       // epoch ms (file modified)
    }

    /// The newest sessions (up to `limit`) whose title, folder or last prompt contains `query`
    /// (all of them for an empty query). Scans the `scan` most recently written transcripts.
    static func past(query: String?, limit: Int = 10, root: URL = projects, scan: Int = 400) -> [Past] {
        let fm = FileManager.default
        var files: [(url: URL, at: Date)] = []
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let list = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in list where f.pathExtension == "jsonl" {
                files.append((f, (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast))
            }
        }
        files.sort { $0.at > $1.at }
        let q = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        var out: [Past] = []
        for f in files.prefix(scan) {
            guard let p = summary(f.url, at: f.at) else { continue }
            if q.isEmpty || [p.title, p.cwd, p.lastPrompt ?? ""].contains(where: { $0.lowercased().contains(q) }) { out.append(p) }
            if out.count >= limit { break }
        }
        return out
    }

    /// Title, folder and last prompt of one transcript; nil when it has no folder (not a session).
    static func summary(_ url: URL, at: Date) -> Past? {
        var cwd = ""
        for line in headLines(url, bytes: 64 << 10) {
            if let c = (json(line)?["cwd"] as? String), !c.isEmpty { cwd = c; break }
        }
        guard !cwd.isEmpty else { return nil }
        var title: String?, prompt: String?
        for line in tailLines(url, bytes: 256 << 10).reversed() where title == nil || prompt == nil {
            guard let e = json(line) else { continue }
            if title == nil, let t = (e["customTitle"] as? String) ?? (e["summary"] as? String), !t.isEmpty { title = t }
            if prompt == nil, let p = e["lastPrompt"] as? String, !p.isEmpty { prompt = clip120(p) }
        }
        return Past(id: url.deletingPathExtension().lastPathComponent, title: title ?? prompt ?? (cwd as NSString).lastPathComponent,
                    cwd: cwd, lastPrompt: prompt, lastAt: (at.timeIntervalSince1970 * 1000).rounded())
    }

    static func pastJSON(_ list: [Past]) -> String {
        String(decoding: (try? JSONEncoder().encode(["sessions": list])) ?? Data("{}".utf8), as: UTF8.self)
    }

    /// The first `bytes` of the file as whole JSON lines (the last, partial one dropped).
    static func headLines(_ url: URL, bytes: Int) -> [Data] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: bytes)) ?? Data()
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if data.count == bytes, !lines.isEmpty { lines.removeLast() }
        return lines.map { Data($0) }
    }

    /// A Claude Code session id, safe to put on a command line.
    static func isSessionID(_ s: String) -> Bool {
        (8...64).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func json(_ line: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] }
    private static func clip120(_ s: String) -> String {
        let one = s.split(whereSeparator: \.isNewline).joined(separator: " ")
        return one.count > 120 ? one.prefix(120) + "…" : one
    }

    // MARK: - images

    /// The image `key` ("<uuid>#<n>", as in the items) as a JPEG that fits a relay frame.
    static func image(in url: URL, key: String) -> Data? {
        let parts = key.split(separator: "#")
        guard parts.count == 2, let n = Int(parts[1]),
              let all = try? Data(contentsOf: url, options: .mappedIfSafe),
              let hit = all.range(of: Data("\"uuid\":\"\(parts[0])\"".utf8)) else { return nil }
        let start = all[..<hit.lowerBound].lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? all.startIndex
        let end = all[hit.upperBound...].firstIndex(of: UInt8(ascii: "\n")) ?? all.endIndex
        let line = Data(all[start..<end])
        let entry = items([line])
        guard n < entry.count, entry[n].k == "image",
              let e = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let b64 = images(in: e).dropFirst(entry.prefix(n).filter { $0.k == "image" }.count).first,
              let raw = Data(base64Encoded: b64) else { return nil }
        return jpeg(raw)
    }

    /// The base64 payloads of an entry's images, in item order.
    private static func images(in e: [String: Any]) -> [String] {
        let content = (e["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        return content.flatMap { b -> [[String: Any]] in
            if b["type"] as? String == "image" { return [b] }
            return (b["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "image" }
        }.compactMap { ($0["source"] as? [String: Any])?["data"] as? String }
    }

    /// Downscaled JPEG (≤ 1280 px, smaller until it fits a frame as base64).
    static func jpeg(_ raw: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(raw as CFData, nil) else { return nil }
        for (px, q) in [(1280, 0.7), (960, 0.6), (640, 0.5)] {
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceThumbnailMaxPixelSize: px,
                                         kCGImageSourceCreateThumbnailWithTransform: true]
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            let out = NSMutableData()
            guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
            guard CGImageDestinationFinalize(dst) else { return nil }
            if out.length * 4 / 3 < maxFrame - 1024 { return out as Data }
        }
        return nil
    }

    static func imageFrame(key: String, jpeg: Data?) -> String {
        struct Wire: Encodable { let t = "image"; let key: String; let mime = "image/jpeg"; let data: String? }
        let data = (try? JSONEncoder().encode(Wire(key: key, data: jpeg?.base64EncodedString()))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - text

    /// Assistant text without the voice plumbing: `<reply>` lines dropped, the final
    /// `<speak>` / `<speak-end>` line returned on its own.
    static func split(_ text: String) -> (body: String, spoken: String?) {
        var body = text.replacingOccurrences(of: #"(?m)^\s*<reply\b[^>]*>.*?</reply>\s*$\n?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<slide\b[^>]*>\s?"#, with: "", options: .regularExpression)
        var spoken: String?
        // The LAST tag, closed at the very end (or never): earlier mentions are prose.
        if let last = body.range(of: "<speak", options: .backwards),
           let r = body.range(of: #"<speak(?:-end)?>(?:(?!</speak)[\s\S])*(?:</speak(?:-end)?>)?\s*$"#,
                              options: .regularExpression, range: last.lowerBound..<body.endIndex) {
            spoken = String(body[r])
                .replacingOccurrences(of: #"</?speak(?:-end)?>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            body.removeSubrange(r)
        }
        return (body.trimmingCharacters(in: .whitespacesAndNewlines), spoken?.isEmpty == false ? spoken : nil)
    }

    /// A voice reply ("Stop hook feedback:\n…") without Parley's own notes; nil for other meta.
    static func voiceReply(_ s: String) -> String? {
        let prefix = "Stop hook feedback:\n"
        guard s.hasPrefix(prefix) else { return nil }
        let text = s.dropFirst(prefix.count).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("[Parley ") }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// What the user typed; slash commands as "/name args"; system-injected blocks dropped.
    static func userText(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name = tag("command-name", in: t) {
            let args = tag("command-args", in: t) ?? ""
            return args.isEmpty ? name : "\(name) \(args)"
        }
        return t.isEmpty || t.hasPrefix("<") ? nil : t
    }

    private static func tag(_ name: String, in s: String) -> String? {
        guard let r = s.range(of: "<\(name)>([\\s\\S]*?)</\(name)>", options: .regularExpression) else { return nil }
        return String(s[r]).replacingOccurrences(of: "</?\(name)>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Bash · git status" — the tool's short name and what it was for.
    static func tool(_ name: String, _ input: [String: Any]) -> String {
        let short = name.components(separatedBy: "__").last ?? name   // mcp__server__tool → tool
        let detail = ["description", "command", "file_path", "pattern", "url", "query", "action", "prompt"]
            .lazy.compactMap { input[$0] as? String }.first { !$0.isEmpty }
            .map { $0.hasPrefix("/") ? ($0 as NSString).lastPathComponent : $0 }
        guard let detail else { return short }
        let line = detail.split(separator: "\n").first.map(String.init) ?? detail
        return "\(short) · \(line.count > 90 ? line.prefix(90) + "…" : line)"
    }

    /// Lines a file tool added / removed (the phone's "+62 −0"), nil for other tools.
    static func diff(_ name: String, _ input: [String: Any]) -> (Int, Int)? {
        func lines(_ v: Any?) -> Int {
            guard let s = v as? String, !s.isEmpty else { return 0 }
            return s.split(separator: "\n", omittingEmptySubsequences: false).count - (s.hasSuffix("\n") ? 1 : 0)
        }
        switch name {
        case "Write": return (lines(input["content"]), 0)
        case "Edit": return (lines(input["new_string"]), lines(input["old_string"]))
        case "MultiEdit":
            let edits = input["edits"] as? [[String: Any]] ?? []
            return (edits.map { lines($0["new_string"]) }.reduce(0, +), edits.map { lines($0["old_string"]) }.reduce(0, +))
        default: return nil
        }
    }

    private static func clip(_ s: String) -> String { s.count > maxText ? s.prefix(maxText) + "…" : s }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
