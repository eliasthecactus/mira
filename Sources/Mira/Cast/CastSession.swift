import Foundation

// Google Cast mirroring session control:
//   1. TLS to the device, CONNECT to "receiver-0"
//   2. LAUNCH the built-in mirroring receiver app (0F5096E8, audio+video)
//   3. RECEIVER_STATUS names the app's sessionId and transportId; CONNECT to it
//   4. OFFER (urn:x-cast:com.google.cast.webrtc) -> ANSWER with UDP port and SSRCs
//   5. stream; STOP ends the app when Mira stops
final class CastSession {

    enum SessionError: LocalizedError, Equatable {
        case launchFailed(String)
        case answerRejected(String)
        case timeout(String)
        case appStopped

        var errorDescription: String? {
            switch self {
            case .launchFailed(let why): return "The Cast device would not start screen mirroring (\(why))"
            case .answerRejected(let why): return "The Cast device rejected the stream (\(why))"
            case .timeout(let what): return "The Cast device did not answer \(what)"
            case .appStopped: return "Mirroring was stopped on the Cast device"
            }
        }
    }

    static let mirroringAppID = "0F5096E8"
    static let audioOnlyAppID = "85CDB22F"

    // The offer to send once the mirroring app runs (built by the controller).
    var makeOffer: (() -> CastOffer)?
    var onAnswer: ((CastOffer, CastAnswer) -> Void)?
    var onClosed: ((Error?) -> Void)?

    let host: String
    private let queue: DispatchQueue
    private let channel: CastChannel
    private let senderID = "sender-mira-\(Int.random(in: 10_000...99_999))"
    private var requestID = 1
    private var appSessionID: String?
    private var transportID: String?
    private var offer: CastOffer?
    private var offerSeq = 0
    private var answered = false
    private var closed = false
    private var timeoutWork: DispatchWorkItem?

    init(host: String, port: UInt16 = CastChannel.defaultPort, queue: DispatchQueue) {
        self.host = host
        self.queue = queue
        channel = CastChannel(host: host, port: port, queue: queue)
    }

    func start() {
        channel.onMessage = { [weak self] m in self?.handle(m) }
        channel.onClosed = { [weak self] err in self?.finish(err) }
        channel.connect { [weak self] in
            guard let self else { return }
            self.send(self.connectMessage(), ns: CastMessage.connection, to: CastMessage.platformReceiver,
                      from: CastMessage.platformSender)
            self.send(["type": "LAUNCH", "requestId": self.nextRequestID(), "appId": Self.mirroringAppID,
                       "language": "en-US", "supportedAppTypes": ["WEB"]],
                      ns: CastMessage.receiver, to: CastMessage.platformReceiver, from: CastMessage.platformSender)
            Log.info("Cast", "Launching the screen mirroring receiver")
            self.armTimeout(15, "the request to start mirroring")
        }
    }

    // Stops the mirroring app on the device and closes the connection.
    func stop() {
        queue.async { [self] in
            guard !closed else { return }
            if let appSessionID {
                send(["type": "STOP", "requestId": nextRequestID(), "sessionId": appSessionID],
                     ns: CastMessage.receiver, to: CastMessage.platformReceiver, from: CastMessage.platformSender)
            }
            if let transportID {
                send(["type": "CLOSE"], ns: CastMessage.connection, to: transportID, from: senderID)
            }
            // Give the messages a moment to leave before the TLS connection closes.
            queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.finish(nil) }
        }
    }

    // MARK: - Messages

    private func nextRequestID() -> Int {
        requestID += 1
        return requestID
    }

    private func connectMessage() -> [String: Any] {
        ["type": "CONNECT", "connType": 0, "origin": [String: Any](),
         "userAgent": "Mira/\(AppInfo.version)",
         "senderInfo": ["sdkType": 2, "version": AppInfo.version, "browserVersion": AppInfo.version,
                        "platform": 4, "connectionType": 1] as [String: Any]]
    }

    private func send(_ json: [String: Any], ns: String, to: String, from: String) {
        channel.send(.json(json, namespace: ns, from: from, to: to))
    }

    private func handle(_ m: CastMessage) {
        guard let json = m.json, let type = m.type else { return }
        switch (m.namespace, type) {
        case (CastMessage.receiver, "RECEIVER_STATUS"):
            receiverStatus(json)
        case (CastMessage.receiver, "LAUNCH_ERROR"):
            finish(SessionError.launchFailed((json["reason"] as? String) ?? "unknown reason"))
        case (CastMessage.receiver, "INVALID_REQUEST"):
            Log.warn("Cast", "Device says our request is invalid: \((json["reason"] as? String) ?? "?")")
        case (CastMessage.webrtc, "ANSWER"):
            answer(json)
        case (CastMessage.connection, "CLOSE") where m.sourceID == transportID:
            Log.info("Cast", "The mirroring receiver closed the connection")
            finish(nil)
        default:
            break
        }
    }

    private func receiverStatus(_ json: [String: Any]) {
        let apps = ((json["status"] as? [String: Any])?["applications"] as? [[String: Any]]) ?? []
        guard let app = apps.first(where: { ($0["appId"] as? String) == Self.mirroringAppID }) else {
            if appSessionID != nil {
                // Our app is gone: stopped from the TV, the remote, or another sender.
                // That's a normal end, not an error.
                Log.info("Cast", "Mirroring was stopped on the Cast device")
                finish(nil)
            }
            return
        }
        guard transportID == nil else { return }
        guard let session = app["sessionId"] as? String, let transport = app["transportId"] as? String else {
            finish(SessionError.launchFailed("no session or transport ID"))
            return
        }
        appSessionID = session
        transportID = transport
        Log.info("Cast", "Mirroring receiver running (session \(session.prefix(8))...); sending OFFER")
        send(connectMessage(), ns: CastMessage.connection, to: transport, from: senderID)
        guard let offer = makeOffer?() else { finish(SessionError.launchFailed("no offer")); return }
        self.offer = offer
        offerSeq = nextRequestID()
        send(["type": "OFFER", "seqNum": offerSeq, "offer": offer.json], ns: CastMessage.webrtc, to: transport, from: senderID)
        armTimeout(10, "the stream offer")
    }

    private func answer(_ json: [String: Any]) {
        guard !answered, let offer else { return }
        if let seq = (json["seqNum"] as? NSNumber)?.intValue, seq != offerSeq { return }
        timeoutWork?.cancel()
        switch CastAnswer.parse(json) {
        case .failure(let err):
            finish(err)
        case .success(let a):
            answered = true
            let picked = a.sendIndexes.compactMap { i in offer.streams.first { $0.index == i } }
            Log.info("Cast", "ANSWER: UDP port \(a.udpPort), streams \(picked.map(\.codecName).joined(separator: " + "))"
                     + (a.maxWidth.map { ", max \($0)x\(a.maxHeight ?? 0)" } ?? "")
                     + (a.maxVideoBitRate.map { ", max \($0 / 1000) kbps" } ?? ""))
            onAnswer?(offer, a)
        }
    }

    private func armTimeout(_ seconds: Double, _ what: String) {
        timeoutWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.finish(SessionError.timeout(what)) }
        timeoutWork = w
        queue.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        timeoutWork?.cancel()
        channel.onClosed = nil
        channel.close()
        if let error { Log.error("Cast", error.localizedDescription) } else { Log.info("Cast", "Session closed") }
        onClosed?(error)
    }
}
