import Foundation

// RTCP on the RTP port + 1 (RFC 3550): sends Sender Reports once a second and listens
// for the sink's Receiver Reports, whose loss figures drive the bitrate controller.
// RTCP is optional in WFD. We always listen; we send SRs once we know where to (from
// the SETUP Transport header, or the address the sink's own RTCP comes from).
final class RTCPSender: @unchecked Sendable {   // all state confined to `queue`

    struct Snapshot { var rtpTimestamp: UInt32; var packets: UInt32; var octets: UInt32 }

    var onReport: ((RTCPReportBlock) -> Void)?

    private let queue = DispatchQueue(label: "mira.rtcp", qos: .utility)
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private let ssrc: UInt32
    private var destination: sockaddr_in?
    private var sinkHost = ""
    private(set) var reportsReceived = 0

    init(ssrc: UInt32) {
        self.ssrc = ssrc
    }

    func start(sinkHost: String, rtcpPort: UInt16?, localPort: UInt16, snapshot: @escaping () -> Snapshot) {
        queue.sync {
            self.sinkHost = sinkHost
            let s = socket(AF_INET, SOCK_DGRAM, 0)
            guard s >= 0 else { Log.warn("RTCP", "socket failed: \(errno)"); return }
            var yes: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
            var local = DTLSTunnel.address("0.0.0.0", localPort)
            guard withUnsafePointer(to: &local, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else {
                Log.warn("RTCP", "Could not bind UDP \(localPort) (\(errno)); no RTCP this session")
                close(s); return
            }
            fd = s
            if let rtcpPort { destination = DTLSTunnel.address(sinkHost, rtcpPort) }

            let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
            src.setEventHandler { [weak self] in self?.read() }
            src.resume()
            readSource = src

            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in
                guard let self, self.fd >= 0, var dest = self.destination else { return }
                let report = self.senderReport(snapshot())
                _ = report.withUnsafeBytes { raw in
                    withUnsafePointer(to: &dest) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(self.fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    } }
                }
            }
            t.resume()
            timer = t
            Log.info("RTCP", "Listening on UDP \(localPort)\(rtcpPort.map { ", sender reports -> \(sinkHost):\($0)" } ?? "")")
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel(); timer = nil
            readSource?.cancel(); readSource = nil
            if fd >= 0 { close(fd); fd = -1 }
        }
    }

    private func read() {
        var buf = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, MSG_DONTWAIT, $0, &len) }
        }
        guard n > 0 else { return }
        if destination == nil {
            destination = from      // learn the sink's RTCP address from its first packet
            Log.info("RTCP", "Sink sends RTCP; replying to the same address")
        }
        for block in RTCPReportBlock.parse(Data(buf[0..<n])) where block.ssrc == ssrc {
            reportsReceived += 1
            Log.debug("RTCP", String(format: "RR: %.1f%% lost, jitter %u", block.fractionLost * 100, block.jitter))
            onReport?(block)
        }
    }

    func senderReport(_ s: Snapshot) -> Data {
        // NTP: seconds since 1900 + 32-bit fraction
        let now = Date().timeIntervalSince1970
        let seconds = UInt32(truncatingIfNeeded: UInt64(now) + 2_208_988_800)
        let fraction = UInt32(truncatingIfNeeded: UInt64((now - floor(now)) * 4_294_967_296.0))

        var d = Data(capacity: 28)
        d.append(0x80)             // V=2, RC=0
        d.append(200)              // PT=SR
        d.appendBE(UInt16(6))      // length in 32-bit words minus one
        d.appendBE(ssrc)
        d.appendBE(seconds)
        d.appendBE(fraction)
        d.appendBE(s.rtpTimestamp)
        d.appendBE(s.packets)
        d.appendBE(s.octets)
        return d
    }
}
