import Foundation

// Permission prompts aloud (docs/IPHONE.md, stage 5): the plugin's PermissionRequest hook
// long-polls POST /permission; Parley asks "<Projekt> möchte <…> — erlauben?", listens, and
// answers allow / deny / ask by simple keyword rules.

enum PermissionDecision: String, Equatable, Sendable {
    case allow, deny, ask
    var json: String { #"{"decision":"\#(rawValue)"}"# }
}

// POST /permission {"session_id","cwd","tool_name","tool_input"}; tool_input keeps its top-level
// string fields (all a spoken description needs).
struct PermissionRequest: Equatable {
    var sessionId: String
    var cwd: String
    var toolName: String
    var input: [String: String]

    static func decode(_ body: Data) -> PermissionRequest? {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let sid = obj["session_id"] as? String, !sid.isEmpty,
              let tool = obj["tool_name"] as? String, !tool.isEmpty else { return nil }
        let raw = obj["tool_input"] as? [String: Any] ?? [:]
        return PermissionRequest(sessionId: sid, cwd: obj["cwd"] as? String ?? "", toolName: tool,
                                 input: raw.compactMapValues { $0 as? String })
    }
}

enum PermissionPrompt {
    /// "Tippfrei möchte den Befehl npm test ausführen — erlauben?"
    static func question(label: String, tool: String, input: [String: String]) -> String {
        "\(label.isEmpty ? "Eine Sitzung" : label) möchte \(describe(tool: tool, input: input)) — erlauben?"
    }

    /// What the tool call does, as a short German infinitive phrase.
    static func describe(tool: String, input: [String: String]) -> String {
        func file(_ key: String) -> String? {
            input[key].map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch tool {
        case "Bash":
            guard let cmd = input["command"].map(short), !cmd.isEmpty else { return "einen Befehl ausführen" }
            return "den Befehl \(cmd) ausführen"
        case "Edit", "MultiEdit":
            return file("file_path").map { "die Datei \($0) ändern" } ?? "eine Datei ändern"
        case "Write":
            return file("file_path").map { "die Datei \($0) schreiben" } ?? "eine Datei schreiben"
        case "NotebookEdit":
            return file("notebook_path").map { "das Notebook \($0) ändern" } ?? "ein Notebook ändern"
        case "Read":
            return file("file_path").map { "die Datei \($0) lesen" } ?? "eine Datei lesen"
        case "WebFetch":
            return input["url"].flatMap { URL(string: $0)?.host }.map { "die Seite \($0) abrufen" } ?? "eine Webseite abrufen"
        case "WebSearch":
            return input["query"].map(short).map { "im Web nach \($0) suchen" } ?? "im Web suchen"
        case "Glob", "Grep":
            return input["pattern"].map(short).map { "nach \($0) suchen" } ?? "Dateien durchsuchen"
        case "Task", "Agent":
            return input["description"].map(short).map { "einen Agenten starten: \($0)" } ?? "einen Agenten starten"
        default:
            let parts = tool.components(separatedBy: "__")
            if parts.count >= 3, parts[0] == "mcp" {
                let name = parts[2...].joined(separator: " ").replacingOccurrences(of: "_", with: " ")
                return "das Werkzeug \(name) von \(parts[1].replacingOccurrences(of: "_", with: " ")) benutzen"
            }
            return "das Werkzeug \(tool) benutzen"
        }
    }

    // First line, whitespace collapsed, at most ~80 characters (cut at a word).
    private static func short(_ s: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let flat = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > 80 else { return flat }
        let cut = String(flat.prefix(80))
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? cut) + " …"
    }

    // MARK: - the spoken answer

    // Order: an unclear phrase is set aside first (so "weiß nicht" is no "nicht"), then the
    // set phrases, then single words. Any no wins (refusing is the safe side); unclear (or a
    // reply that opens with a question word) beats yes; nothing recognised → ask (the normal
    // on-screen prompt).
    private static let unclearPhrases = ["weiß nicht", "weiss nicht", "keine ahnung", "kommt drauf an", "vielleicht",
                                         "i dont know", "not sure", "maybe", "egal"]
    private static let denyPhrases = ["auf keinen fall", "lieber nicht", "besser nicht", "bloß nicht", "bloss nicht"]
    private static let allowPhrases = ["kein problem", "no problem", "warum nicht", "why not", "auf jeden fall",
                                       "nur zu", "gib frei", "leg los", "do it", "go ahead"]
    private static let denyWords: Set<String> = [
        "nein", "nee", "nö", "noe", "nope", "no", "nicht", "nichts", "kein", "keine", "keinen", "stopp", "stop",
        "abbrechen", "abbruch", "abgelehnt", "verboten", "cancel", "deny", "denied", "dont",
    ]
    private static let denyPrefixes = ["verbiet", "verweiger", "ablehn"]
    private static let allowWords: Set<String> = [
        "ja", "jaa", "jo", "jup", "jep", "jap", "jawohl", "yes", "yeah", "yep", "yup", "ok", "okay", "okey", "oke",
        "klar", "mach", "machs", "mache", "macht", "los", "passt", "gern", "gerne", "einverstanden", "natürlich",
        "natuerlich", "sicher", "sure", "allow", "approve", "approved", "go", "genau", "richtig", "absolut",
        "selbstverständlich", "logo", "korrekt",
    ]
    private static let allowPrefixes = ["erlaub", "genehmig", "freigeb"]
    // A reply that opens with a question ("Was genau?", "Wie bitte?") is no yes.
    private static let questionWords: Set<String> = ["was", "wie", "wieso", "warum", "weshalb", "welche", "welcher",
                                                     "welches", "wer", "wo", "wohin", "what", "why", "how", "which"]

    static func decide(_ transcript: String) -> PermissionDecision {
        var t = " " + normalize(transcript) + " "
        func take(_ phrases: [String]) -> Bool {
            var hit = false
            for p in phrases where t.contains(" \(p) ") {
                hit = true
                t = t.replacingOccurrences(of: " \(p) ", with: " ")
            }
            return hit
        }
        var unclear = take(unclearPhrases)
        var deny = take(denyPhrases)
        var allow = take(allowPhrases)
        let words = t.split(separator: " ").map(String.init)
        if let first = words.first, questionWords.contains(first) { unclear = true }
        if words == ["halt"] { deny = true }   // "halt" alone; "mach halt" is a yes
        for w in words {
            if denyWords.contains(w) || denyPrefixes.contains(where: w.hasPrefix) { deny = true }
            if allowWords.contains(w) || allowPrefixes.contains(where: w.hasPrefix) { allow = true }
        }
        if deny { return .deny }
        if unclear { return .ask }
        return allow ? .allow : .ask
    }

    // Lowercase, apostrophes dropped ("mach's" → "machs"), everything but letters/digits a space.
    private static func normalize(_ s: String) -> String {
        let lower = s.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
        let spaced = String(lower.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return spaced.split(separator: " ").joined(separator: " ")
    }
}
