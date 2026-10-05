import Foundation

// A UPnP/DLNA MediaRenderer (smart TVs from Samsung, LG, Sony, Philips, ...): its
// device description and the AVTransport service Mira uses to make the TV play a
// stream from the Mac.
struct DLNARenderer: Equatable {
    var friendlyName: String
    var manufacturer: String?
    var model: String?
    var udn: String
    var location: URL
    var avTransportControl: URL

    static let avTransport = "urn:schemas-upnp-org:service:AVTransport:1"

    // Parses a device description (the XML at the SSDP LOCATION).
    static func parse(_ xml: Data, location: URL) -> DLNARenderer? {
        let p = DescriptionParser()
        let parser = XMLParser(data: xml)
        parser.delegate = p
        guard parser.parse() || p.deviceType != nil else { return nil }
        guard let control = p.avTransportControlURL else { return nil }
        let base = p.urlBase.flatMap(URL.init(string:)) ?? location
        guard let controlURL = URL(string: control, relativeTo: base)?.absoluteURL else { return nil }
        return DLNARenderer(friendlyName: p.friendlyName ?? location.host ?? "TV", manufacturer: p.manufacturer,
                            model: p.modelName, udn: p.udn ?? location.absoluteString,
                            location: location, avTransportControl: controlURL)
    }

    private final class DescriptionParser: NSObject, XMLParserDelegate {
        var deviceType: String?
        var friendlyName: String?
        var manufacturer: String?
        var modelName: String?
        var udn: String?
        var urlBase: String?
        var avTransportControlURL: String?
        private var text = ""
        private var serviceType: String?
        private var controlURL: String?
        private var depth = 0          // nesting of <device>; the first device's fields win

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if name == "device" { depth += 1 }
            if name == "service" { serviceType = nil; controlURL = nil }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "deviceType" where depth == 1: deviceType = v
            case "friendlyName" where depth == 1: friendlyName = v
            case "manufacturer" where depth == 1: manufacturer = v
            case "modelName" where depth == 1: modelName = v
            case "UDN" where depth == 1: udn = v
            case "URLBase": urlBase = v
            case "serviceType": serviceType = v
            case "controlURL": controlURL = v
            case "service":
                if serviceType?.hasPrefix("urn:schemas-upnp-org:service:AVTransport:") == true, avTransportControlURL == nil {
                    avTransportControlURL = controlURL
                }
            case "device": depth -= 1
            default: break
            }
            text = ""
        }
    }

    // MARK: - AVTransport (SOAP)

    enum SOAPError: LocalizedError {
        case failed(String, String)
        var errorDescription: String? {
            switch self { case .failed(let action, let why): return "The TV refused \(action): \(why)" }
        }
    }

    // DLNA content features for a live MPEG-TS stream: no seeking (OP=00), streaming
    // transfer mode, connection stalling allowed, DLNA 1.5.
    static let liveTSFeatures = "DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"

    static func didl(title: String, url: URL) -> String {
        let t = xmlEscape(title)
        return """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">\
        <item id="mira" parentID="0" restricted="1"><dc:title>\(t)</dc:title>\
        <upnp:class>object.item.videoItem</upnp:class>\
        <res protocolInfo="http-get:*:video/mpeg:\(liveTSFeatures)">\(xmlEscape(url.absoluteString))</res>\
        </item></DIDL-Lite>
        """
    }

    static func soapEnvelope(action: String, arguments: [(String, String)]) -> String {
        let args = arguments.map { "<\($0.0)>\(xmlEscape($0.1))</\($0.0)>" }.joined()
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        <s:Body><u:\(action) xmlns:u="\(avTransport)">\(args)</u:\(action)></s:Body></s:Envelope>
        """
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    func call(_ action: String, _ arguments: [(String, String)], timeout: TimeInterval = 8,
              completion: @escaping (Result<String, Error>) -> Void) {
        var req = URLRequest(url: avTransportControl, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(Self.avTransport)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        req.httpBody = Data(Self.soapEnvelope(action: action, arguments: arguments).utf8)
        Log.debug("DLNA", "-> \(action) \(avTransportControl)")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let body = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            if let err { completion(.failure(err)); return }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                let code = Self.element("errorDescription", in: body) ?? Self.element("errorCode", in: body) ?? "HTTP \(status)"
                completion(.failure(SOAPError.failed(action, code)))
                return
            }
            completion(.success(body))
        }.resume()
    }

    func play(url: URL, title: String, completion: @escaping (Error?) -> Void) {
        call("SetAVTransportURI", [("InstanceID", "0"), ("CurrentURI", url.absoluteString),
                                   ("CurrentURIMetaData", Self.didl(title: title, url: url))]) { r in
            if case .failure(let e) = r { completion(e); return }
            self.call("Play", [("InstanceID", "0"), ("Speed", "1")]) { r in
                if case .failure(let e) = r { completion(e) } else { completion(nil) }
            }
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        call("Stop", [("InstanceID", "0")], timeout: 3) { _ in completion?() }
    }

    // PLAYING, TRANSITIONING, PAUSED_PLAYBACK, STOPPED, NO_MEDIA_PRESENT
    func transportState(completion: @escaping (String?) -> Void) {
        call("GetTransportInfo", [("InstanceID", "0")], timeout: 4) { r in
            if case .success(let body) = r { completion(Self.element("CurrentTransportState", in: body)) }
            else { completion(nil) }
        }
    }

    static func element(_ name: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(name)>") ?? xml.range(of: ":\(name)>"),
              let end = xml.range(of: "</", range: start.upperBound..<xml.endIndex) else { return nil }
        return String(xml[start.upperBound..<end.lowerBound])
    }
}
