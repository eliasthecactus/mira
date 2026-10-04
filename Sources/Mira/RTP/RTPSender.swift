import Foundation
import Network

// Sends RTP packets over UDP to the sink from a fixed local port (the port we
// announce as server_port in the SETUP response).
final class RTPSender {

    private var connection: NWConnection?
    private let localPort: UInt16
    private let queue = DispatchQueue(label: "mira.rtp", qos: .userInteractive)
    private let statsLock = NSLock()
    private var _packetsSent: UInt64 = 0
    private var _bytesSent: UInt64 = 0
    private var _sendErrors: UInt64 = 0
    private var _submitted: UInt64 = 0

    var packetsSent: UInt64 { statsLock.withLock { _packetsSent } }
    var bytesSent: UInt64 { statsLock.withLock { _bytesSent } }
    var sendErrors: UInt64 { statsLock.withLock { _sendErrors } }
    // Packets handed to the network stack but not yet sent — grows when Wi-Fi can't keep up.
    var backlog: Int { statsLock.withLock { Int(_submitted &- _packetsSent &- _sendErrors) } }

    init(localPort: UInt16) {
        self.localPort = localPort
    }

    func connect(toHost host: String, port: UInt16) {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "0.0.0.0", port: NWEndpoint.Port(rawValue: localPort)!)
        params.serviceClass = .interactiveVideo
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port)!,
                                using: params)
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:  Log.info("RTP", "UDP \(self.localPort) → \(host):\(port) ready")
            case .failed(let e): Log.error("RTP", "UDP sender failed: \(e)")
            default: break
            }
        }
        conn.start(queue: queue)
        self.connection = conn
    }

    func send(_ packets: [Data]) {
        guard let connection else { return }
        statsLock.withLock { _submitted &+= UInt64(packets.count) }
        connection.batch {
            for p in packets {
                connection.send(content: p, completion: .contentProcessed { [weak self] err in
                    guard let self else { return }
                    self.statsLock.withLock {
                        if err != nil { self._sendErrors += 1 } else {
                            self._packetsSent += 1
                            self._bytesSent += UInt64(p.count)
                        }
                    }
                    if let err, self.sendErrors % 100 == 1 { Log.warn("RTP", "send error: \(err)") }
                })
            }
        }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }
}
