import Foundation
import Network

// Sends RTCP Sender Reports on a separate UDP socket (RTP port + 1).
final class RTCPSender {

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "mira.rtcp", qos: .background)
    private var timer: DispatchSourceTimer?
    private let ssrc: UInt32
    private var packetCount: UInt32 = 0
    private var octetCount: UInt32 = 0
    private var rtpTimestampRef: (() -> UInt32)?

    init(ssrc: UInt32) {
        self.ssrc = ssrc
    }

    func connect(toHost host: String, rtcpPort: UInt16, localPort: UInt16 = WFDCapabilities.rtcpVideoPort) {
        let params = NWParameters.udp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "0.0.0.0",
                                                           port: NWEndpoint.Port(rawValue: localPort)!)
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: rtcpPort)!,
                                using: params)
        conn.stateUpdateHandler = { state in
            if case .ready = state { print("[RTCP] Sender ready → \(host):\(rtcpPort)") }
        }
        conn.start(queue: queue)
        self.connection = conn
    }

    // Call this for every RTP packet sent
    func record(packets: UInt32, octets: UInt32) {
        packetCount &+= packets
        octetCount  &+= octets
    }

    // rtpTimestamp: closure returning current RTP timestamp (90kHz)
    func startReports(interval: TimeInterval = 1.0, rtpTimestamp: @escaping () -> UInt32) {
        self.rtpTimestampRef = rtpTimestamp
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.sendReport() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        connection?.cancel()
    }

    // MARK: - RTCP SR (RFC 3550 Section 6.4.1)

    private func sendReport() {
        let ntpTime = wallClockNTP()
        let rtpTS = rtpTimestampRef?() ?? 0

        var report = Data(count: 28)   // 8-byte fixed + 20-byte sender info = 1 report block
        report[0]  = 0x80              // V=2, P=0, RC=0
        report[1]  = 200               // PT=SR
        report[2]  = 0x00              // length high (28 bytes = 7 words → length = 6)
        report[3]  = 0x06
        // SSRC
        report[4]  = UInt8((ssrc >> 24) & 0xFF)
        report[5]  = UInt8((ssrc >> 16) & 0xFF)
        report[6]  = UInt8((ssrc >>  8) & 0xFF)
        report[7]  = UInt8( ssrc        & 0xFF)
        // NTP timestamp (64-bit)
        let ntpHi = ntpTime.high
        let ntpLo = ntpTime.low
        report[8]  = UInt8((ntpHi >> 24) & 0xFF)
        report[9]  = UInt8((ntpHi >> 16) & 0xFF)
        report[10] = UInt8((ntpHi >>  8) & 0xFF)
        report[11] = UInt8( ntpHi        & 0xFF)
        report[12] = UInt8((ntpLo >> 24) & 0xFF)
        report[13] = UInt8((ntpLo >> 16) & 0xFF)
        report[14] = UInt8((ntpLo >>  8) & 0xFF)
        report[15] = UInt8( ntpLo        & 0xFF)
        // RTP timestamp
        report[16] = UInt8((rtpTS >> 24) & 0xFF)
        report[17] = UInt8((rtpTS >> 16) & 0xFF)
        report[18] = UInt8((rtpTS >>  8) & 0xFF)
        report[19] = UInt8( rtpTS        & 0xFF)
        // Sender's packet count
        report[20] = UInt8((packetCount >> 24) & 0xFF)
        report[21] = UInt8((packetCount >> 16) & 0xFF)
        report[22] = UInt8((packetCount >>  8) & 0xFF)
        report[23] = UInt8( packetCount        & 0xFF)
        // Sender's octet count
        report[24] = UInt8((octetCount >> 24) & 0xFF)
        report[25] = UInt8((octetCount >> 16) & 0xFF)
        report[26] = UInt8((octetCount >>  8) & 0xFF)
        report[27] = UInt8( octetCount        & 0xFF)

        connection?.send(content: report, completion: .idempotent)
    }

    // MARK: - NTP timestamp

    // NTP epoch is Jan 1, 1900. Unix epoch is Jan 1, 1970.
    private let ntpEpochOffset: UInt64 = 2_208_988_800

    private struct NTPTimestamp { var high: UInt32; var low: UInt32 }

    private func wallClockNTP() -> NTPTimestamp {
        let now = Date().timeIntervalSince1970
        let seconds = UInt64(now) + ntpEpochOffset
        let fraction = UInt64((now - Double(UInt64(now))) * Double(UInt32.max))
        return NTPTimestamp(high: UInt32(seconds & 0xFFFFFFFF),
                            low:  UInt32(fraction & 0xFFFFFFFF))
    }
}
