import Foundation
import Network

// Sends RTCP Sender Reports (RFC 3550 §6.4.1) once a second. RTCP is optional in
// WFD; we only send it when the sink's SETUP Transport header names an RTCP port.
final class RTCPSender {

    struct Snapshot { var rtpTimestamp: UInt32; var packets: UInt32; var octets: UInt32 }

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "mira.rtcp", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let ssrc: UInt32

    init(ssrc: UInt32) {
        self.ssrc = ssrc
    }

    func start(toHost host: String, rtcpPort: UInt16, localPort: UInt16, snapshot: @escaping () -> Snapshot) {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "0.0.0.0", port: NWEndpoint.Port(rawValue: localPort)!)
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: rtcpPort)!,
                                using: params)
        conn.start(queue: queue)
        connection = conn

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.connection?.send(content: self.senderReport(snapshot()), completion: .idempotent)
        }
        t.resume()
        timer = t
        Log.info("RTCP", "Sender reports → \(host):\(rtcpPort)")
    }

    func stop() {
        timer?.cancel(); timer = nil
        connection?.cancel(); connection = nil
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
