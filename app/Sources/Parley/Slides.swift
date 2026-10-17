import Foundation

// Slides in a call (docs/CALL-SLIDES.md): `<slide …/>` markers in the spoken line (the Stop hook
// strips them and keeps the word each precedes). Each slide shows when that word is spoken —
// the caption times — so the phone needs one `slides` frame per line and the images as `image`
// frames keyed by slide id. Kinds: image (the session's last screenshot, or a file), chart
// (bar / line / pie), metric (a big number), text (a short card).
struct SlideSpec: Codable, Equatable {
    var word: Int
    var image: String?      // "last", "last-2", or an image file path
    var chart: String?      // "bar" | "line" | "pie"
    var labels: String?     // "Mo,Di,Mi"
    var values: String?     // "3,5.5,2" (dot decimals)
    var metric: String?     // "98 %"
    var text: String?
    var title: String?
    var unit: String?
    var note: String?
}

enum Slides {
    struct Out: Encodable, Equatable {
        var id: String
        var at: Double
        var kind: String
        var title: String?
        var text: String?
        var chart: String?
        var labels: [String]?
        var values: [Double]?
        var unit: String?
        var metric: String?
        var note: String?
    }

    /// The slides with their times (the start of the word each precedes; 0 without captions).
    static func items(_ specs: [SlideSpec], timed: Captions.Timed?, prefix: String) -> [Out] {
        specs.enumerated().map { n, s in
            let at = timed.map { s.word < $0.starts.count ? $0.starts[max(0, s.word)] : $0.end } ?? 0
            let kind = s.image != nil ? "image" : s.chart != nil ? "chart" : s.metric != nil ? "metric" : "text"
            let labels = s.labels.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            let values = s.values.map { $0.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
            return Out(id: "\(prefix)-\(n)", at: (at * 100).rounded() / 100, kind: kind, title: s.title, text: s.text,
                       chart: kind == "chart" ? s.chart : nil, labels: labels, values: values, unit: s.unit,
                       metric: s.metric, note: s.note)
        }
    }

    static func frame(_ items: [Out]) -> String {
        struct Wire: Encodable { let t = "slides"; let items: [Out] }
        return String(decoding: (try? JSONEncoder().encode(Wire(items: items))) ?? Data(), as: UTF8.self)
    }

    /// An image slide's pixels as a frame-sized JPEG: "last" / "last-N" = the N-th newest image
    /// in the session's transcript (screenshots Claude took), else an image file's path.
    static func image(_ source: String, session: String, root: URL = Transcript.projects) -> Data? {
        if source == "last" || source.hasPrefix("last-") {
            let n = source == "last" ? 1 : Int(source.dropFirst(5)) ?? 1
            guard let url = Transcript.file(for: session, root: root),
                  let item = Transcript.parse(Transcript.tailLines(url)).filter({ $0.k == "image" }).dropLast(n - 1).last
            else { return nil }
            return Transcript.image(in: url, key: item.id)
        }
        let url = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
        guard ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff"].contains(url.pathExtension.lowercased()),
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 30 << 20,
              let raw = try? Data(contentsOf: url) else { return nil }
        return Transcript.jpeg(raw)
    }
}
