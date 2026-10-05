import Foundation
import Network

// Hotel / venue casting systems put the room TVs behind a gateway that advertises
// them (often all on one address, on ports other than 8009) and refuses connections
// until a device is "paired" with the room: the TV shows a code or a QR code with a
// link like http://<gateway>/pair?pairCode=7F6GY, which has to be opened *on the
// device that wants to cast*.
//
// CastPairing does that from the Mac:
//   link -> fetched in the background; if that alone doesn't unlock the gateway, it
//           is opened in the browser so the user can finish (consent pages, buttons)
//   code -> the gateway's web page is searched for a pairing form, which is filled
//           in and submitted; otherwise known link patterns are tried; as a last
//           resort the gateway page is opened in the browser
// and then waits until the gateway lets the Mac through.
final class CastPairing: @unchecked Sendable {

    enum Input: Equatable {
        case link(URL)
        case code(String)
    }

    enum PairingError: LocalizedError, Equatable {
        case invalidInput
        case notUnlocked

        var errorDescription: String? {
            switch self {
            case .invalidInput:
                return "That doesn't look like a pairing code or link. Enter the code shown on the TV (like 7F6GY) or the link from its QR code."
            case .notUnlocked:
                return "The TV's casting system still doesn't let this Mac connect. Finish the pairing in the browser page Mira opened (or open the link from the TV's QR code on this Mac), then connect again."
            }
        }
    }

    // A Cast device on a port other than 8009 is almost always behind such a gateway.
    static func isBehindGateway(_ device: MiracastDevice) -> Bool {
        device.kind == .googleCast && device.port != CastChannel.defaultPort
    }

    // Text from the user or a QR code -> link or code.
    static func parse(_ text: String) -> Input? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.contains("://"), let url = URL(string: t), url.host != nil, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return .link(url)
        }
        // "172.20.0.8/pair?pairCode=7F6GY" or "hotel.example/pair?..." without a scheme.
        if t.contains("/"), !t.contains(" "), let url = URL(string: "http://" + t), let host = url.host, host.contains(".") {
            return .link(url)
        }
        let code = t.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        guard (3...16).contains(code.count), code.allSatisfy({ $0.isLetter || $0.isNumber }), code.allSatisfy(\.isASCII) else {
            return nil
        }
        return .code(code)
    }

    let gatewayHost: String
    let devicePort: UInt16
    var openInBrowser: (URL) -> Void = { _ in }
    var progress: (String) -> Void = { _ in }

    private let session: URLSession

    init(gatewayHost: String, devicePort: UInt16) {
        self.gatewayHost = gatewayHost
        self.devicePort = devicePort
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.httpCookieStorage = HTTPCookieStorage()      // keep a session cookie across steps
        config.httpCookieAcceptPolicy = .always
        session = URLSession(configuration: config)
    }

    // Runs the whole pairing; `completion` is called once the gateway accepts the Mac
    // (success), or after `waitAfterBrowser` seconds of waiting for the user.
    func pair(_ input: Input, waitAfterBrowser: TimeInterval = 120, completion: @escaping (Result<Void, Error>) -> Void) {
        Task {
            do {
                try await run(input, waitAfterBrowser: waitAfterBrowser)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func run(_ input: Input, waitAfterBrowser: TimeInterval) async throws {
        if await reachable(timeout: 2) {
            Log.info("Cast", "The casting gateway already accepts this Mac")
            return
        }
        let browserURL: URL
        switch input {
        case .link(let url):
            progress("Pairing with the link from the TV...")
            Log.info("Cast", "Pairing: opening \(Self.redacted(url)) in the background")
            let page = try? await fetch(url)
            if await reachable(timeout: 4) { return }
            if let page, try await submitPairingForm(in: page, code: nil) { return }
            browserURL = url
        case .code(let code):
            progress("Looking for the TV's pairing page...")
            if try await pairWithCode(code) { return }
            browserURL = URL(string: webBase + "/")!
        }
        // The page wants a person (terms to accept, a button, a captcha...).
        progress("Finish the pairing in the browser window - Mira connects as soon as it's done")
        Log.info("Cast", "Pairing: opening the page in the browser for the user to finish")
        let open = openInBrowser
        await MainActor.run { open(browserURL) }
        let deadline = Date().addingTimeInterval(waitAfterBrowser)
        while Date() < deadline {
            if await reachable(timeout: 2) { return }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw PairingError.notUnlocked
    }

    // MARK: - Code: forms first, then known link patterns

    // The gateway's web server (port 80; MIRA_GATEWAY_WEB_PORT overrides it for tests).
    var webBase: String {
        "http://\(gatewayHost)" + (ProcessInfo.processInfo.environment["MIRA_GATEWAY_WEB_PORT"].map { ":" + $0 } ?? "")
    }

    private func pairWithCode(_ code: String) async throws -> Bool {
        let base = webBase
        for path in ["/", "/pair", "/pairing"] {
            guard let url = URL(string: base + path), let page = try? await fetch(url) else { continue }
            if try await submitPairingForm(in: page, code: code) { return true }
        }
        let escaped = code.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? code
        for pattern in ["/pair?pairCode=", "/pair?code=", "/pair?pin=", "/?pairCode=", "/pair/"] {
            guard let url = URL(string: base + pattern + escaped) else { continue }
            Log.info("Cast", "Pairing: trying \(pattern)<code>")
            guard let page = try? await fetch(url), page.status < 400 else { continue }
            if await reachable(timeout: 3) { return true }
            if try await submitPairingForm(in: page, code: code) { return true }
        }
        return false
    }

    // Fills in and submits a pairing form on `page`: the code goes into the text field
    // (preferring one named like code/pin/pair), hidden fields are kept. A form that
    // needs a person (checkboxes such as "accept terms", passwords) is left to the user.
    private func submitPairingForm(in page: Page, code: String?) async throws -> Bool {
        for form in HTMLForm.parse(page.html, base: page.url) {
            guard form.needsPerson == false else { continue }
            var fields = form.hidden
            if let code {
                guard let field = form.codeField else { continue }
                fields.append((field, code))
            } else if !form.textFields.isEmpty {
                continue    // a form asking for something we don't have
            }
            for (name, value) in form.submitValues { fields.append((name, value)) }
            Log.info("Cast", "Pairing: submitting the form at \(Self.redacted(form.action)) (\(form.method))")
            _ = try? await submit(form, fields: fields)
            if await reachable(timeout: 4) { return true }
        }
        return false
    }

    // MARK: - HTTP

    struct Page {
        var url: URL
        var status: Int
        var html: String
    }

    private func fetch(_ url: URL) async throws -> Page {
        let (data, resp) = try await session.data(from: url)
        let http = resp as? HTTPURLResponse
        return Page(url: http?.url ?? url, status: http?.statusCode ?? 0,
                    html: String(decoding: data.prefix(512 * 1024), as: UTF8.self))
    }

    private func submit(_ form: HTMLForm, fields: [(String, String)]) async throws -> Page {
        var comps = URLComponents()
        comps.queryItems = fields.map { URLQueryItem(name: $0.0, value: $0.1) }
        let query = comps.percentEncodedQuery ?? ""
        var req: URLRequest
        if form.method == "POST" {
            req = URLRequest(url: form.action)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(query.utf8)
        } else {
            var c = URLComponents(url: form.action, resolvingAgainstBaseURL: true) ?? URLComponents()
            c.percentEncodedQuery = query
            req = URLRequest(url: c.url ?? form.action)
        }
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        return Page(url: http?.url ?? form.action, status: http?.statusCode ?? 0,
                    html: String(decoding: data.prefix(512 * 1024), as: UTF8.self))
    }

    // Can the Mac open a connection to the TV's Cast port through the gateway? Retries
    // until `timeout`: a gateway can take a moment to open up after pairing.
    func reachable(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if await probeOnce(timeout: min(2, max(0.5, deadline.timeIntervalSinceNow))) { return true }
            try? await Task.sleep(nanoseconds: 400_000_000)
        } while Date() < deadline
        return false
    }

    private func probeOnce(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(gatewayHost), port: NWEndpoint.Port(rawValue: devicePort)!, using: .tcp)
            let queue = DispatchQueue(label: "mira.pair.probe")
            let probe = Probe(conn, cont)      // all calls on `queue`
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: probe.finish(true)
                case .failed, .waiting: probe.finish(false)
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { probe.finish(false) }
        }
    }

    private final class Probe: @unchecked Sendable {
        let conn: NWConnection
        let cont: CheckedContinuation<Bool, Never>
        var done = false
        init(_ conn: NWConnection, _ cont: CheckedContinuation<Bool, Never>) { self.conn = conn; self.cont = cont }
        func finish(_ ok: Bool) {
            guard !done else { return }
            done = true
            conn.cancel()
            cont.resume(returning: ok)
        }
    }

    // Pairing codes are short-lived secrets: keep them out of the log.
    static func redacted(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url.host ?? "?" }
        c.queryItems = c.queryItems?.map { URLQueryItem(name: $0.name, value: "...") }
        return c.string ?? url.absoluteString
    }
}

// Just enough HTML form parsing for pairing pages.
struct HTMLForm {
    var action: URL
    var method: String                       // GET or POST
    var hidden: [(String, String)] = []
    var textFields: [String] = []
    var submitValues: [(String, String)] = []
    var needsPerson = false                  // checkbox / password / select: leave it to the user

    // The field the pairing code goes into.
    var codeField: String? {
        let lowered = textFields.map { ($0, $0.lowercased()) }
        return lowered.first(where: { $0.1.contains("code") || $0.1.contains("pin") || $0.1.contains("pair") })?.0
            ?? (textFields.count == 1 ? textFields[0] : nil)
    }

    static func parse(_ html: String, base: URL) -> [HTMLForm] {
        var forms: [HTMLForm] = []
        var rest = html[...]
        while let start = rest.range(of: "<form", options: .caseInsensitive) {
            let afterTag = rest[start.lowerBound...]
            guard let tagEnd = afterTag.firstIndex(of: ">") else { break }
            let attrs = attributes(String(afterTag[afterTag.startIndex..<tagEnd]))
            let bodyStart = afterTag.index(after: tagEnd)
            let end = rest.range(of: "</form", options: .caseInsensitive, range: bodyStart..<rest.endIndex)?.lowerBound ?? rest.endIndex
            let body = String(rest[bodyStart..<end])
            rest = rest[end...].dropFirst(min(6, rest[end...].count))

            let action = attrs["action"].flatMap { $0.isEmpty ? nil : URL(string: decodeEntities($0), relativeTo: base)?.absoluteURL } ?? base
            var form = HTMLForm(action: action, method: (attrs["method"] ?? "get").uppercased() == "POST" ? "POST" : "GET")
            for tag in tags(named: "input", in: body) {
                let a = attributes(tag)
                let name = a["name"] ?? ""
                let type = (a["type"] ?? "text").lowercased()
                switch type {
                case "hidden": if !name.isEmpty { form.hidden.append((name, decodeEntities(a["value"] ?? ""))) }
                case "text", "number", "tel", "search", "": if !name.isEmpty { form.textFields.append(name) }
                case "submit": if !name.isEmpty { form.submitValues.append((name, decodeEntities(a["value"] ?? ""))) }
                case "checkbox", "radio", "password", "email", "file": form.needsPerson = true
                default: break
                }
            }
            if !tags(named: "select", in: body).isEmpty || !tags(named: "textarea", in: body).isEmpty { form.needsPerson = true }
            forms.append(form)
        }
        return forms
    }

    static func tags(named name: String, in html: String) -> [String] {
        var out: [String] = []
        var rest = html[...]
        while let r = rest.range(of: "<\(name)", options: .caseInsensitive) {
            let after = rest[r.upperBound...]
            guard let first = after.first, first == " " || first == ">" || first == "\n" || first == "\t" || first == "/" else {
                rest = after
                continue
            }
            guard let end = after.firstIndex(of: ">") else { break }
            out.append(String(rest[r.lowerBound..<end]))
            rest = after[end...]
        }
        return out
    }

    static func attributes(_ tag: String) -> [String: String] {
        var out: [String: String] = [:]
        let pattern = #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return out }
        let ns = tag as NSString
        // Skip the tag name itself.
        let startOffset = (tag.firstIndex(of: " ").map { tag.distance(from: tag.startIndex, to: $0) }) ?? ns.length
        for m in re.matches(in: tag, range: NSRange(location: startOffset, length: ns.length - startOffset)) {
            let key = ns.substring(with: m.range(at: 1)).lowercased()
            var value = ""
            for g in 2...4 where m.range(at: g).location != NSNotFound { value = ns.substring(with: m.range(at: g)) }
            if out[key] == nil { out[key] = value }
        }
        return out
    }

    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
