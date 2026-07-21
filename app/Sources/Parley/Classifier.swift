import Foundation

// Intent of the user's spoken reply, used to pick a cached acknowledgement line.
enum Intent: String, CaseIterable {
    case feature = "FEATURE"    // wants something built / added
    case bug     = "BUG"        // reports something broken / wants a fix
    case stop    = "STOP"       // wants us to pause / stop / wait
    case cont    = "CONTINUE"   // proceed / yes / go on
    case other   = "OTHER"      // anything else / unclear

    var folder: String { rawValue.lowercased() }
}

// Classify the transcript via Groq (OpenAI-compatible chat). Fast + cheap; falls back
// to .other on any error. Only request construction + parsing are unit-tested.
enum Classifier {
    static let model = "llama-3.1-8b-instant"
    static let endpoint = "https://api.groq.com/openai/v1/chat/completions"

    private static let system = """
    You are an intent classifier for short messages a developer speaks to a coding \
    assistant. Reply with EXACTLY ONE word, one of: FEATURE, BUG, STOP, CONTINUE, OTHER.
    FEATURE = wants something built or added. BUG = reports something broken or wants a \
    fix. STOP = wants the assistant to pause, stop, or wait. CONTINUE = says to proceed / \
    yes / go on / keep going. OTHER = anything else or unclear. Output only the word.
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
        // Check the specific ones before OTHER so "OTHER" isn't shadowed.
        for i in [Intent.feature, .bug, .stop, .cont] where up.contains(i.rawValue) { return i }
        return .other
    }
}
