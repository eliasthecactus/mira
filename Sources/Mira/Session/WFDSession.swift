import Foundation
import Network

// Wi-Fi Display source-side RTSP session.
//
// In Miracast the *source* (the Mac) is the RTSP server: it listens on TCP 7236
// and the sink connects in (for MS-MICE, after we send SOURCE_READY). The source
// then drives capability negotiation:
//
//   M1  source → sink  OPTIONS *                      (Require: org.wfa.wfd1.0)
//   M2  sink → source  OPTIONS *
//   M3  source → sink  GET_PARAMETER                  (ask sink capabilities)
//   M4  source → sink  SET_PARAMETER                  (chosen format, presentation URL)
//   M5  source → sink  SET_PARAMETER wfd_trigger_method: SETUP
//   M6  sink → source  SETUP  .../streamid=0          (Transport: client_port=…)
//   M7  sink → source  PLAY
//   ··· RTP (MPEG-2 TS) flows to the sink ···
//   M16 source → sink  GET_PARAMETER (empty)          keep-alive, before the session timeout
//   M5  source → sink  SET_PARAMETER wfd_trigger_method: TEARDOWN, then
//   M8  sink → source  TEARDOWN
final class WFDSession {

    enum State: String {
        case idle, listening, connected, negotiating, awaitingSetup, awaitingPlay, playing, paused, closed
    }

    enum SessionError: LocalizedError {
        case listenFailed(Error)
        case sinkNeverConnected(TimeInterval)
        case timeout(String)
        case rejected(String, Int)
        case connectionLost(String)

        var errorDescription: String? {
            switch self {
            case .listenFailed(let e):
                return "Could not listen for RTSP: \(e)"
            case .sinkNeverConnected(let t):
                return "Sink did not connect back to the RTSP port within \(Int(t))s. Most likely the macOS firewall is blocking incoming connections, or the sink rejected SOURCE_READY."
            case .timeout(let what):
                return "Sink did not answer \(what)"
            case .rejected(let what, let code):
                return "Sink rejected \(what) with status \(code)"
            case .connectionLost(let why):
                return "RTSP connection lost: \(why)"
            }
        }
    }

    // Called once the sink sent PLAY. Media should start flowing to sinkIP:format.rtpPort0.
    var onPlay: ((_ format: WFDNegotiatedFormat, _ sinkIP: String, _ rtpPort: UInt16, _ rtcpPort: UInt16?) -> Void)?
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
    var onIDRRequest: (() -> Void)?
    var onClosed: ((Error?) -> Void)?

    let rtspPort: UInt16
    let serverRTPPort: UInt16
    let prefs: StreamPreferences

    private(set) var state: State = .idle
    private(set) var negotiated: WFDNegotiatedFormat?
    private(set) var sinkCapabilities: WFDSinkCapabilities?

    private let queue: DispatchQueue
    private var listener: NWListener?
    private var connection: NWConnection?
    private var buffer = Data()
    private var cseq = 0
    private let sessionID = String(UInt32.random(in: 10_000_000...99_999_999))
    private let sessionTimeout = 30
    private var pending: [Int: (name: String, handler: (RTSPMessage) -> Void)] = [:]
    private var pendingTimers: [Int: DispatchWorkItem] = [:]
    private var keepaliveTimer: DispatchSourceTimer?
    private var connectTimeout: DispatchWorkItem?
    private var gotM1Reply = false
    private var gotM2 = false
    private var sentM3 = false
    private var sinkIP = ""
    private var localIP = ""
    private var rtcpPort: UInt16?
    private var teardownRequested = false

    init(rtspPort: UInt16 = 7236, serverRTPPort: UInt16, prefs: StreamPreferences, queue: DispatchQueue) {
        self.rtspPort = rtspPort
        self.serverRTPPort = serverRTPPort
        self.prefs = prefs
        self.queue = queue
    }

    // MARK: - Lifecycle

    // Starts listening. `ready` fires once the port is bound (before SOURCE_READY is sent).
    func listen(connectTimeout seconds: TimeInterval = 15, ready: @escaping () -> Void) {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcp.noDelay = true
            }
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: rtspPort)!)
            l.stateUpdateHandler = { [weak self] s in
                guard let self else { return }
                switch s {
                case .ready:
                    Log.info("RTSP", "Listening on TCP \(self.rtspPort)")
                    self.state = .listening
                    let t = DispatchWorkItem { [weak self] in
                        guard let self, self.connection == nil, self.state == .listening else { return }
                        self.close(error: SessionError.sinkNeverConnected(seconds))
                    }
                    self.connectTimeout = t
                    self.queue.asyncAfter(deadline: .now() + seconds, execute: t)
                    ready()
                case .failed(let err):
                    Log.error("RTSP", "Listener failed: \(err)")
                    self.close(error: SessionError.listenFailed(err))
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener = l
            l.start(queue: queue)
        } catch {
            close(error: SessionError.listenFailed(error))
        }
    }

    // Asks the sink to tear down (M5 TEARDOWN trigger); closes after a short grace period.
    func teardown() {
        guard state != .closed else { return }
        guard connection != nil, [.awaitingSetup, .awaitingPlay, .playing, .paused].contains(state) else {
            close(error: nil)
            return
        }
        teardownRequested = true
        sendRequest("SET_PARAMETER", name: "M5 (TEARDOWN trigger)",
                    body: "wfd_trigger_method: TEARDOWN\r\n") { _ in }
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.close(error: nil) }
    }

    func requestIDR() { onIDRRequest?() }

    private func close(error: Error?) {
        guard state != .closed else { return }
        state = .closed
        keepaliveTimer?.cancel(); keepaliveTimer = nil
        connectTimeout?.cancel(); connectTimeout = nil
        pendingTimers.values.forEach { $0.cancel() }
        pendingTimers.removeAll(); pending.removeAll()
        connection?.cancel(); connection = nil
        listener?.cancel(); listener = nil
        if let error { Log.error("RTSP", error.localizedDescription) } else { Log.info("RTSP", "Session closed") }
        onClosed?(error)
    }

    // MARK: - Connection

    private func accept(_ conn: NWConnection) {
        guard connection == nil else {
            Log.warn("RTSP", "Rejecting extra connection from \(conn.endpoint)")
            conn.cancel()
            return
        }
        connectTimeout?.cancel()
        connection = conn
        if case .hostPort(let host, _) = conn.endpoint { sinkIP = Self.ipString(host) }
        Log.info("RTSP", "Sink connected from \(sinkIP)")

        conn.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            switch s {
            case .ready:
                if case .hostPort(let host, _)? = conn.currentPath?.localEndpoint { self.localIP = Self.ipString(host) }
                self.state = .connected
                self.sendM1()
                self.receive()
            case .failed(let err):
                self.close(error: SessionError.connectionLost("\(err)"))
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private static func ipString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a):
            // IPv4-mapped IPv6 (::ffff:a.b.c.d) → a.b.c.d
            let s = "\(a)".components(separatedBy: "%").first ?? "\(a)"
            return s.hasPrefix("::ffff:") ? String(s.dropFirst(7)) : s
        case .name(let n, _): return n
        @unknown default: return "\(host)"
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, err in
            guard let self, self.state != .closed else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                while let msg = RTSPMessage.extract(from: &self.buffer) { self.handle(msg) }
            }
            if let err { self.close(error: SessionError.connectionLost("\(err)")); return }
            if isComplete {
                self.close(error: self.teardownRequested ? nil : SessionError.connectionLost("sink closed the connection"))
                return
            }
            self.receive()
        }
    }

    // MARK: - Sending

    private func send(_ msg: RTSPMessage) {
        Log.info("RTSP", "→ \(msg.summary)")
        Log.debug("RTSP", "\n" + msg.fullText)
        connection?.send(content: msg.serialize(), completion: .contentProcessed { err in
            if let err { Log.error("RTSP", "Send failed: \(err)") }
        })
    }

    private func sendRequest(_ method: String, uri: String = "rtsp://localhost/wfd1.0", name: String,
                             headers: [(String, String)] = [], body: String? = nil,
                             timeout: TimeInterval = 6, handler: @escaping (RTSPMessage) -> Void) {
        cseq += 1
        let seq = cseq
        pending[seq] = (name, handler)
        let t = DispatchWorkItem { [weak self] in
            guard let self, self.pending[seq] != nil else { return }
            self.close(error: SessionError.timeout(name))
        }
        pendingTimers[seq] = t
        queue.asyncAfter(deadline: .now() + timeout, execute: t)
        send(.request(method: method, uri: uri, cseq: seq, extra: headers, body: body))
    }

    // MARK: - Dispatch

    private func handle(_ msg: RTSPMessage) {
        Log.info("RTSP", "← \(msg.summary)")
        Log.debug("RTSP", "\n" + msg.fullText)
        switch msg.kind {
        case .response:
            guard let seq = msg.cseq, let p = pending.removeValue(forKey: seq) else {
                Log.warn("RTSP", "Unexpected response (CSeq \(msg.cseq ?? -1))")
                return
            }
            pendingTimers.removeValue(forKey: seq)?.cancel()
            p.handler(msg)
        case .request(let method, _):
            handleRequest(method.uppercased(), msg)
        }
    }

    private func handleRequest(_ method: String, _ msg: RTSPMessage) {
        guard let seq = msg.cseq else {
            Log.warn("RTSP", "Request without CSeq ignored")
            return
        }
        switch method {
        case "OPTIONS":                          // M2
            send(.ok(cseq: seq, extra: [
                ("Public", "org.wfa.wfd1.0, SETUP, TEARDOWN, PLAY, PAUSE, GET_PARAMETER, SET_PARAMETER"),
            ]))
            gotM2 = true
            maybeSendM3()

        case "SETUP":                            // M6
            let transport = msg.header("Transport") ?? ""
            guard let ports = RTSPTransport.clientPorts(transport) else {
                Log.error("RTSP", "SETUP without usable client_port: \(transport)")
                send(.response(461, "Unsupported Transport", cseq: seq))
                return
            }
            if transport.uppercased().contains("RTP/AVP/TCP") {
                Log.warn("RTSP", "Sink asked for RTP over TCP; only UDP is implemented")
            }
            if var n = negotiated, n.rtpPort0 != ports.rtp {
                Log.info("RTSP", "SETUP overrides RTP port \(n.rtpPort0) → \(ports.rtp)")
                n.rtpPort0 = ports.rtp
                negotiated = n
            }
            rtcpPort = ports.rtcp
            let clientPort = ports.rtcp.map { "\(ports.rtp)-\($0)" } ?? "\(ports.rtp)"
            send(.ok(cseq: seq, extra: [
                ("Session", "\(sessionID);timeout=\(sessionTimeout)"),
                ("Transport", "RTP/AVP/UDP;unicast;client_port=\(clientPort);server_port=\(serverRTPPort)-\(serverRTPPort + 1)"),
            ]))
            state = .awaitingPlay

        case "PLAY":                             // M7 (or resume after PAUSE)
            send(.ok(cseq: seq, extra: [("Session", sessionID), ("Range", "npt=now-")]))
            if state == .paused {
                state = .playing
                onResume?()
            } else if state != .playing, let n = negotiated {
                state = .playing
                startKeepalive()
                Log.info("RTSP", "PLAY — streaming \(n.resolution) to \(sinkIP):\(n.rtpPort0)")
                onPlay?(n, sinkIP, n.rtpPort0, rtcpPort)
            }

        case "PAUSE":                            // M9
            send(.ok(cseq: seq, extra: [("Session", sessionID)]))
            if state == .playing { state = .paused; onPause?() }

        case "TEARDOWN":                         // M8
            send(.ok(cseq: seq, extra: [("Session", sessionID)]))
            teardownRequested = true
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.close(error: nil) }

        case "SET_PARAMETER":
            let params = WFDParameters.parse(msg.body ?? "")
            send(.ok(cseq: seq, extra: msg.header("Session") != nil ? [("Session", sessionID)] : []))
            if params["wfd_idr_request"] != nil {
                Log.info("RTSP", "Sink requested an IDR frame")
                onIDRRequest?()
            }

        case "GET_PARAMETER":                    // sink-side keep-alive
            send(.ok(cseq: seq, extra: [("Session", sessionID)]))

        default:
            send(.response(501, "Not Implemented", cseq: seq))
        }
    }

    // MARK: - Negotiation

    private func sendM1() {
        state = .negotiating
        sendRequest("OPTIONS", uri: "*", name: "M1 (OPTIONS)", headers: [("Require", "org.wfa.wfd1.0")]) { [weak self] resp in
            guard let self else { return }
            guard resp.statusCode == 200 else {
                self.close(error: SessionError.rejected("M1 OPTIONS", resp.statusCode ?? 0)); return
            }
            let pub = resp.header("Public") ?? ""
            if !pub.lowercased().contains("org.wfa.wfd1.0") {
                Log.warn("RTSP", "Sink's Public header lacks org.wfa.wfd1.0: \(pub)")
            }
            self.gotM1Reply = true
            self.maybeSendM3()
        }
        // Some sinks never send M2; don't wait on it forever.
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.gotM1Reply, !self.sentM3 else { return }
            Log.warn("RTSP", "No M2 OPTIONS from sink after 3s — continuing with M3")
            self.gotM2 = true
            self.maybeSendM3()
        }
    }

    private func maybeSendM3() {
        guard gotM1Reply, gotM2, !sentM3 else { return }
        sentM3 = true
        let body = [
            "wfd_video_formats",
            "wfd_audio_codecs",
            "wfd_client_rtp_ports",
            "wfd_content_protection",
        ].joined(separator: "\r\n") + "\r\n"
        sendRequest("GET_PARAMETER", name: "M3 (GET_PARAMETER)", body: body) { [weak self] resp in
            guard let self else { return }
            guard resp.statusCode == 200 else {
                self.close(error: SessionError.rejected("M3 GET_PARAMETER", resp.statusCode ?? 0)); return
            }
            let caps = WFDSinkCapabilities.parse(resp.body ?? "")
            self.sinkCapabilities = caps
            self.logCapabilities(caps)
            if let cp = caps.contentProtection, cp.lowercased() != "none" {
                Log.warn("RTSP", "Sink advertises content protection (\(cp)); Mira does not use HDCP, which is fine for mirroring")
            }
            guard caps.rtpPort0 != 0 else {
                self.close(error: SessionError.rejected("M3: sink reported no RTP port", 200)); return
            }
            let n = WFDNegotiatedFormat.choose(sink: caps, prefs: self.prefs)
            self.negotiated = n
            Log.info("RTSP", "Chose \(n.resolution), H.264 CBP level bit 0x\(String(n.levelBit, radix: 16)), audio: \(n.audio?.descriptor ?? "none")")
            self.sendM4(n)
        }
    }

    private func sendM4(_ n: WFDNegotiatedFormat) {
        let host = localIP.isEmpty ? "localhost" : localIP
        let url = "rtsp://\(host)/wfd1.0/streamid=0"
        sendRequest("SET_PARAMETER", name: "M4 (SET_PARAMETER)", body: n.m4Body(presentationURL: url)) { [weak self] resp in
            guard let self else { return }
            guard resp.statusCode == 200 else {
                self.close(error: SessionError.rejected("M4 SET_PARAMETER (format \(n.videoFormatsDescriptor))", resp.statusCode ?? 0)); return
            }
            self.sendM5Setup()
        }
    }

    private func sendM5Setup() {
        state = .awaitingSetup
        sendRequest("SET_PARAMETER", name: "M5 (SETUP trigger)", body: "wfd_trigger_method: SETUP\r\n") { [weak self] resp in
            guard let self else { return }
            guard resp.statusCode == 200 else {
                self.close(error: SessionError.rejected("M5 trigger", resp.statusCode ?? 0)); return
            }
            Log.info("RTSP", "Waiting for SETUP/PLAY from sink")
        }
    }

    private func logCapabilities(_ caps: WFDSinkCapabilities) {
        if let v = caps.videoFormats {
            for c in v.codecs {
                let res = WFDResolution.cea.filter { c.supports($0) }.map(\.description).joined(separator: " ")
                Log.info("RTSP", String(format: "Sink H.264 profile 0x%02X level 0x%02X, CEA: %@", c.profile, c.level, res))
            }
            if let native = v.nativeResolution { Log.info("RTSP", "Sink native resolution: \(native)") }
        } else {
            Log.warn("RTSP", "Sink sent no parsable wfd_video_formats: \(caps.raw["wfd_video_formats"] ?? "(missing)")")
        }
        Log.info("RTSP", "Sink audio: \(caps.audioCodecs.map(\.descriptor).joined(separator: ", ").nilIfEmpty ?? "none"); RTP port \(caps.rtpPort0)")
    }

    // MARK: - Keep-alive (M16)

    private func startKeepalive() {
        let interval = TimeInterval(sessionTimeout - 5)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.sendRequest("GET_PARAMETER", name: "M16 (keep-alive)",
                             headers: [("Session", self.sessionID)], timeout: 10) { _ in }
        }
        t.resume()
        keepaliveTimer = t
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
