import Foundation
import dnssd

// Finds Miracast-over-Infrastructure sinks. Per [MS-MICE] a sink registers
// "<friendly name>._display._tcp.local" (SRV -> port 7250) with a TXT record
// "container_id=<GUID>". The Microsoft 4K Wireless Display Adapter only does this
// once it has been joined to your Wi-Fi network with Microsoft's app.
//
// Uses the DNS-SD API directly (browse -> resolve -> getaddrinfo on the interface
// the service was seen on). Network.framework's resolution follows the default
// route, so with a VPN connected it never resolves LAN services.
//
// Note: if macOS Local Network access is denied for Mira, the browse simply never
// reports anything - there is no error to detect. The UI explains this when
// nothing turns up.
//
// Google Cast devices register "<id>._googlecast._tcp" (port 8009) with TXT fn=<friendly
// name>, md=<model> and ca=<capability bits>; only those with video output are shown.
final class DeviceBrowser: @unchecked Sendable {   // all state confined to `queue`
    static let serviceType = "_display._tcp"
    static let castServiceType = "_googlecast._tcp"
    static let airplayServiceType = "_airplay._tcp"

    let kind: MiracastDevice.Kind
    var serviceType: String {
        switch kind {
        case .miracast: return Self.serviceType
        case .googleCast: return Self.castServiceType
        case .airplay: return Self.airplayServiceType
        case .dlna: return ""
        }
    }

    init(kind: MiracastDevice.Kind = .miracast) {
        self.kind = kind
    }

    var onDeviceFound: ((MiracastDevice) -> Void)?
    var onDeviceLost: ((String) -> Void)?

    private let queue = DispatchQueue(label: "mira.discovery")
    private var browseRef: DNSServiceRef?
    private var resolutions: [ObjectIdentifier: Resolution] = [:]

    // One in-flight resolve -> address lookup for a service seen on one interface.
    private final class Resolution {
        let name: String
        let interfaceIndex: UInt32
        weak var browser: DeviceBrowser?
        var ref: DNSServiceRef?
        var port: UInt16 = 0
        var containerID: String?
        var friendlyName: String?
        var model: String?
        var capabilities: Int?
        var features: String?
        var done = false

        init(name: String, interfaceIndex: UInt32, browser: DeviceBrowser) {
            self.name = name
            self.interfaceIndex = interfaceIndex
            self.browser = browser
        }

        func cancel() {
            if let ref { DNSServiceRefDeallocate(ref) }
            ref = nil
            done = true
        }
    }

    func start() {
        queue.async { [self] in
            guard browseRef == nil else { return }
            var ref: DNSServiceRef?
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            let err = DNSServiceBrowse(&ref, 0, 0, serviceType, nil, { _, flags, ifIndex, err, name, type, domain, ctx in
                guard let ctx else { return }
                let me = Unmanaged<DeviceBrowser>.fromOpaque(ctx).takeUnretainedValue()
                guard err == kDNSServiceErr_NoError, let name, let type, let domain else {
                    me.browseFailed(err)
                    return
                }
                me.browseEvent(added: flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, interfaceIndex: ifIndex,
                               name: String(cString: name), type: String(cString: type), domain: String(cString: domain))
            }, ctx)
            guard err == kDNSServiceErr_NoError, let ref else {
                Log.error("Discovery", "DNSServiceBrowse failed: \(err)")
                return
            }
            DNSServiceSetDispatchQueue(ref, queue)
            browseRef = ref
            Log.info("Discovery", "Browsing \(serviceType)")
        }
    }

    func stop() {
        queue.async { [self] in
            if let browseRef { DNSServiceRefDeallocate(browseRef) }
            browseRef = nil
            resolutions.values.forEach { $0.cancel() }
            resolutions.removeAll()
        }
    }

    // MARK: - Browse -> resolve -> address (all on `queue`)

    private func browseFailed(_ err: DNSServiceErrorType) {
        if err == kDNSServiceErr_PolicyDenied {
            Log.error("Discovery", "macOS denied local network access. Allow Mira in System Settings -> Privacy & Security -> Local Network, then restart it.")
        } else {
            Log.error("Discovery", "Browse error \(err)")
        }
    }

    private func browseEvent(added: Bool, interfaceIndex: UInt32, name: String, type: String, domain: String) {
        Log.debug("Discovery", "\(added ? "+" : "-") \(name) on interface \(interfaceIndex)")
        if isLoopback(interfaceIndex) { return }
        guard added else {
            Log.info("Discovery", "Lost \(name)")
            onDeviceLost?(name)
            return
        }

        let r = Resolution(name: name, interfaceIndex: interfaceIndex, browser: self)
        let ctx = Unmanaged.passRetained(r).toOpaque()   // released when the resolution finishes
        var ref: DNSServiceRef?
        let err = DNSServiceResolve(&ref, 0, interfaceIndex, name, type, domain, { _, _, _, err, _, host, port, txtLen, txt, ctx in
            guard let ctx else { return }
            let r = Unmanaged<Resolution>.fromOpaque(ctx).takeUnretainedValue()
            guard let me = r.browser else { return }
            if err != kDNSServiceErr_NoError || host == nil {
                me.finish(r, error: "resolve error \(err)")
                return
            }
            Log.debug("Discovery", "resolved \(r.name) -> \(String(cString: host!))")
            r.port = UInt16(bigEndian: port)
            r.containerID = DeviceBrowser.txtValue("container_id", txtLen, txt)
            r.friendlyName = DeviceBrowser.txtValue("fn", txtLen, txt)
            r.model = DeviceBrowser.txtValue("md", txtLen, txt) ?? DeviceBrowser.txtValue("model", txtLen, txt)
            r.features = DeviceBrowser.txtValue("features", txtLen, txt)
            r.capabilities = DeviceBrowser.txtValue("ca", txtLen, txt).flatMap { Int($0) }
            me.lookupAddress(r, host: String(cString: host!))
        }, ctx)
        guard err == kDNSServiceErr_NoError, let ref else {
            Unmanaged<Resolution>.fromOpaque(ctx).release()
            Log.warn("Discovery", "Could not resolve \(name): \(err)")
            return
        }
        r.ref = ref
        resolutions[ObjectIdentifier(r)] = r
        DNSServiceSetDispatchQueue(ref, queue)
        queue.asyncAfter(deadline: .now() + 6) { [weak self, weak r] in
            guard let self, let r, !r.done else { return }
            self.finish(r, error: "timed out")
        }
    }

    private func lookupAddress(_ r: Resolution, host: String) {
        if let ref = r.ref { DNSServiceRefDeallocate(ref) }
        r.ref = nil
        var ref: DNSServiceRef?
        let ctx = Unmanaged.passUnretained(r).toOpaque()
        let err = DNSServiceGetAddrInfo(&ref, 0, r.interfaceIndex, DNSServiceProtocol(kDNSServiceProtocol_IPv4), host, { _, _, _, err, _, addr, _, ctx in
            guard let ctx else { return }
            let r = Unmanaged<Resolution>.fromOpaque(ctx).takeUnretainedValue()
            guard let me = r.browser, !r.done else { return }
            guard err == kDNSServiceErr_NoError, let addr, addr.pointee.sa_family == sa_family_t(AF_INET) else {
                me.finish(r, error: "no IPv4 address (\(err))")
                return
            }
            var sin = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(buf.count))
            // Cast: bit 0 of "ca" = video output; speakers and audio groups don't have it.
            if me.kind == .googleCast, let ca = r.capabilities, ca & 0x01 == 0 {
                Log.debug("Discovery", "Ignoring \(r.friendlyName ?? r.name): audio-only Cast device")
                me.finish(r, error: nil)
                return
            }
            if me.kind == .airplay, !DeviceBrowser.isAirPlayDisplay(model: r.model, features: r.features) {
                Log.debug("Discovery", "Ignoring \(r.name): AirPlay device without a screen (\(r.model ?? "?"))")
                me.finish(r, error: nil)
                return
            }
            let device = MiracastDevice(name: r.friendlyName ?? r.name, ipAddress: String(cString: buf), port: r.port,
                                        containerID: r.containerID, kind: me.kind, model: r.model, serviceName: r.name)
            Log.info("Discovery", "Found \(device)\(r.containerID.map { " container_id=\($0)" } ?? "")\(r.model.map { " model=\($0)" } ?? "")")
            me.onDeviceFound?(device)
            me.finish(r, error: nil)
        }, ctx)
        guard err == kDNSServiceErr_NoError, let ref else {
            finish(r, error: "address lookup failed (\(err))")
            return
        }
        r.ref = ref
        DNSServiceSetDispatchQueue(ref, queue)
    }

    private func finish(_ r: Resolution, error: String?) {
        guard !r.done else { return }
        if let error { Log.warn("Discovery", "Could not resolve \(r.name): \(error)") }
        r.cancel()
        // Defer the release: we may be inside one of this resolution's callbacks.
        queue.async { [self] in
            if resolutions.removeValue(forKey: ObjectIdentifier(r)) != nil {
                Unmanaged.passUnretained(r).release()
            }
        }
    }

    private func isLoopback(_ index: UInt32) -> Bool {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(index, &name) != nil else { return false }
        return String(cString: name).hasPrefix("lo")
    }

    // AirPlay receivers worth listing: TVs and Apple TVs. Macs, iPhones, iPads, HomePods,
    // AirPort and other speakers are left out (features bit 0 = video, bit 7 = screen).
    static func isAirPlayDisplay(model: String?, features: String?) -> Bool {
        let m = (model ?? "").lowercased()
        for skip in ["mac", "imac", "iphone", "ipad", "ipod", "audioaccessory", "airport", "homepod"] where m.hasPrefix(skip) {
            return false
        }
        guard let features else { return true }
        let low = features.split(separator: ",").first.map(String.init) ?? features
        let hex = low.lowercased().hasPrefix("0x") ? String(low.dropFirst(2)) : low
        guard let bits = UInt64(hex, radix: 16) else { return true }
        return bits & 0x01 != 0 || bits & 0x80 != 0
    }

    private static func txtValue(_ key: String, _ len: UInt16, _ txt: UnsafePointer<UInt8>?) -> String? {
        guard let txt else { return nil }
        var valueLen: UInt8 = 0
        guard let ptr = TXTRecordGetValuePtr(len, txt, key, &valueLen) else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(valueLen)), as: UTF8.self)
    }
}
