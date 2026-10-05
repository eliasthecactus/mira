import Foundation

// Google Cast media transport: encrypted Cast Streaming RTP to the receiver's UDP
// port (one port for all streams), RTCP feedback back on the same socket.
final class CastTransport: MediaTransport, @unchecked Sendable {   // state confined to `queue`

    struct StreamSetup {
        var offer: CastStreamOffer
        var receiverSSRC: UInt32
    }

    var onLoss: ((Double) -> Void)?
    var onKeyframeRequest: (() -> Void)?

    let receiverIP: String
    let udpPort: UInt16
    private let video: CastStreamSender?
    private let audio: CastStreamSender?
    private let audioIsAAC: Bool
    private let queue = DispatchQueue(label: "mira.cast.rtp", qos: .userInteractive)
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var baseHost: Double?
    private var paused = false
    private var stopped = false
    private var lastSR: Double = 0
    private var sentFirstSR = Set<UInt32>()
    private var bytesSent: UInt64 = 0
    private var packetsSent: UInt64 = 0
    private var sendErrors: UInt64 = 0
    private var droppedReported = 0
    private var lastAudioRTP: Int64 = -1
    private var lastVideoRTP: Int64 = -1
    // Host clock -> wall clock, for NTP timestamps in sender reports.
    private let wallMinusHost = Date().timeIntervalSince1970 - MediaPipeline.hostNow()

    init(receiverIP: String, udpPort: UInt16, video: StreamSetup?, audio: StreamSetup?) {
        self.receiverIP = receiverIP
        self.udpPort = udpPort
        func sender(_ s: StreamSetup?) -> CastStreamSender? {
            guard let s else { return nil }
            return CastStreamSender(config: .init(
                ssrc: s.offer.ssrc, receiverSSRC: s.receiverSSRC, payloadType: s.offer.payloadType,
                timeBase: s.offer.timeBase, targetDelay: Double(s.offer.targetDelayMs) / 1000,
                aesKey: s.offer.aesKey, aesIvMask: s.offer.aesIvMask, isVideo: s.offer.kind == .video))
        }
        self.video = sender(video)
        self.audio = sender(audio)
        audioIsAAC = audio?.offer.codecName == "aac"
    }

    func start() throws {
        try queue.sync {
            let s = socket(AF_INET, SOCK_DGRAM, 0)
            guard s >= 0 else { throw TransportError.socket(errno) }
            var size: Int32 = 4 << 20
            setsockopt(s, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            var tos: Int32 = 0x88   // AF41: video
            setsockopt(s, IPPROTO_IP, IP_TOS, &tos, socklen_t(MemoryLayout<Int32>.size))
            var addr = DTLSTunnel.address(receiverIP, udpPort)
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard rc == 0 else { close(s); throw TransportError.socket(errno) }
            fd = s
            let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
            src.setEventHandler { [weak self] in self?.read() }
            src.resume()
            readSource = src
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            t.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
        video?.onPictureLost = { [weak self] in
            Log.info("Cast", "Receiver lost the picture; sending a keyframe")
            self?.onKeyframeRequest?()
        }
        for s in [video, audio].compactMap({ $0 }) {
            s.onLoss = { [weak self] f in self?.onLoss?(f) }
        }
        Log.info("Cast", "Streaming to \(receiverIP):\(udpPort)")
    }

    func beginClock(baseHost: Double) {
        queue.sync { self.baseHost = baseHost }
    }

    func sendVideo(_ accessUnit: Data, captureHost: Double, isKeyframe: Bool) -> Bool {
        guard let video else { return true }
        return queue.sync {
            guard let base = baseHost, !paused, !stopped else { return true }
            var rtp = Int64(((captureHost - base) * 90_000).rounded())
            if rtp <= lastVideoRTP { rtp = lastVideoRTP + 1 }
            lastVideoRTP = rtp
            let result = video.enqueue(accessUnit, rtpTimestamp: rtp, referenceTime: captureHost,
                                       isKey: isKeyframe, now: MediaPipeline.hostNow())
            if result == .ok { flush(video) }
            return result != .needsKeyframe
        }
    }

    func sendAudio(_ frame: Data, captureHost: Double) {
        guard let audio else { return }
        queue.async { [self] in
            guard let base = baseHost, !paused, !stopped else { return }
            // AAC goes out raw (no ADTS header).
            let payload = audioIsAAC && frame.count > 7 ? frame.dropFirst(7) : frame
            var rtp = Int64(((captureHost - base) * 48_000).rounded())
            if rtp <= lastAudioRTP { rtp = lastAudioRTP + 1 }
            lastAudioRTP = rtp
            if audio.enqueue(Data(payload), rtpTimestamp: rtp, referenceTime: captureHost,
                             isKey: true, now: MediaPipeline.hostNow()) == .ok {
                flush(audio)
            }
        }
    }

    func setPaused(_ p: Bool) {
        queue.async { self.paused = p }
    }

    func congestion(bitrate: Int) -> BitrateController.Signal? {
        queue.sync {
            let dropped = video?.framesDropped ?? 0
            defer { droppedReported = dropped }
            return dropped > droppedReported ? .framesDropped(dropped - droppedReported) : nil
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            timer?.cancel(); timer = nil
            readSource?.cancel(); readSource = nil
            if fd >= 0 { close(fd); fd = -1 }
        }
    }

    var counters: TransportCounters {
        queue.sync {
            TransportCounters(bytesSent: bytesSent, packetsSent: packetsSent, sendErrors: sendErrors,
                              retransmissions: (video?.retransmissions ?? 0) + (audio?.retransmissions ?? 0),
                              encrypted: true)
        }
    }

    // MARK: - Sending (queue)

    private func flush(_ s: CastStreamSender) {
        let now = MediaPipeline.hostNow()
        // The receiver drops the first packet of every frame until it has had a sender
        // report (it needs it to place frames in time), so one goes out first.
        if !sentFirstSR.contains(s.config.ssrc), let sr = s.senderReport(now: now, ntp: ntp) {
            sentFirstSR.insert(s.config.ssrc)
            send(sr)
        }
        while let p = s.nextPacket(now: now) { send(p) }
    }

    private func tick() {
        guard !stopped else { return }
        let now = MediaPipeline.hostNow()
        for s in [audio, video].compactMap({ $0 }) {
            while let p = s.nextPacket(now: now) { send(p) }      // retransmissions
            if let p = s.kickstart(now: now) { send(p) }
        }
        if now - lastSR >= 0.5 {
            lastSR = now
            for s in [audio, video].compactMap({ $0 }) where sentFirstSR.contains(s.config.ssrc) {
                if let sr = s.senderReport(now: now, ntp: ntp) { send(sr) }
            }
        }
    }

    private func send(_ d: Data) {
        guard fd >= 0 else { return }
        let n = d.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, d.count, 0) }
        if n == d.count {
            bytesSent += UInt64(n)
            packetsSent += 1
        } else {
            sendErrors += 1
        }
    }

    private func ntp(_ host: Double) -> UInt64 {
        let wall = host + wallMinusHost + 2_208_988_800
        let seconds = UInt64(wall)
        let fraction = UInt64((wall - Double(seconds)) * 4_294_967_296.0)
        return seconds << 32 | (fraction & 0xFFFF_FFFF)
    }

    // MARK: - RTCP from the receiver (queue)

    private func read() {
        var buf = [UInt8](repeating: 0, count: 2048)
        while true {
            let n = recv(fd, &buf, buf.count, MSG_DONTWAIT)
            guard n > 0 else { return }
            guard n >= 8, (200...207).contains(buf[1]) else { continue }
            let packet = Data(buf[0..<n])
            // The first RTCP block names the receiver's SSRC, which identifies the stream.
            let ssrc = CastStreamSender.u32(buf, 4)
            let now = MediaPipeline.hostNow()
            for s in [video, audio].compactMap({ $0 }) where s.config.receiverSSRC == ssrc {
                s.handleRTCP(packet, now: now)
                while let p = s.nextPacket(now: now) { send(p) }   // NACKed packets
            }
        }
    }

    enum TransportError: LocalizedError {
        case socket(Int32)
        var errorDescription: String? {
            switch self { case .socket(let e): return "Cast UDP socket error \(e)" }
        }
    }
}
