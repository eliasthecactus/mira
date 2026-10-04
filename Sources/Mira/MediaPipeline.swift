import Foundation
import CoreMedia
import CoreVideo

// Capture → H.264/AAC → MPEG-TS → RTP → UDP, for one negotiated WFD session.
//
// Timing: everything uses the host clock. PCR = time since start; PTS = capture
// time + `ptsDelay`, which gives the sink a fixed buffer to absorb encode time and
// Wi-Fi jitter. Lower = less latency, higher = fewer stutters.
final class MediaPipeline: @unchecked Sendable {   // mux state is confined to muxQueue

    struct Config {
        var format: WFDNegotiatedFormat
        var sinkIP: String
        var rtpPort: UInt16
        var rtcpPort: UInt16?
        var localRTPPort: UInt16
        var bitrate: Int
        var fps: Int
        var testPattern = false
        var displayID: CGDirectDisplayID? = nil
        var dumpTS: URL? = nil
        var ptsDelay: Double = 0.2
        var adaptiveBitrate = true
        var minBitrate = 1_500_000
        var extendedDisplayID: CGDirectDisplayID? = nil   // virtual monitor to stream (extend mode)
        var muteMac = true                  // silence the Mac's speakers while sending system audio
        var tunnel: DTLSTunnel? = nil       // MS-MICE stream encryption, when negotiated
    }

    struct Stats {
        var framesEncoded: UInt64 = 0
        var keyframes: UInt64 = 0
        var audioFrames: UInt64 = 0
        var bytesSent: UInt64 = 0
        var packetsSent: UInt64 = 0
        var sendErrors: UInt64 = 0
        var bitrate: Int = 0
        var encrypted = false
        var extended = false
    }

    var onFatalError: ((Error) -> Void)?

    let config: Config
    private let encoder: H264Encoder
    private var audioEncoder: AudioEncoding?
    private let muxer: MPEGTSMuxer
    private let packetizer = RTPMP2TPacketizer()
    private let rtpSender: RTPSender
    private lazy var rtcpSender = RTCPSender(ssrc: packetizer.ssrc)
    private var source: VideoSource?
    private var pumpTimer: DispatchSourceTimer?
    private let pumpQueue = DispatchQueue(label: "mira.pump", qos: .userInteractive)
    private let muxQueue = DispatchQueue(label: "mira.mux", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "mira.aac", qos: .userInteractive)
    private var dumpHandle: FileHandle?
    private var baseHost: Double = 0
    private let rtpTimestampOffset = UInt32.random(in: 0...UInt32.max)
    private var lastRTPTimestamp: UInt32 = 0
    private var paused = false
    private var stopped = false
    private let statsLock = NSLock()
    private var _stats = Stats()
    private var lastNoFrameWarning: Double = 0
    private var lastFrameSlot: Int64 = -1
    private var clockStarted = false      // muxQueue: nothing is muxed before the stream clock starts
    private let bitrate: BitrateController
    private let controlQueue = DispatchQueue(label: "mira.bitrate")
    private var controlTimer: DispatchSourceTimer?
    private let sleepGuard = SleepGuard()
    private let muter = MacAudioMuter()

    var stats: Stats {
        var s = statsLock.withLock { _stats }
        if let tunnel = config.tunnel {
            s.bytesSent = tunnel.mediaBytesSent
            s.packetsSent = tunnel.mediaPacketsSent
            s.encrypted = true
        } else {
            s.bytesSent = rtpSender.bytesSent
            s.packetsSent = rtpSender.packetsSent
            s.sendErrors = rtpSender.sendErrors
        }
        s.bitrate = controlQueue.sync { bitrate.current }
        s.extended = config.extendedDisplayID != nil
        return s
    }

    init(config: Config) {
        self.config = config
        let r = config.format.resolution
        encoder = H264Encoder(config: .init(width: Int32(r.width), height: Int32(r.height),
                                            fps: Int32(config.fps), bitrate: config.bitrate,
                                            levelBit: config.format.levelBit))
        switch config.format.audio?.format {
        case "AAC":  muxer = MPEGTSMuxer(audio: .aac)
        case "LPCM": muxer = MPEGTSMuxer(audio: .lpcm)
        default:     muxer = MPEGTSMuxer(audio: nil)
        }
        rtpSender = RTPSender(localPort: config.localRTPPort)
        let maxRate = config.bitrate
        bitrate = BitrateController(config: .init(
            initial: config.adaptiveBitrate ? min(maxRate, max(config.minBitrate, maxRate * 2 / 3)) : maxRate,
            minimum: config.adaptiveBitrate ? min(config.minBitrate, maxRate) : maxRate,
            maximum: maxRate))
    }



    static func hostNow() -> Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }

    func start() async throws {
        baseHost = Self.hostNow()   // provisional; reset right before the first frame
        let r = config.format.resolution

        if let url = config.dumpTS {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            dumpHandle = try FileHandle(forWritingTo: url)
            Log.info("Pipeline", "Writing a copy of the TS stream to \(url.path)")
        }

        if let tunnel = config.tunnel {
            try tunnel.setMediaDestination(host: config.sinkIP, port: config.rtpPort, localPort: config.localRTPPort)
        } else {
            rtpSender.connect(toHost: config.sinkIP, port: config.rtpPort)
        }
        rtcpSender.onReport = { [weak self] block in
            guard let self else { return }
            self.controlQueue.async { self.bitrate.report(.loss(fraction: block.fractionLost)) }
        }
        rtcpSender.start(sinkHost: config.sinkIP, rtcpPort: config.rtcpPort, localPort: config.localRTPPort + 1) { [weak self] in
            guard let self else { return .init(rtpTimestamp: 0, packets: 0, octets: 0) }
            return self.muxQueue.sync {
                .init(rtpTimestamp: self.lastRTPTimestamp, packets: self.packetizer.packetCount,
                      octets: self.packetizer.octetCount)
            }
        }
        bitrate.onChange = { [weak self] bps in self?.encoder.setBitrate(bps) }

        encoder.onEncoded = { [weak self] sb, isKey in
            guard let self, let au = H264Bitstream.accessUnit(from: sb, isKeyframe: isKey) else { return }
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
            self.muxQueue.async { self.muxVideo(au, captureHost: pts, isKeyframe: isKey) }
        }
        try encoder.start()
        encoder.setBitrate(bitrate.current)
        encoder.warmUp()

        if let codec = config.format.audio {
            let enc: AudioEncoding = codec.format == "LPCM" ? LPCMEncoder() : try AACEncoder()
            enc.onEncoded = { [weak self] frame, pts in
                guard let self else { return }
                self.muxQueue.async { self.muxAudio(frame, captureHost: pts) }
            }
            audioEncoder = enc
        }

        // Extend mode: the controller created the virtual display before connecting.
        let captureDisplay = config.extendedDisplayID ?? config.displayID

        let src: VideoSource
        if config.testPattern {
            src = TestPatternSource(width: r.width, height: r.height)
        } else {
            let cap = ScreenCapturer(config: .init(width: r.width, height: r.height, fps: config.fps,
                                                   captureAudio: config.format.audio != nil,
                                                   displayID: captureDisplay,
                                                   requireDisplay: config.extendedDisplayID != nil))
            cap.onStopped = { [weak self] err in if let err { self?.onFatalError?(err) } }
            src = cap
        }
        if let audioSrc = src as? AudioSource, let enc = audioEncoder {
            audioSrc.onAudio = { [weak self] samples, pts in
                self?.audioQueue.async { enc.encode(interleaved: samples, pts: pts) }
            }
        }
        try await src.start()
        source = src
        sleepGuard.begin(reason: "Mirroring to a Miracast display")
        if config.muteMac, !config.testPattern, config.format.audio != nil { muter.mute() }
        // Start the stream clock only now, after encoder warm-up and capture start-up.
        muxQueue.sync {
            baseHost = Self.hostNow()
            clockStarted = true
        }
        startPump()
        startBitrateControl()
        Log.info("Pipeline", "Streaming \(r) at \(String(format: "%.1f", Double(bitrate.current) / 1e6)) Mbit/s\(config.adaptiveBitrate ? " (adaptive, max \(config.bitrate / 1_000_000))" : "")\(config.tunnel != nil ? ", encrypted" : "")")
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        pumpTimer?.cancel(); pumpTimer = nil
        controlTimer?.cancel(); controlTimer = nil
        source?.stop(); source = nil
        sleepGuard.end()
        muter.restore()

        encoder.stop()
        rtcpSender.stop()
        muxQueue.sync {
            rtpSender.disconnect()
            try? dumpHandle?.close()
            dumpHandle = nil
        }
        let s = stats
        Log.info("Pipeline", "Stopped: \(s.framesEncoded) frames (\(s.keyframes) key), \(s.audioFrames) audio frames, \(s.packetsSent) RTP packets, \(s.bytesSent / 1024) KiB, \(s.sendErrors) send errors")
    }

    func forceKeyframe() { encoder.forceKeyframe() }

    // The sink asked for an IDR: its decoder lost data — also a sign the link is struggling.
    func sinkRequestedKeyframe() {
        encoder.forceKeyframe()
        controlQueue.async { self.bitrate.report(.idrRequest) }
    }

    // MARK: - Adaptive bitrate

    private func startBitrateControl() {
        guard config.adaptiveBitrate else { return }
        let t = DispatchSource.makeTimerSource(queue: controlQueue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // Packets queued in the network stack for more than ~250 ms of stream time
            // means the Wi-Fi can't carry the current rate.
            if self.config.tunnel == nil {
                let packetsPerSecond = max(1, self.bitrate.current / 8 / 1328)
                let backlog = self.rtpSender.backlog
                if backlog > max(60, packetsPerSecond / 4) {
                    self.bitrate.report(.sendCongestion(backlog: backlog))
                }
            }
            self.bitrate.tick()
        }
        t.resume()
        controlTimer = t
    }

    func setPaused(_ p: Bool) {
        muxQueue.async { self.paused = p }
        if !p { encoder.forceKeyframe() }
    }

    // MARK: - Frame pump

    // Encodes the most recent frame at a constant rate. Re-encoding an unchanged
    // frame costs almost nothing (all-skip P-frames) and keeps PCR and the sink's
    // decoder fed while the screen is static.
    private func startPump() {
        let interval = 1.0 / Double(config.fps)
        let duration = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: pumpQueue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            guard let frame = source.currentFrame() else {
                let now = Self.hostNow()
                if now - self.baseHost > 3, now - self.lastNoFrameWarning > 10 {
                    self.lastNoFrameWarning = now
                    Log.warn("Pipeline", "No frames from screen capture yet")
                }
                return
            }
            // Snap to the 1/fps grid and keep PTS strictly increasing: timer jitter
            // would otherwise produce uneven or duplicate timestamps, which sinks
            // with a fixed display cadence handle badly.
            let fps = Double(self.config.fps)
            let slot = max(self.lastFrameSlot + 1, Int64(((Self.hostNow() - self.baseHost) * fps).rounded()))
            self.lastFrameSlot = slot
            let pts = CMTime(seconds: self.baseHost + Double(slot) / fps, preferredTimescale: 90_000)
            self.encoder.encode(frame, pts: pts, duration: duration)
        }
        t.resume()
        pumpTimer = t
    }

    // MARK: - Mux (muxQueue only)

    private func pts90k(_ host: Double) -> UInt64 {
        UInt64(max(0, host - baseHost + config.ptsDelay + 1.0) * 90_000)
    }

    private func pcr27M() -> UInt64 {
        UInt64(max(0, Self.hostNow() - baseHost + 1.0) * 27_000_000)
    }

    private func muxVideo(_ au: Data, captureHost: Double, isKeyframe: Bool) {
        statsLock.withLock {
            _stats.framesEncoded += 1
            if isKeyframe { _stats.keyframes += 1 }
        }
        guard clockStarted, !paused, !stopped else { return }
        let pcr = pcr27M()
        let ts = muxer.muxVideo(accessUnit: au, pts90k: pts90k(captureHost), pcr27M: pcr, isKeyframe: isKeyframe)
        emit(ts, pcr: pcr, flush: true)
    }

    private func muxAudio(_ frame: Data, captureHost: Double) {
        statsLock.withLock { _stats.audioFrames += 1 }
        guard clockStarted, !paused, !stopped else { return }
        let pcr = pcr27M()
        let ts = muxer.muxAudio(frame, pts90k: pts90k(captureHost), pcr27M: pcr)
        emit(ts, pcr: pcr, flush: true)
    }

    private func emit(_ ts: [Data], pcr: UInt64, flush: Bool) {
        if let dumpHandle { for p in ts { dumpHandle.write(p) } }
        let rtpTS = UInt32(truncatingIfNeeded: pcr / 300) &+ rtpTimestampOffset
        lastRTPTimestamp = rtpTS
        let packets = packetizer.packetize(tsPackets: ts, rtpTimestamp: rtpTS, flush: flush)
        guard !packets.isEmpty else { return }
        if let tunnel = config.tunnel { tunnel.sendMedia(packets) } else { rtpSender.send(packets) }
    }
}
