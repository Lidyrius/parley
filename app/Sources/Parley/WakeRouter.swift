import Foundation

// "Hey Parley" → greeting → listen → route (docs/IPHONE.md, protocol v2): where an utterance
// goes — a running session the user names (or clearly means), else the Zentrale. Groq's LLM
// picks among the labels; a label substring match is the fallback.

struct RouteTarget: Equatable, Sendable {
    var id: String?      // session id; nil = the Zentrale
    var label: String

    static let zentrale = RouteTarget(id: nil, label: Zentrale.label)
}

enum WakeRouter {
    static func request(text: String, labels: [String], apiKey: String) -> URLRequest {
        let sessions = labels.filter { $0.caseInsensitiveCompare(Zentrale.label) != .orderedSame }
        let sys = """
        You route a spoken request in a voice coding assistant. Running sessions, by their spoken \
        names: \(sessions.isEmpty ? "(none)" : sessions.joined(separator: ", ")). Also available: \
        "\(Zentrale.label)", the general assistant — new projects, finding projects, starting \
        sessions, general questions, and anything not clearly meant for one running session. If \
        the utterance names one of the running sessions or is clearly about its project, the \
        target is that session's name; otherwise "\(Zentrale.label)". Reply ONLY with JSON \
        {"target":"<exact name from the list, or \(Zentrale.label)>"}.
        """
        var req = URLRequest(url: URL(string: Classifier.endpoint)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": Classifier.model, "reasoning_effort": "none", "temperature": 0, "max_tokens": 60,
            "response_format": ["type": "json_object"],
            "messages": [["role": "system", "content": sys], ["role": "user", "content": text]],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// The LLM's pick (OpenAI-compatible response, content {"target":"…"}) as one of `labels`;
    /// nil when the response is broken or names none of them.
    static func parse(_ data: Data, labels: [String]) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String,
              let parsed = (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any],
              let target = parsed["target"] as? String else { return nil }
        let t = fold(target)
        guard !t.isEmpty else { return nil }
        return labels.first { fold($0) == t } ?? labels.first { let l = fold($0); return !l.isEmpty && (l.contains(t) || t.contains(l)) }
    }

    /// The label the utterance names — case, accents, spaces and hyphens ignored ("Tipp-Frei"
    /// finds "Tippfrei"); the longest wins. Labels under 3 letters never match.
    static func substring(_ text: String, labels: [String]) -> String? {
        let t = squash(text)
        return labels.filter { let l = squash($0); return l.count >= 3 && t.contains(l) }
            .max { squash($0).count < squash($1).count }
    }

    /// Where `text` goes. `ask` performs the LLM call (nil on any failure); no key → fallback only.
    static func route(_ text: String, sessions: [RouteTarget], apiKey: String,
                      ask: @Sendable (URLRequest) async -> Data?) async -> RouteTarget {
        let labels = sessions.map(\.label) + [Zentrale.label]
        func target(_ label: String) -> RouteTarget {
            sessions.first { $0.label == label } ?? .zentrale
        }
        if !apiKey.isEmpty, let data = await ask(request(text: text, labels: labels, apiKey: apiKey)),
           let label = parse(data, labels: labels) {
            return target(label)
        }
        return substring(text, labels: labels).map(target) ?? .zentrale
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func squash(_ s: String) -> String {
        String(fold(s).unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }
}
