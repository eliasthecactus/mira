import Foundation
import Network

// Sends RTP packets over UDP to a Miracast sink.
final class RTPSender {

    private var connection: NWConnection?
    private let localPort: UInt16
    private let queue = DispatchQueue(label: "mira.rtp", qos: .userInteractive)
    private(set) var packetsSent: UInt64 = 0
    private(set) var bytesSent: UInt64 = 0

    init(localPort: UInt16 = WFDCapabilities.rtpVideoPort) {
        self.localPort = localPort
    }

    func connect(toHost host: String, port: UInt16) {
        let params = NWParameters.udp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "0.0.0.0", port: NWEndpoint.Port(rawValue: localPort)!)
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port)!,
                                using: params)
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:  print("[RTP] UDP sender ready → \(host):\(port)")
            case .failed(let e): print("[RTP] UDP sender failed: \(e)")
            default: break
            }
        }
        conn.start(queue: queue)
        self.connection = conn
    }

    func send(_ packet: Data) {
        connection?.send(content: packet, completion: .contentProcessed { [weak self] err in
            if let err {
                print("[RTP] send error: \(err)")
                return
            }
            self?.packetsSent += 1
            self?.bytesSent += UInt64(packet.count)
        })
    }

    func send(_ packets: [Data]) {
        for p in packets { send(p) }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }
}
