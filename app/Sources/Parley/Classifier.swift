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
    static let model = "llama-3.3-70b-versatile"   // more accurate on combos/questions, still ~0.3s
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

    static func request(text: String, apiKey: String) -> URLRequest {
        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
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
