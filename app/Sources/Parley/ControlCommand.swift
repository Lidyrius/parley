import Foundation

// Detects whether a spoken reply is a Parley CONTROL command — resuming a paused
// (parked) session by voice — rather than a normal reply to the current session. Only
// called when paused sessions exist, so it can never hijack an ordinary reply otherwise.
enum ControlCommand {
    struct Result { let resume: Bool; let target: String; let instruction: String }

    static func detect(_ text: String, labels: [String], config: AppConfig) async -> Result? {
        guard !config.groqKey.isEmpty, !labels.isEmpty else { return nil }
        let sys = """
        You route a spoken utterance in a voice coding assistant. Some projects are PAUSED \
        and can be resumed by voice. Paused projects: \(labels.joined(separator: ", ")).
        If the user asks to RESUME / continue / wake / pick up one of these PAUSED projects, \
        reply with JSON {"resume":true,"target":"<exact paused project name from the list>",\
        "instruction":"<what they want that project to do next, or empty string>"}. The \
        target MUST be one of the paused project names. If the utterance is just a normal \
        reply to the CURRENT session and not about resuming a paused project, reply \
        {"resume":false,"target":"","instruction":""}. Output ONLY the JSON object.
        """
        var req = URLRequest(url: URL(string: Classifier.endpoint)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(config.groqKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": Classifier.model,
            "temperature": 0,
            "max_tokens": 160,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": sys],
                ["role": "user", "content": text],
            ],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String,
              let cdata = content.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: cdata) as? [String: Any]
        else { return nil }
        return Result(resume: (parsed["resume"] as? Bool) ?? false,
                      target: (parsed["target"] as? String) ?? "",
                      instruction: (parsed["instruction"] as? String) ?? "")
    }
}
