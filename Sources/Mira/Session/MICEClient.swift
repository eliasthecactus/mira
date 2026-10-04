import Foundation
import Network

// MS-MICE signalling channel: TCP from the Mac to the sink's port 7250.
//
// Flow: connect → send SOURCE_READY (friendly name, our RTSP port, source ID) →
// the sink then opens a TCP connection *back to us* on that RTSP port. The 7250
// connection stays open for the whole session; either side may send
// STOP_PROJECTION on it to end the projection.
final class MICEClient {

    var onConnected: (() -> Void)?
    var onStopProjection: (() -> Void)?
    var onError: ((Error) -> Void)?

    let host: String
    let port: UInt16
    let friendlyName: String
    let sourceID: Data

    private var connection: NWConnection?
    private var buffer = Data()
    private let queue: DispatchQueue
    private var stopped = false

    init(host: String, port: UInt16, friendlyName: String, sourceID: Data, queue: DispatchQueue) {
        self.host = host
        self.port = port
        self.friendlyName = friendlyName
        self.sourceID = MICEMessage.normalizedSourceID(sourceID)
        self.queue = queue
    }

    func connect() {
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
                Log.info("MICE", "Connected to \(self.host):\(self.port)")
                self.onConnected?()
                self.receive()
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

    func sendSourceReady(rtspPort: UInt16) {
        let msg = MICEMessage.sourceReady(friendlyName: friendlyName, rtspPort: rtspPort, sourceID: sourceID)
        send(msg)
    }

    // Politely ends the projection, then closes the socket.
    func stop() {
        guard !stopped else { return }
        stopped = true
        guard let conn = connection else { return }
        let msg = MICEMessage.stopProjection(friendlyName: friendlyName, sourceID: sourceID)
        Log.info("MICE", "→ STOP_PROJECTION")
        conn.send(content: msg.serialize(), completion: .contentProcessed { _ in conn.cancel() })
        connection = nil
    }

    private func send(_ msg: MICEMessage) {
        let data = msg.serialize()
        Log.info("MICE", "→ \(msg.commandName) (\(data.count) bytes)")
        Log.debug("MICE", "  \(data.hexString)")
        connection?.send(content: data, completion: .contentProcessed { err in
            if let err { Log.error("MICE", "Send failed: \(err)") }
        })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, err in
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
            while let msg = try MICEMessage.extract(from: &buffer) {
                Log.info("MICE", "← \(msg.commandName)")
                if msg.command == MICEMessage.Command.stopProjection.rawValue, !stopped {
                    stopped = true
                    onStopProjection?()
                }
            }
        } catch {
            Log.warn("MICE", "Unparseable data from sink (\(error)); discarding \(buffer.count) bytes")
            buffer.removeAll()
        }
    }

    private func fail(_ err: Error) {
        guard !stopped else { return }
        stopped = true
        connection?.cancel()
        connection = nil
        onError?(err)
    }
}
