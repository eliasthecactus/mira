import Foundation
import Network

// WFD RTSP state machine.
// Source (Mac) TCP-connects to Sink (adapter) on port 7236.
// Sink sends OPTIONS first; handshake proceeds to PLAY.
final class WFDSession {

    enum State: String {
        case idle, connecting, waitingOptions, waitingGetParam
        case sendingSetupTrigger, waitingSetup, waitingPlay
        case streaming, teardown
    }

    // Called when session reaches .streaming
    var onReady: ((_ sinkIP: String, _ sinkRTPPort: UInt16) -> Void)?
    var onError: ((Error) -> Void)?

    private let device: MiracastDevice
    private var connection: NWConnection!
    private var state: State = .idle
    private var cseq = 0
    private let sessionID: String
    private var sinkRTPPort: UInt16 = 1990
    private var buffer = Data()
    private let queue = DispatchQueue(label: "mira.wfd", qos: .userInteractive)
    private var keepaliveTimer: DispatchSourceTimer?

    init(device: MiracastDevice) {
        self.device = device
        self.sessionID = String(UInt32.random(in: 1_000_000...9_999_999))
    }

    func connect() {
        let host = NWEndpoint.Host(device.ipAddress)
        let port = NWEndpoint.Port(rawValue: device.port)!
        connection = NWConnection(host: host, port: port, using: .tcp)
        connection.stateUpdateHandler = { [weak self] s in self?.connectionStateChanged(s) }
        state = .connecting
        connection.start(queue: queue)
        receiveNext()
    }

    func disconnect() {
        keepaliveTimer?.cancel()
        sendTeardown()
    }

    // MARK: - Connection state

    private func connectionStateChanged(_ s: NWConnection.State) {
        switch s {
        case .ready:
            state = .waitingOptions
            print("[WFD] Connected to \(device) — waiting for OPTIONS")
        case .failed(let err):
            print("[WFD] Connection failed: \(err)")
            onError?(err)
        case .cancelled:
            state = .teardown
        default:
            break
        }
    }

    // MARK: - Receive loop

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isDone, err in
            guard let self else { return }
            if let data { self.buffer.append(data); self.drain() }
            if let err { self.onError?(err); return }
            if !isDone { self.receiveNext() }
        }
    }

    private func drain() {
        while let msg = nextMessage() { dispatch(msg) }
    }

    private func nextMessage() -> RTSPMessage? {
        let boundary = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let range = buffer.range(of: boundary) else { return nil }

        // Peek at Content-Length to know total byte count
        let headerData = buffer.prefix(range.lowerBound)
        let headerText = String(data: headerData, encoding: .utf8) ?? ""
        let contentLength = headerText.components(separatedBy: "\r\n")
            .compactMap { line -> Int? in
                let l = line.lowercased()
                guard l.hasPrefix("content-length:") else { return nil }
                return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            }.first ?? 0

        let total = range.upperBound + contentLength
        guard buffer.count >= total else { return nil }

        let msgData = buffer.prefix(total)
        buffer = buffer.dropFirst(total)
        return RTSPMessage.parse(from: Data(msgData))
    }

    // MARK: - Dispatch

    private func dispatch(_ msg: RTSPMessage) {
        print("[WFD] ← \(msg.debugDescription)")
        switch state {
        case .waitingOptions:     handleOptions(msg)
        case .waitingGetParam:    handleGetParameter(msg)
        case .sendingSetupTrigger: handleSetupTriggerAck(msg)
        case .waitingSetup:       handleSetup(msg)
        case .waitingPlay:        handlePlay(msg)
        case .streaming:          handleStreamingMessage(msg)
        default:                  break
        }
    }

    // MARK: - Handshake handlers

    private func handleOptions(_ msg: RTSPMessage) {
        guard case .request(let m, _) = msg.kind, m == "OPTIONS", let seq = msg.cseq else { return }
        send(.ok(cseq: seq, extra: [
            ("Public", "org.wfa.wfd1.0, GET_PARAMETER, SET_PARAMETER"),
            ("Require", "org.wfa.wfd1.0")
        ]))
        state = .waitingGetParam
    }

    private func handleGetParameter(_ msg: RTSPMessage) {
        guard case .request(let m, _) = msg.kind, m == "GET_PARAMETER", let seq = msg.cseq else { return }
        let requested = (msg.body ?? "")
            .components(separatedBy: "\r\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let body = WFDCapabilities.responseBody(for: requested)
        send(.ok(cseq: seq, body: body.isEmpty ? nil : body))
        state = .sendingSetupTrigger
        sendSetupTrigger()
    }

    private func sendSetupTrigger() {
        cseq += 1
        send(.request(method: "SET_PARAMETER", uri: "rtsp://localhost/wfd1.0",
                      cseq: cseq, body: "wfd_trigger_method: SETUP\r\n"))
    }

    private func handleSetupTriggerAck(_ msg: RTSPMessage) {
        guard case .response(let code, _) = msg.kind, code == 200 else { return }
        state = .waitingSetup
        print("[WFD] SETUP trigger ACK'd — waiting for SETUP from sink")
    }

    private func handleSetup(_ msg: RTSPMessage) {
        guard case .request(let m, _) = msg.kind, m == "SETUP", let seq = msg.cseq else { return }
        let transport = msg.header("Transport") ?? ""
        sinkRTPPort = WFDCapabilities.parseClientPort(transport: transport)
        print("[WFD] Sink RTP port: \(sinkRTPPort)")
        send(.ok(cseq: seq, extra: [
            ("Session", "\(sessionID);timeout=60"),
            ("Transport", "RTP/AVP/UDP;unicast;client_port=\(sinkRTPPort);server_port=\(WFDCapabilities.rtpVideoPort)")
        ]))
        state = .waitingPlay
    }

    private func handlePlay(_ msg: RTSPMessage) {
        guard case .request(let m, _) = msg.kind, m == "PLAY", let seq = msg.cseq else { return }
        send(.ok(cseq: seq, extra: [("Session", sessionID)]))
        state = .streaming
        print("[WFD] Session LIVE — streaming to \(device.ipAddress):\(sinkRTPPort)")
        startKeepalive()
        onReady?(device.ipAddress, sinkRTPPort)
    }

    private func handleStreamingMessage(_ msg: RTSPMessage) {
        // Respond to keepalive GET_PARAMETER from sink
        if case .request(let m, _) = msg.kind, m == "GET_PARAMETER", let seq = msg.cseq {
            send(.ok(cseq: seq, extra: [("Session", sessionID)]))
        }
        // Respond to ACKs for our own keepalives
    }

    // MARK: - Keepalive

    private func startKeepalive() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.sendKeepalive() }
        timer.resume()
        keepaliveTimer = timer
    }

    private func sendKeepalive() {
        cseq += 1
        send(.request(method: "GET_PARAMETER", uri: "rtsp://localhost/wfd1.0",
                      cseq: cseq, extra: [("Session", sessionID)]))
    }

    private func sendTeardown() {
        cseq += 1
        send(.request(method: "TEARDOWN", uri: "rtsp://localhost/wfd1.0",
                      cseq: cseq, extra: [("Session", sessionID)]))
        connection?.cancel()
    }

    // MARK: - Send

    private func send(_ msg: RTSPMessage) {
        print("[WFD] → \(msg.debugDescription)")
        let data = msg.serialize()
        connection.send(content: data, completion: .contentProcessed { err in
            if let err { print("[WFD] Send error: \(err)") }
        })
    }
}
