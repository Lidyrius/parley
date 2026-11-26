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
    var focus: String?      // v12, image slides: "x,y,w,h" — the part to zoom to (fractions, or percent)
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
        var focus: [Double]?    // v12: [x, y, w, h], fractions of the image, origin top left
        var ref: String?        // v12: an earlier slide of this line with the same image (no own pixels)
    }

    /// "x,y,w,h" as fractions (or percent, when any value is above 1) → a rect inside the image;
    /// nil when it isn't four numbers or is too small to mean anything. Pure.
    static func focus(_ s: String?) -> [Double]? {
        guard let s else { return nil }
        var v = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard v.count == 4, v.allSatisfy({ $0 >= 0 }) else { return nil }
        if v.contains(where: { $0 > 1 }) { v = v.map { $0 / 100 } }
        let x = min(v[0], 1), y = min(v[1], 1)
        let w = min(v[2], 1 - x), h = min(v[3], 1 - y)
        guard w >= 0.02, h >= 0.02 else { return nil }
        return [x, y, w, h].map { ($0 * 1000).rounded() / 1000 }
    }

    /// The sharp close-up of a focus: the rect with a margin around it (the phone zooms a bit
    /// wider than the rect), still inside the image.
    static func closeUp(_ f: [Double]) -> CGRect {
        let m = 0.12 * max(f[2], f[3])
        let x = max(0, f[0] - m), y = max(0, f[1] - m)
        return CGRect(x: x, y: y, width: min(1, f[0] + f[2] + m) - x, height: min(1, f[1] + f[3] + m) - y)
    }

    /// The slides with their times (the start of the word each precedes; 0 without captions).
    static func items(_ specs: [SlideSpec], timed: Captions.Timed?, prefix: String) -> [Out] {
        var first: [String: String] = [:]   // image source → the first slide id showing it
        return specs.enumerated().map { n, s in
            let at = timed.map { s.word < $0.starts.count ? $0.starts[max(0, s.word)] : $0.end } ?? 0
            let kind = s.image != nil ? "image" : s.chart != nil ? "chart" : s.metric != nil ? "metric" : "text"
            let labels = s.labels.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            let values = s.values.map { $0.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
            let id = "\(prefix)-\(n)"
            var ref: String?
            if let img = s.image { if let earlier = first[img] { ref = earlier } else { first[img] = id } }
            return Out(id: id, at: (at * 100).rounded() / 100, kind: kind, title: s.title, text: s.text,
                       chart: kind == "chart" ? s.chart : nil, labels: labels, values: values, unit: s.unit,
                       metric: s.metric, note: s.note, focus: kind == "image" ? focus(s.focus) : nil, ref: ref)
        }
    }

    static func frame(_ items: [Out]) -> String {
        struct Wire: Encodable { let t = "slides"; let items: [Out] }
        return String(decoding: (try? JSONEncoder().encode(Wire(items: items))) ?? Data(), as: UTF8.self)
    }

    /// An image slide's pixels as a frame-sized JPEG: "last" / "last-N" = the N-th newest image
    /// in the session's transcript (screenshots Claude took), else an image file's path.
    /// `crop`: only that part, sharp (a zoomed slide's close-up).
    static func image(_ source: String, session: String, root: URL = Transcript.projects, crop: CGRect? = nil) -> Data? {
        raw(source, session: session, root: root).flatMap { Transcript.jpeg($0, crop: crop) }
    }

    static func raw(_ source: String, session: String, root: URL = Transcript.projects) -> Data? {
        if source == "last" || source.hasPrefix("last-") {
            let n = source == "last" ? 1 : Int(source.dropFirst(5)) ?? 1
            guard let url = Transcript.file(for: session, root: root),
                  let item = Transcript.parse(Transcript.tailLines(url)).filter({ $0.k == "image" }).dropLast(n - 1).last
            else { return nil }
            return Transcript.rawImage(in: url, key: item.id)
        }
        let url = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
        guard ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff"].contains(url.pathExtension.lowercased()),
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 30 << 20
        else { return nil }
        return try? Data(contentsOf: url)
    }

    /// The `image` frames for a line's slides: each image once (a `ref` slide has none), plus a
    /// sharp close-up `<id>.hd` for every focus. (key, source, crop) in send order.
    static func imageJobs(_ specs: [SlideSpec], _ items: [Out]) -> [(key: String, source: String, crop: CGRect?)] {
        zip(specs, items).flatMap { s, o -> [(key: String, source: String, crop: CGRect?)] in
            guard let src = s.image else { return [] }
            var jobs: [(key: String, source: String, crop: CGRect?)] = o.ref == nil ? [(o.id, src, nil)] : []
            if let f = o.focus { jobs.append((o.id + ".hd", src, closeUp(f))) }
            return jobs
        }
    }
}
