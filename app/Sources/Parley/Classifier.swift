import Foundation

// Intent of the user's spoken reply, used to pick a cached acknowledgement line.
// Includes two likely multi-intent combos (research-then-build, fix-and-extend).
enum Intent: String, CaseIterable {
    case feature         = "FEATURE"           // wants something built / added
    case bug             = "BUG"               // reports something broken / wants a fix
    case research        = "RESEARCH"          // look something up / investigate
    case question        = "QUESTION"          // asks a question expecting an answer
    case stop            = "STOP"              // pause / stop / wait
    case cont            = "CONTINUE"          // proceed / yes / go on
    case featureResearch = "FEATURE_RESEARCH"  // research, then build
    case bugFeature      = "BUG_FEATURE"       // fix and extend
    case other           = "OTHER"

    var folder: String { rawValue.lowercased() }

    // Order for keyword matching: combos + specific labels BEFORE their substrings
    // (so "FEATURE_RESEARCH" isn't matched as "FEATURE").
    static let matchOrder: [Intent] = [
        .featureResearch, .bugFeature, .question, .research, .feature, .bug, .stop, .cont,
    ]
}

// Classify the transcript via Groq (OpenAI-compatible chat). Fast + cheap; falls back
// to .other on any error. Only request construction + parsing are unit-tested.
enum Classifier {
    // ~0.2 s with reasoning off (every request sends `reasoning_effort: none`). Groq retires
    // models without notice — a 4xx here shows up in the log as "groq … http 400".
    static let model = "qwen/qwen3.8-27b"
    static let endpoint = "https://api.groq.com/openai/v1/chat/completions"

    private static let system = """
    You are an intent classifier for short messages a developer speaks to a coding \
    assistant. Reply with EXACTLY ONE label from this list, nothing else:
    FEATURE = wants something built or added.
    BUG = reports something broken or wants a fix.
    RESEARCH = wants you to look something up, investigate, or find out.
    QUESTION = phrased as a question / asks for information (was, wie, warum, wie viel, \
    ob, ...) and does NOT ask you to change code. Only use BUG for an actual defect/fix.
    STOP = wants you to pause, stop, or wait.
    CONTINUE = proceed / yes / go on / keep going.
    FEATURE_RESEARCH = wants you to research something AND then build a feature.
    BUG_FEATURE = wants a fix AND a new capability.
    OTHER = anything else or unclear.
    Use a combo label (FEATURE_RESEARCH, BUG_FEATURE) only when BOTH parts are clearly \
    present. Output only the label.
    """

    // Wait/pause extraction: if the user asks to wait a DURATION before continuing, returns
    // the total seconds; 0 otherwise. Language/format independent (handled by the model).
    private static let waitSystem = """
    The user speaks to a coding assistant. If they ask you to WAIT or PAUSE for a duration \
    before continuing (e.g. "warte 5 Minuten", "mach 10 Minuten Pause", "in einer halben \
    Stunde", "wait 30 seconds", "gib mir 2 Minuten"), output ONLY the total number of \
    SECONDS as a plain integer. If they are NOT asking to wait for a set duration, output 0. \
    Output only the integer, nothing else.
    """

    // Which predicted answer the transcript is: the 1-based option number, 0 = none fits.
    private static let replySystem = """
    A developer answered a coding assistant by voice. The assistant predicted these kinds of \
    answer, numbered. Output the number of the one closest in meaning — loose wording is fine. \
    Output 0 only if the answer means something none of them covers (e.g. a new request or \
    instruction). Output only the integer.
    """

    static func replyRequest(text: String, options: [String], apiKey: String) -> URLRequest {
        let list = options.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return chat(system: replySystem, user: "\(list)\n\nAnswer: \(text)", maxTokens: 4, apiKey: apiKey)
    }

    /// The matched option's index, nil when none (or out of range).
    static func parseReply(_ data: Data, count: Int) -> Int? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = (obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              let n = Int(((msg["content"] as? String) ?? "").filter(\.isNumber)), (1...count).contains(n) else { return nil }
        return n - 1
    }

    private static func chat(system: String, user: String, maxTokens: Int, apiKey: String) -> URLRequest {
        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model, "reasoning_effort": "none", "temperature": 0, "max_tokens": maxTokens,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    static func waitRequest(text: String, apiKey: String) -> URLRequest {
        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model, "reasoning_effort": "none", "temperature": 0, "max_tokens": 8,
            "messages": [["role": "system", "content": waitSystem], ["role": "user", "content": text]],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Parse the wait response → seconds (clamped 0…3600; a lone tiny value is ignored).
    static func parseWait(_ data: Data) -> Int {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else { return 0 }
        let digits = content.filter(\.isNumber)
        let n = Int(digits) ?? 0
        return n < 5 ? 0 : min(3600, n)
    }

    static func request(text: String, apiKey: String) -> URLRequest {
        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "reasoning_effort": "none",
            "temperature": 0,
            "max_tokens": 4,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": text],
            ],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Parse the OpenAI-compatible response → Intent (first matching keyword; .other fallback).
    static func parse(_ data: Data) -> Intent {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else { return .other }
        let up = content.uppercased()
        for i in Intent.matchOrder where up.contains(i.rawValue) { return i }
        return .other
    }
}
