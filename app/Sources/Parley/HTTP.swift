import Foundation

// Minimal HTTP/1.1 request parsing for the loopback control server. Just enough
// to route POST bodies from the hook — no keep-alive, no chunked encoding.

struct HTTPRequest: Equatable {
    var method: String
    var path: String
    var body: Data
}

enum HTTPParse {
    /// Returns the parsed request once headers + full body are present, or nil if
    /// more bytes are still needed. Returns .some(nil) is not modelled — callers
    /// keep reading until this yields a request.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let sep = range(of: [0x0d, 0x0a, 0x0d, 0x0a], in: data) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<sep.lowerBound)
        guard let header = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])

        var contentLength = 0
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = sep.upperBound
        let available = data.distance(from: bodyStart, to: data.endIndex)
        guard available >= contentLength else { return nil }
        let body = data.subdata(in: bodyStart..<data.index(bodyStart, offsetBy: contentLength))
        return HTTPRequest(method: method, path: path, body: body)
    }

    static func response(status: Int, json: String) -> Data {
        let reason = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Bad Request")
        let bodyBytes = Array(json.utf8)
        let head = "HTTP/1.1 \(status) \(reason)\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(bodyBytes.count)\r\n" +
            "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(contentsOf: bodyBytes)
        return out
    }

    // Byte-sequence search over Data (Foundation's range(of:) on Data works but
    // this keeps intent explicit and index-safe on subdata slices).
    private static func range(of needle: [UInt8], in data: Data) -> Range<Data.Index>? {
        guard !needle.isEmpty, data.count >= needle.count else { return nil }
        let bytes = [UInt8](data)
        let limit = bytes.count - needle.count
        var i = 0
        while i <= limit {
            if Array(bytes[i..<i+needle.count]) == needle {
                let lower = data.index(data.startIndex, offsetBy: i)
                let upper = data.index(lower, offsetBy: needle.count)
                return lower..<upper
            }
            i += 1
        }
        return nil
    }
}
