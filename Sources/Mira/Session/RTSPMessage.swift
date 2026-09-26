import Foundation

struct RTSPMessage {
    enum Kind {
        case request(method: String, uri: String)
        case response(statusCode: Int, reason: String)
    }

    var kind: Kind
    var headers: [(name: String, value: String)]
    var body: String?

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var cseq: Int? { header("CSeq").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }

    // MARK: - Parse

    static func parse(from data: Data) -> RTSPMessage? {
        // Find header/body boundary
        let crlf2 = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let boundary = data.range(of: crlf2) else { return nil }
        guard let headerText = String(data: data.prefix(boundary.lowerBound), encoding: .utf8) else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let firstLine = lines.first, !firstLine.isEmpty else { return nil }
        lines.removeFirst()

        let kind: Kind
        let parts = firstLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        if parts[0].hasPrefix("RTSP/") {
            let code = Int(parts[1]) ?? 0
            let reason = parts.count > 2 ? parts[2] : ""
            kind = .response(statusCode: code, reason: reason)
        } else {
            let uri = parts.count > 1 ? parts[1] : "*"
            kind = .request(method: parts[0], uri: uri)
        }

        var headers: [(String, String)] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }

        // Extract body using Content-Length
        var body: String? = nil
        let contentLength = headers
            .first { $0.0.caseInsensitiveCompare("Content-Length") == .orderedSame }
            .flatMap { Int($0.1.trimmingCharacters(in: .whitespaces)) } ?? 0

        if contentLength > 0 {
            let bodyStart = boundary.upperBound
            let bodyEnd = bodyStart + contentLength
            if data.count >= bodyEnd {
                body = String(data: data[bodyStart..<bodyEnd], encoding: .utf8)
            }
        }

        return RTSPMessage(kind: kind, headers: headers, body: body)
    }

    // MARK: - Serialize

    func serialize() -> Data {
        var text = ""
        switch kind {
        case .request(let method, let uri):
            text += "\(method) \(uri) RTSP/1.0\r\n"
        case .response(let code, let reason):
            text += "RTSP/1.0 \(code) \(reason)\r\n"
        }
        for (name, value) in headers {
            text += "\(name): \(value)\r\n"
        }
        if let body = body, !body.isEmpty {
            text += "Content-Length: \(body.utf8.count)\r\n"
            text += "\r\n"
            text += body
        } else {
            text += "\r\n"
        }
        return text.data(using: .utf8) ?? Data()
    }

    // MARK: - Factories

    static func ok(cseq: Int, extra: [(String, String)] = [], body: String? = nil) -> RTSPMessage {
        var h: [(String, String)] = [("CSeq", "\(cseq)")]
        h.append(contentsOf: extra)
        return RTSPMessage(kind: .response(statusCode: 200, reason: "OK"), headers: h, body: body)
    }

    static func request(method: String, uri: String, cseq: Int, extra: [(String, String)] = [], body: String? = nil) -> RTSPMessage {
        var h: [(String, String)] = [("CSeq", "\(cseq)")]
        h.append(contentsOf: extra)
        if let body = body, !body.isEmpty {
            h.append(("Content-Type", "text/parameters"))
        }
        return RTSPMessage(kind: .request(method: method, uri: uri), headers: h, body: body)
    }

    var debugDescription: String {
        switch kind {
        case .request(let m, let u): return "\(m) \(u)"
        case .response(let c, let r): return "\(c) \(r)"
        }
    }
}
