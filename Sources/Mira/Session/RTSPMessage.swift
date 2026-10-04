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

    var method: String? {
        if case .request(let m, _) = kind { return m }
        return nil
    }

    var statusCode: Int? {
        if case .response(let c, _) = kind { return c }
        return nil
    }

    // Session header without attributes such as ";timeout=30".
    var sessionID: String? {
        header("Session")?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Framing

    private static let headerTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A])

    // Removes one complete message (headers + Content-Length body) from the front of
    // `buffer`. Returns nil if the buffer does not yet hold a complete message.
    static func extract(from buffer: inout Data) -> RTSPMessage? {
        guard let range = buffer.range(of: headerTerminator) else { return nil }
        let headerText = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
        let contentLength = headerText.components(separatedBy: "\r\n").lazy
            .compactMap { line -> Int? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                guard line[..<colon].trimmingCharacters(in: .whitespaces)
                        .caseInsensitiveCompare("Content-Length") == .orderedSame else { return nil }
                return Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }.first ?? 0

        let total = (range.upperBound - buffer.startIndex) + contentLength
        guard buffer.count >= total else { return nil }

        let msgData = Data(buffer.prefix(total))
        buffer = Data(buffer.dropFirst(total))
        return parse(from: msgData)
    }

    // MARK: - Parse

    static func parse(from data: Data) -> RTSPMessage? {
        guard let boundary = data.range(of: headerTerminator) else { return nil }
        guard let headerText = String(data: data[data.startIndex..<boundary.lowerBound], encoding: .utf8) else { return nil }

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
            kind = .request(method: parts[0], uri: parts[1])
        }

        var headers: [(String, String)] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }

        var body: String? = nil
        let contentLength = headers
            .first { $0.0.caseInsensitiveCompare("Content-Length") == .orderedSame }
            .flatMap { Int($0.1) } ?? 0

        if contentLength > 0 {
            let bodyStart = boundary.upperBound
            let bodyEnd = bodyStart + contentLength
            if data.endIndex >= bodyEnd {
                body = String(decoding: data[bodyStart..<bodyEnd], as: UTF8.self)
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
        for (name, value) in headers where name.caseInsensitiveCompare("Content-Length") != .orderedSame {
            text += "\(name): \(value)\r\n"
        }
        if let body = body, !body.isEmpty {
            text += "Content-Length: \(body.utf8.count)\r\n"
            text += "\r\n"
            text += body
        } else {
            text += "\r\n"
        }
        return Data(text.utf8)
    }

    // MARK: - Factories

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()

    static func response(_ code: Int, _ reason: String, cseq: Int,
                         extra: [(String, String)] = [], body: String? = nil) -> RTSPMessage {
        var h: [(String, String)] = [("CSeq", "\(cseq)"), ("Date", dateFormatter.string(from: Date()))]
        h.append(contentsOf: extra)
        if let body, !body.isEmpty { h.append(("Content-Type", "text/parameters")) }
        return RTSPMessage(kind: .response(statusCode: code, reason: reason), headers: h, body: body)
    }

    static func ok(cseq: Int, extra: [(String, String)] = [], body: String? = nil) -> RTSPMessage {
        response(200, "OK", cseq: cseq, extra: extra, body: body)
    }

    static func request(method: String, uri: String, cseq: Int, extra: [(String, String)] = [], body: String? = nil) -> RTSPMessage {
        var h: [(String, String)] = [("CSeq", "\(cseq)")]
        h.append(contentsOf: extra)
        if let body = body, !body.isEmpty {
            h.append(("Content-Type", "text/parameters"))
        }
        return RTSPMessage(kind: .request(method: method, uri: uri), headers: h, body: body)
    }

    var summary: String {
        switch kind {
        case .request(let m, let u):
            let params = body.map { " [" + WFDParameters.names(in: $0).joined(separator: ", ") + "]" } ?? ""
            return "\(m) \(u) (CSeq \(cseq ?? -1))\(params)"
        case .response(let c, let r):
            return "\(c) \(r) (CSeq \(cseq ?? -1))"
        }
    }

    var fullText: String { String(decoding: serialize(), as: UTF8.self) }
}
