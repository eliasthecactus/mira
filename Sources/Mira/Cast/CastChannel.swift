import Foundation
import Network

// The Cast control connection: TLS to port 8009, length-prefixed CastMessages.
//
// Receivers use self-signed certificates (authenticity is normally proven by an extra
// device-auth exchange that only protects the *sender*), so the certificate is not
// verified here. A heartbeat PING every 5 s keeps the connection open; receivers
// drop senders that stay silent.
final class CastChannel: @unchecked Sendable {   // all state on `queue`

    enum ChannelError: LocalizedError {
        case connectFailed(String)
        case refused                // nothing listening, or a gateway that blocks this device
        case closed(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .connectFailed(let why): return "Could not connect to the Cast device: \(why)"
            case .refused: return "The Cast device refused the connection"
            case .closed(let why): return "Cast connection closed: \(why)"
            case .timeout: return "The Cast device stopped answering"
            }
        }
    }

    static let defaultPort: UInt16 = 8009

    var onMessage: ((CastMessage) -> Void)?
    var onClosed: ((Error?) -> Void)?

    let host: String
    let port: UInt16
    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var buffer = Data()
    private var heartbeat: DispatchSourceTimer?
    private var lastReceived = Date()
    private var closed = false

    init(host: String, port: UInt16 = CastChannel.defaultPort, queue: DispatchQueue) {
        self.host = host
        self.port = port
        self.queue = queue
    }

    func connect(ready: @escaping () -> Void) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
            complete(true)   // self-signed device certificate
        }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 8
        let params = NWParameters(tls: tls, tcp: tcp)
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Log.info("Cast", "Connected to \(self.host):\(self.port) (TLS)")
                self.lastReceived = Date()
                self.startHeartbeat()
                self.receive()
                ready()
            case .failed(let err):
                self.finish(Self.isRefused(err) ? ChannelError.refused : ChannelError.connectFailed("\(err)"))
            case .waiting(let err):
                if Self.isRefused(err) {
                    self.finish(ChannelError.refused)
                    return
                }
                Log.warn("Cast", "Waiting to connect: \(err)")
                self.queue.asyncAfter(deadline: .now() + 6) { [weak self] in
                    if case .waiting = conn.state { self?.finish(ChannelError.connectFailed("\(err)")) }
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    static func isRefused(_ err: NWError) -> Bool {
        if case .posix(let code) = err, code == .ECONNREFUSED { return true }
        return false
    }

    func send(_ message: CastMessage) {
        guard let connection, !closed else { return }
        if message.namespace != CastMessage.heartbeat {
            Log.debug("Cast", "-> \(message.namespace) \(message.destinationID): \(message.payloadUTF8 ?? "<binary>")")
        }
        connection.send(content: message.framed(), completion: .contentProcessed { err in
            if let err { Log.warn("Cast", "Send failed: \(err)") }
        })
    }

    func close() {
        queue.async { self.finish(nil) }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        heartbeat?.cancel(); heartbeat = nil
        connection?.cancel(); connection = nil
        onClosed?(error)
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.lastReceived = Date()
                self.buffer.append(data)
                guard let messages = CastMessage.extract(from: &self.buffer) else {
                    self.finish(ChannelError.closed("malformed message from the device"))
                    return
                }
                for m in messages { self.handle(m) }
            }
            if let err { self.finish(ChannelError.closed("\(err)")); return }
            if done { self.finish(ChannelError.closed("the device closed the connection")); return }
            self.receive()
        }
    }

    private func handle(_ m: CastMessage) {
        if m.namespace == CastMessage.heartbeat {
            if m.type == "PING" {
                send(.json(["type": "PONG"], namespace: CastMessage.heartbeat,
                           from: m.destinationID, to: m.sourceID))
            }
            return
        }
        Log.debug("Cast", "<- \(m.namespace) \(m.sourceID): \(m.payloadUTF8 ?? "<binary \(m.payloadBinary?.count ?? 0) bytes>")")
        onMessage?(m)
    }

    private func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastReceived) > 20 {
                self.finish(ChannelError.timeout)
                return
            }
            self.send(.json(["type": "PING"], namespace: CastMessage.heartbeat,
                            from: CastMessage.platformSender, to: CastMessage.platformReceiver))
        }
        t.resume()
        heartbeat = t
    }
}
