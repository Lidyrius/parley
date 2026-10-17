import Foundation

// A colour palette for the iPhone app, made by voice: Sir asks ("eine Palette im Apple-Design"),
// the Zentrale researches it and POSTs it here; the phone gets it as a `palette` frame, saves it
// under "Eigene" and switches to it. Roles as the app's Palette (ios/ParleyMobile/Theme.swift).
//
// POST /palette {"name","note"?,"alwaysDark"?,"colors":{role: "#RRGGBB" | ["#light","#dark"]}}
enum PaletteSpec {
    static let roles = ["background", "card", "raised", "accent", "waiting", "working", "purple", "idle", "stopped", "red"]

    enum Problem: Error, Equatable { case notJSON, noName, colors(missing: [String], invalid: [String]) }

    /// The body → the phone's frame (keys sorted, colours as "#RRGGBB" pairs), or what is wrong.
    static func frame(_ body: Data) -> Result<(name: String, frame: String), Problem> {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return .failure(.notJSON) }
        let name = (obj["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.noName) }
        let given = obj["colors"] as? [String: Any] ?? [:]
        var colors: [String: [String]] = [:], missing: [String] = [], invalid: [String] = []
        for role in roles {
            guard let v = given[role] else { missing.append(role); continue }
            let pair = (v as? String).map { [$0, $0] } ?? (v as? [String]).map { $0.count == 1 ? [$0[0], $0[0]] : $0 }
            guard let pair, pair.count == 2, let l = hex(pair[0]), let d = hex(pair[1]) else { invalid.append(role); continue }
            colors[role] = [l, d]
        }
        guard missing.isEmpty, invalid.isEmpty else { return .failure(.colors(missing: missing, invalid: invalid)) }
        struct Wire: Encodable {
            let t = "palette"
            let name: String
            let note: String
            let alwaysDark: Bool
            let colors: [String: [String]]
        }
        let wire = Wire(name: String(name.prefix(40)),
                        note: String((obj["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)),
                        alwaysDark: obj["alwaysDark"] as? Bool ?? false, colors: colors)
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let text = (try? enc.encode(wire)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return .success((wire.name, text))
    }

    /// "#a1b2c3" / "A1B2C3" → "#A1B2C3"; nil for anything else.
    static func hex(_ s: String) -> String? {
        let h = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard h.count == 6, h.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + h.uppercased()
    }

    static func message(_ p: Problem) -> String {
        switch p {
        case .notJSON: "body must be a JSON object"
        case .noName: "name is missing"
        case .colors(let missing, let invalid):
            ([missing.isEmpty ? nil : "missing: " + missing.joined(separator: ", "),
              invalid.isEmpty ? nil : "not #RRGGBB or [light, dark]: " + invalid.joined(separator: ", ")]
                .compactMap { $0 }.joined(separator: "; "))
        }
    }
}
