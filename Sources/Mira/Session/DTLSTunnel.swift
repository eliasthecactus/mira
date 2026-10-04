import Foundation
import Network

// DTLS for MS-MICE stream encryption / PIN pairing.
//
// [MS-MICE] carries the DTLS handshake inside SECURITY_HANDSHAKE messages on the TCP
// 7250 channel, so there is no UDP socket between the peers to run DTLS on. We run
// Network.framework's DTLS 1.2 client against a loopback relay we own: every
// datagram the client emits lands in the relay, and we decide where it goes.
//
//   handshake records  → SECURITY_HANDSHAKE token to the sink (and the sink's tokens
//                        are injected back into the client)
//   application data   → either the encrypted form of a TLVArray (PIN messages) or an
//                        encrypted RTP packet sent on to the sink's RTP port
//
// The spec says TLVArrays and RTP "MUST be encrypted … using the DTLS Encryption Key"
// without naming a record format. We use DTLS application-data records — what a
// DTLS stack (e.g. Windows SChannel) produces when asked to encrypt a message. This
// is an interpretation; the security log lines exist to confirm it on real hardware.
final class DTLSTunnel: @unchecked Sendable {   // all state confined to `queue`

    enum TunnelError: LocalizedError {
        case socket(String)
        case handshake(String)
        case timeout(String)

        var errorDescription: String? {
            switch self {
            case .socket(let s): return "DTLS relay socket error: \(s)"
            case .handshake(let s): return "DTLS handshake with the display failed: \(s)"
            case .timeout(let s): return "DTLS timed out: \(s)"
            }
        }
    }

    var onHandshakeToken: ((Data) -> Void)?
    var onReady: (() -> Void)?
    var onFailed: ((Error) -> Void)?

    private(set) var isReady = false
    private(set) var negotiatedSummary = ""
    private(set) var mediaPacketsSent: UInt64 = 0
    private(set) var mediaBytesSent: UInt64 = 0

    private let queue: DispatchQueue
    private var relayFD: Int32 = -1
    private var relaySource: DispatchSourceRead?
    private var clientAddress: sockaddr_in?
    private var pendingToClient: [Data] = []
    private var connection: NWConnection?

    private enum Route { case message((Data) -> Void), media }
    private var routes: [Route] = []
    private var decryptWaiters: [(Data?) -> Void] = []

    private var mediaFD: Int32 = -1
    private var mediaDestination = sockaddr_in()
    private var stopped = false

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    deinit {
        if relayFD >= 0 { close(relayFD) }
        if mediaFD >= 0 { close(mediaFD) }
    }

    // MARK: - Lifecycle

    func start(handshakeTimeout: TimeInterval = 15) {
        queue.async { [self] in
            do {
                let port = try openRelay()
                startClient(relayPort: port)
                queue.asyncAfter(deadline: .now() + handshakeTimeout) { [weak self] in
                    guard let self, !self.isReady, !self.stopped else { return }
                    self.fail(TunnelError.timeout("no handshake completion after \(Int(handshakeTimeout))s"))
                }
            } catch {
                fail(error)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            connection?.cancel(); connection = nil
            relaySource?.cancel(); relaySource = nil
            if mediaFD >= 0 { close(mediaFD); mediaFD = -1 }
        }
    }

    // MARK: - Handshake

    // A Security Token TLV from the sink → into the DTLS client.
    func receiveHandshakeToken(_ token: Data) {
        queue.async { [self] in
            Log.debug("DTLS", "← \(token.count) bytes \(Self.describe(token))")
            toClient(token)
        }
    }

    // MARK: - Message (TLVArray) encryption

    func encrypt(_ plaintext: Data, completion: @escaping (Data) -> Void) {
        queue.async { [self] in
            guard let connection, isReady else {
                Log.warn("DTLS", "encrypt requested but tunnel is \(stopped ? "stopped" : "not ready")")
                return
            }
            Log.debug("DTLS", "encrypting \(plaintext.count)-byte message, \(routes.count) routes pending, \(mediaPacketsSent) media sent")
            routes.append(.message(completion))
            connection.send(content: plaintext, completion: .contentProcessed { _ in })
        }
    }

    func decrypt(_ record: Data, timeout: TimeInterval = 3, completion: @escaping (Data?) -> Void) {
        queue.async { [self] in
            guard isReady else { completion(nil); return }
            var done = false
            decryptWaiters.append { data in
                guard !done else { return }
                done = true
                completion(data)
            }
            toClient(record)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, !done else { return }
                // The client silently drops records it can't authenticate; unblock the queue.
                if !self.decryptWaiters.isEmpty { self.decryptWaiters.removeFirst() }
                done = true
                Log.warn("DTLS", "Could not decrypt a \(record.count)-byte record from the display")
                completion(nil)
            }
        }
    }

    // MARK: - Media

    func setMediaDestination(host: String, port: UInt16, localPort: UInt16) throws {
        try queue.sync {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { throw TunnelError.socket("media socket: \(errno)") }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var sndbuf: Int32 = 4 << 20
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, socklen_t(MemoryLayout<Int32>.size))
            var local = Self.address("0.0.0.0", localPort)
            guard withUnsafePointer(to: &local, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else {
                close(fd); throw TunnelError.socket("bind media port \(localPort): \(errno)")
            }
            mediaDestination = Self.address(host, port)
            mediaFD = fd
            Log.info("DTLS", "Encrypted RTP → \(host):\(port) from UDP \(localPort)")
        }
    }

    // Each RTP packet becomes one DTLS application-data record on the wire.
    func sendMedia(_ packets: [Data]) {
        queue.async { [self] in
            guard let connection, isReady, mediaFD >= 0 else { return }
            connection.batch {
                for p in packets {
                    routes.append(.media)
                    connection.send(content: p, completion: .idempotent)
                }
            }
        }
    }

    // MARK: - Relay

    private func openRelay() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw TunnelError.socket("socket: \(errno)") }
        var rcvbuf: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))
        var addr = Self.address("127.0.0.1", 0)
        guard withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else {
            close(fd); throw TunnelError.socket("bind: \(errno)")
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            _ = getsockname(fd, $0, &len) } }
        relayFD = fd

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.readRelay() }
        src.resume()
        relaySource = src
        return UInt16(bigEndian: addr.sin_port)
    }

    private func readRelay() {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(relayFD, &buf, buf.count, MSG_DONTWAIT, $0, &len)
                }
            }
            guard n > 0 else { return }
            if clientAddress == nil {
                clientAddress = from
                pendingToClient.forEach(toClient)
                pendingToClient.removeAll()
            }
            fromClient(Data(buf[0..<n]))
        }
    }

    // A datagram the DTLS client wants to send.
    private func fromClient(_ datagram: Data) {
        let contentType = datagram.first ?? 0
        if contentType == 23, isReady, !routes.isEmpty {
            switch routes.removeFirst() {
            case .message(let completion):
                Log.debug("DTLS", "encrypted message record (\(datagram.count) bytes), \(routes.count) routes pending")
                completion(datagram)
            case .media:
                var dest = mediaDestination
                let sent = datagram.withUnsafeBytes { raw in
                    withUnsafePointer(to: &dest) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(mediaFD, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    } }
                }
                if sent > 0 { mediaPacketsSent += 1; mediaBytesSent += UInt64(sent) }
            }
        } else if contentType == 21 && isReady {
            Log.warn("DTLS", "Alert from local DTLS client: \(datagram.hexString)")
        } else {
            Log.debug("DTLS", "→ \(datagram.count) bytes \(Self.describe(datagram))")
            onHandshakeToken?(datagram)
        }
    }

    private func toClient(_ datagram: Data) {
        guard var addr = clientAddress else { pendingToClient.append(datagram); return }
        _ = datagram.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(relayFD, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            } }
        }
    }

    // MARK: - DTLS client

    private func startClient(relayPort: UInt16) {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .DTLSv12)
        // Sinks use self-signed certificates; MS-MICE authenticates the user via the PIN.
        sec_protocol_options_set_verify_block(sec, { metadata, trust, complete in
            Log.info("DTLS", "Display presented a certificate (not verified; MS-MICE authenticates via PIN)")
            complete(true)
        }, queue)
        let udp = NWProtocolUDP.Options()
        let params = NWParameters(dtls: tls, udp: udp)
        params.requiredInterfaceType = .loopback

        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: relayPort)!, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isReady = true
                if let m = conn.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
                    let md = m.securityProtocolMetadata
                    let version = sec_protocol_metadata_get_negotiated_tls_protocol_version(md)
                    let suite = sec_protocol_metadata_get_negotiated_tls_ciphersuite(md)
                    self.negotiatedSummary = String(format: "DTLS 0x%04X, cipher suite 0x%04X", version.rawValue, suite.rawValue)
                }
                Log.info("DTLS", "Handshake complete (\(self.negotiatedSummary))")
                self.receiveDecrypted()
                self.onReady?()
            case .failed(let err):
                self.fail(TunnelError.handshake("\(err)"))
            case .waiting(let err):
                self.fail(TunnelError.handshake("\(err)"))
            default:
                break
            }
        }
        connection = conn
        conn.start(queue: queue)
    }

    private func receiveDecrypted() {
        connection?.receiveMessage { [weak self] data, _, _, err in
            guard let self, !self.stopped else { return }
            if let data, !self.decryptWaiters.isEmpty {
                self.decryptWaiters.removeFirst()(data)
            } else if let data {
                Log.warn("DTLS", "Unexpected decrypted data (\(data.count) bytes)")
            }
            if err == nil { self.receiveDecrypted() }
        }
    }

    private func fail(_ error: Error) {
        guard !stopped else { return }
        stopped = true
        connection?.cancel(); connection = nil
        Log.error("DTLS", error.localizedDescription)
        onFailed?(error)
    }

    // MARK: - Helpers

    static func address(_ host: String, _ port: UInt16) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &a.sin_addr)
        return a
    }

    // "handshake: ClientHello" etc. — enough to read the exchange in the log.
    static func describe(_ datagram: Data) -> String {
        let b = [UInt8](datagram)
        var parts: [String] = []
        var i = 0
        while i + 13 <= b.count {
            let type = b[i]
            let len = Int(b[i + 11]) << 8 | Int(b[i + 12])
            let typeName = [20: "ChangeCipherSpec", 21: "Alert", 22: "Handshake", 23: "AppData"][Int(type)] ?? "type \(type)"
            var detail = ""
            if type == 22, i + 13 < b.count, b[i + 3] == 0 && b[i + 4] == 0 {   // epoch 0 = unencrypted
                let hs = [1: "ClientHello", 2: "ServerHello", 3: "HelloVerifyRequest", 11: "Certificate",
                          12: "ServerKeyExchange", 13: "CertificateRequest", 14: "ServerHelloDone",
                          15: "CertificateVerify", 16: "ClientKeyExchange", 20: "Finished"][Int(b[i + 13])]
                detail = hs.map { " \($0)" } ?? ""
            } else if type == 22 {
                detail = " (encrypted)"
            }
            parts.append(typeName + detail)
            i += 13 + len
        }
        return "[" + parts.joined(separator: ", ") + "]"
    }
}
