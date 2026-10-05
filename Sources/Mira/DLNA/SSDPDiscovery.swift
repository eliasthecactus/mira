import Foundation

// Finds DLNA MediaRenderers (smart TVs) with SSDP: an M-SEARCH to 239.255.255.250:1900,
// unicast replies carry LOCATION, the device description has the AVTransport service.
final class SSDPDiscovery: @unchecked Sendable {   // state confined to `queue`

    var onFound: ((MiracastDevice, DLNARenderer) -> Void)?

    private let queue = DispatchQueue(label: "mira.ssdp")
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var seen: [String: Date] = [:]      // LOCATION -> last fetch
    private(set) var renderers: [String: DLNARenderer] = [:]   // by UDN

    static let searchTarget = "urn:schemas-upnp-org:device:MediaRenderer:1"

    func start() {
        queue.async { [self] in
            guard fd < 0 else { return }
            let s = socket(AF_INET, SOCK_DGRAM, 0)
            guard s >= 0 else { Log.warn("DLNA", "SSDP socket failed: \(errno)"); return }
            var ttl: UInt8 = 2
            setsockopt(s, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(1))
            var any = DTLSTunnel.address("0.0.0.0", 0)
            _ = withUnsafePointer(to: &any) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            fd = s
            let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
            src.setEventHandler { [weak self] in self?.read() }
            src.resume()
            readSource = src
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 20)
            t.setEventHandler { [weak self] in self?.search() }
            t.resume()
            timer = t
            Log.info("Discovery", "Searching for DLNA renderers (SSDP)")
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel(); timer = nil
            readSource?.cancel(); readSource = nil
            if fd >= 0 { close(fd); fd = -1 }
        }
    }

    static func searchMessage(mx: Int = 2) -> String {
        "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\n"
            + "MX: \(mx)\r\nST: \(searchTarget)\r\nUSER-AGENT: macOS UPnP/1.1 Mira/\(AppInfo.version)\r\n\r\n"
    }

    private func search() {
        guard fd >= 0 else { return }
        let msg = Array(Self.searchMessage().utf8)
        var dest = DTLSTunnel.address("239.255.255.250", 1900)
        for _ in 0..<2 {     // UDP: send twice
            _ = withUnsafePointer(to: &dest) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, msg, msg.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
    }

    // "HTTP/1.1 200 OK" + headers -> [lowercased name: value]
    static func parseHeaders(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            guard let c = line.firstIndex(of: ":") else { continue }
            out[line[..<c].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    private func read() {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &buf, buf.count, MSG_DONTWAIT)
        guard n > 0 else { return }
        let text = String(decoding: buf[0..<n], as: UTF8.self)
        guard text.hasPrefix("HTTP/1.1 200") || text.hasPrefix("NOTIFY") else { return }
        let h = Self.parseHeaders(text)
        guard let loc = h["location"], let url = URL(string: loc) else { return }
        if let last = seen[loc], Date().timeIntervalSince(last) < 60 { return }
        seen[loc] = Date()
        fetchDescription(url)
    }

    private func fetchDescription(_ url: URL) {
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 5)) { [weak self] data, _, err in
            guard let self, let data, err == nil else { return }
            guard let r = DLNARenderer.parse(data, location: url) else {
                Log.debug("Discovery", "\(url): no AVTransport service")
                return
            }
            self.queue.async {
                guard self.renderers[r.udn] != r else { return }
                self.renderers[r.udn] = r
                let device = MiracastDevice(name: r.friendlyName, ipAddress: url.host ?? "", port: UInt16(url.port ?? 80),
                                            kind: .dlna, model: [r.manufacturer, r.model].compactMap { $0 }.joined(separator: " "),
                                            serviceName: r.udn, location: r.location)
                Log.info("Discovery", "Found \(device) \(device.model ?? "")")
                self.onFound?(device, r)
            }
        }.resume()
    }

    // For connect-by-IP and the CLI: the renderer with this IP, if seen.
    func renderer(for ip: String) -> DLNARenderer? {
        queue.sync { renderers.values.first { $0.location.host == ip } }
    }
}
