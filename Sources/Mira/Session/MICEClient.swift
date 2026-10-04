import Foundation
import Network

// How the MICE session is set up. [MS-MICE] lets the *source* choose: a sink that
// receives a plain SOURCE_READY must connect back (3.1.5.3), so `.none` works with
// any compliant sink; `.encrypted` adds DTLS stream encryption; `.pin` additionally
// makes the sink show a PIN the user types on the Mac.
enum MICESecurity: String, CaseIterable {
    case none, encrypted, pin
}

// MS-MICE signalling channel: TCP from the Mac to the sink's port 7250.
//
//   none:       SOURCE_READY
//   encrypted:  SECURITY_HANDSHAKE ⇄ (DTLS) → SOURCE_READY;              RTP encrypted
//   pin:        SESSION_REQUEST → SECURITY_HANDSHAKE ⇄ (DTLS) → PIN_CHALLENGE ⇄
//               PIN_RESPONSE → SOURCE_READY;  TLVArrays and RTP encrypted
//
// After SOURCE_READY the sink opens a TCP connection back to our RTSP port. The 7250
// connection stays open for the whole session; either side may send STOP_PROJECTION.
final class MICEClient: @unchecked Sendable {   // all state confined to `queue`

    enum MICEError: LocalizedError {
        case wrongPIN
        case pinRejected(String)
        case pinCancelled
        case unexpected(String)

        var errorDescription: String? {
            switch self {
            case .wrongPIN: return "The display rejected the PIN. Check the number shown on the TV and try again."
            case .pinRejected(let why): return "PIN pairing failed: \(why)"
            case .pinCancelled: return "PIN entry was cancelled"
            case .unexpected(let s): return s
            }
        }
    }

    var onConnected: (() -> Void)?
    // Fired once SOURCE_READY has been sent (the sink should now connect to RTSP).
    var onSourceReady: (() -> Void)?
    var onStopProjection: (() -> Void)?
    var onError: ((Error) -> Void)?
    // Asks the user for the PIN shown on the TV; call the completion with nil to cancel.
    var pinProvider: ((@escaping (String?) -> Void) -> Void)?

    let host: String
    let port: UInt16
    let friendlyName: String
    let sourceID: Data
    let security: MICESecurity
    private(set) var tunnel: DTLSTunnel?

    private var connection: NWConnection?
    private var buffer = Data()
    private let queue: DispatchQueue
    private var stopped = false
    private var rtspPort: UInt16 = 7236
    private var localIP = ""
    private var sentPINHash: Data?
    private var encryptsMessages: Bool { security == .pin && tunnel?.isReady == true }

    init(host: String, port: UInt16, friendlyName: String, sourceID: Data,
         security: MICESecurity = .none, queue: DispatchQueue) {
        self.host = host
        self.port = port
        self.friendlyName = friendlyName
        self.sourceID = MICEMessage.normalizedSourceID(sourceID)
        self.security = security
        self.queue = queue
    }

    func connect(rtspPort: UInt16) {
        self.rtspPort = rtspPort
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = 8
            tcp.noDelay = true
        }
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port)!,
                                using: params)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if case .hostPort(let h, _)? = conn.currentPath?.localEndpoint {
                    self.localIP = "\(h)".components(separatedBy: "%").first ?? "\(h)"
                }
                Log.info("MICE", "Connected to \(self.host):\(self.port) (security: \(self.security.rawValue))")
                self.onConnected?()
                self.receive()
                self.begin()
            case .waiting(let err):
                // .waiting means the connect attempt failed but NW would retry later;
                // for a projection that is a hard failure.
                Log.error("MICE", "Cannot reach \(self.host):\(self.port) — \(err)")
                self.fail(err)
            case .failed(let err):
                Log.error("MICE", "Connection failed: \(err)")
                self.fail(err)
            default:
                break
            }
        }
        connection = conn
        conn.start(queue: queue)
    }

    // Politely ends the projection, then closes the socket.
    func stop() {
        guard !stopped else { return }
        stopped = true
        guard let conn = connection else { tunnel?.stop(); return }
        connection = nil
        let msg = MICEMessage.stopProjection(friendlyName: friendlyName, sourceID: sourceID)
        Log.info("MICE", "→ STOP_PROJECTION")
        let finish: (Data) -> Void = { [tunnel] data in
            Log.debug("MICE", "STOP_PROJECTION on the wire (\(data.count) bytes), conn state \(conn.state)")
            conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
            tunnel?.stop()
        }
        if encryptsMessages, let tunnel {
            tunnel.encrypt(msg.tlvBytes) { record in
                finish(MICEMessage.serialize(command: msg.command, body: record))
            }
            // Don't hang on shutdown if encryption never completes.
            queue.asyncAfter(deadline: .now() + 1) { conn.cancel() }
        } else {
            finish(msg.serialize())
        }
    }

    // MARK: - Flow

    private func begin() {
        switch security {
        case .none:
            sendSourceReady()
        case .encrypted:
            startDTLS()
        case .pin:
            send(.sessionRequest(friendlyName: friendlyName, sourceID: sourceID,
                                 options: [.streamEncryption, .sinkDisplaysPin]))
            startDTLS()
        }
    }

    private func startDTLS() {
        let t = DTLSTunnel(queue: queue)
        t.onHandshakeToken = { [weak self] token in
            guard let self else { return }
            self.send(.securityHandshake(token: token, sourceID: self.sourceID), quiet: true)
        }
        t.onReady = { [weak self] in
            guard let self else { return }
            if self.security == .pin { self.requestPIN() } else { self.sendSourceReady() }
        }
        t.onFailed = { [weak self] err in self?.fail(err) }
        tunnel = t
        Log.info("MICE", "Starting DTLS handshake")
        t.start()
    }

    private func requestPIN() {
        guard let pinProvider else {
            fail(MICEError.pinRejected("no way to ask for the PIN (pass --pin in the CLI)"))
            return
        }
        Log.info("MICE", "Waiting for the PIN shown on the display…")
        pinProvider { [weak self] pin in
            guard let self else { return }
            self.queue.async {
                guard let pin = pin?.trimmingCharacters(in: .whitespacesAndNewlines), !pin.isEmpty else {
                    self.fail(MICEError.pinCancelled); return
                }
                guard let hash = MICEMessage.pinHash(pin: pin, senderIP: self.localIP) else {
                    self.fail(MICEError.pinRejected("could not determine this Mac's IP address")); return
                }
                self.sentPINHash = hash
                self.send(.pinChallenge(pinHash: hash, sourceID: self.sourceID))
            }
        }
    }

    private func handlePINResponse(_ msg: MICEMessage) {
        let reason = msg.pinResponseReason
        Log.info("MICE", "PIN response: \(reason.map { "\($0)" } ?? "missing reason")")
        switch reason {
        case .accepted:
            // 3.2.5.6: the echoed hash must match what we sent.
            if let echoed = msg.value(.pinChallenge), let sent = sentPINHash, echoed != sent {
                fail(MICEError.pinRejected("display echoed a different PIN hash"))
                return
            }
            sendSourceReady()
        case .wrongPIN:
            fail(MICEError.wrongPIN)
        default:
            fail(MICEError.pinRejected("display answered \(reason.map { "\($0)" } ?? "without a reason")"))
        }
    }

    private func sendSourceReady() {
        send(.sourceReady(friendlyName: friendlyName, rtspPort: rtspPort, sourceID: sourceID))
        onSourceReady?()
    }

    // MARK: - Sending

    private func send(_ msg: MICEMessage, quiet: Bool = false) {
        if encryptsMessages, let tunnel {
            tunnel.encrypt(msg.tlvBytes) { [weak self] record in
                let data = MICEMessage.serialize(command: msg.command, body: record)
                Log.info("MICE", "→ \(msg.commandName) (encrypted, \(data.count) bytes)")
                self?.write(data)
            }
            return
        }
        let data = msg.serialize()
        if quiet { Log.debug("MICE", "→ \(msg.commandName) (\(data.count) bytes)") }
        else { Log.info("MICE", "→ \(msg.commandName) (\(data.count) bytes)") }
        Log.debug("MICE", "  \(data.prefix(96).hexString)\(data.count > 96 ? " …" : "")")
        write(data)
    }

    private func write(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { err in
            if let err { Log.error("MICE", "Send failed: \(err)") }
        })
    }

    // MARK: - Receiving

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, err in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if let err { self.fail(err); return }
            if isComplete {
                // Only an explicit STOP_PROJECTION ends the projection. A bare close is
                // logged but not fatal: the RTSP session (keep-alives, TEARDOWN)
                // decides whether the stream is alive.
                if !self.stopped {
                    Log.warn("MICE", "Sink closed the signalling connection without STOP_PROJECTION; continuing")
                    self.connection?.cancel()
                    self.connection = nil
                }
                return
            }
            self.receive()
        }
    }

    private func drain() {
        do {
            while let frame = try MICEMessage.extractFrame(from: &buffer) {
                handle(frame)
            }
        } catch {
            Log.warn("MICE", "Unparseable data from sink (\(error)); discarding \(buffer.count) bytes")
            buffer.removeAll()
        }
    }

    private func handle(_ frame: MICEMessage.Frame) {
        let name = MICEMessage(command: frame.command, tlvs: []).commandName
        // Handshake tokens are never encrypted.
        if frame.command == MICEMessage.Command.securityHandshake.rawValue {
            guard let tlvs = try? MICEMessage.parseTLVs(frame.body),
                  let token = tlvs.first(where: { $0.type == MICEMessage.TLVType.securityToken.rawValue })?.value else {
                Log.warn("MICE", "SECURITY_HANDSHAKE without a Security Token TLV")
                return
            }
            tunnel?.receiveHandshakeToken(token)
            return
        }

        let process: (Data) -> Void = { [weak self] body in
            guard let self else { return }
            guard let tlvs = try? MICEMessage.parseTLVs(body) else {
                Log.warn("MICE", "← \(name) with malformed TLVs: \(body.prefix(64).hexString)")
                return
            }
            let msg = MICEMessage(version: frame.version, command: frame.command, tlvs: tlvs)
            Log.info("MICE", "← \(name)")
            switch MICEMessage.Command(rawValue: frame.command) {
            case .stopProjection:
                if !self.stopped { self.stopped = true; self.onStopProjection?() }
            case .pinResponse:
                self.handlePINResponse(msg)
            default:
                break
            }
        }

        if encryptsMessages, let tunnel {
            tunnel.decrypt(frame.body) { [weak self] plain in
                guard let plain else {
                    // A STOP_PROJECTION we can't read is still a stop.
                    if frame.command == MICEMessage.Command.stopProjection.rawValue, let self, !self.stopped {
                        self.stopped = true; self.onStopProjection?()
                    } else {
                        self?.fail(MICEError.unexpected("Could not decrypt \(name) from the display"))
                    }
                    return
                }
                self?.queue.async { process(plain) }
            }
        } else {
            process(frame.body)
        }
    }

    private func fail(_ err: Error) {
        guard !stopped else { return }
        stopped = true
        connection?.cancel()
        connection = nil
        tunnel?.stop()
        onError?(err)
    }
}
