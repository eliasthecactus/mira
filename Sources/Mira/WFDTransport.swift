import Foundation
import CoreMedia

// Miracast media transport: H.264/HEVC + AAC/LPCM -> MPEG-TS -> RTP (PT 33) -> UDP,
// optionally through the MS-MICE DTLS tunnel.
//
// Timing: PCR = time since the stream clock started; PTS = capture time + `ptsDelay`,
// which gives the sink a fixed buffer to absorb encode time and Wi-Fi jitter.
final class WFDTransport: MediaTransport, @unchecked Sendable {   // mux state confined to muxQueue

    struct Config {
        var sinkIP: String
        var rtpPort: UInt16
        var rtcpPort: UInt16?
        var localRTPPort: UInt16
        var audio: MPEGTSMuxer.AudioFormat?
        var hevc = false
        var ptsDelay: Double = 0.2
        var dumpTS: URL? = nil
        var tunnel: DTLSTunnel? = nil       // MS-MICE stream encryption, when negotiated
    }

    var onLoss: ((Double) -> Void)?
    var onKeyframeRequest: (() -> Void)?

    let config: Config
    private let muxer: MPEGTSMuxer
    private let packetizer = RTPMP2TPacketizer()
    private let rtpSender: RTPSender
    private lazy var rtcpSender = RTCPSender(ssrc: packetizer.ssrc)
    private let muxQueue = DispatchQueue(label: "mira.mux", qos: .userInteractive)
    private var dumpHandle: FileHandle?
    private var baseHost: Double = 0
    private var clockStarted = false
    private var paused = false
    private var stopped = false
    private let rtpTimestampOffset = UInt32.random(in: 0...UInt32.max)
    private var lastRTPTimestamp: UInt32 = 0

    init(config: Config) {
        self.config = config
        muxer = MPEGTSMuxer(audio: config.audio, hevc: config.hevc)
        rtpSender = RTPSender(localPort: config.localRTPPort)
    }

    static func audioFormat(_ a: StreamFormat.Audio?) -> MPEGTSMuxer.AudioFormat? {
        switch a {
        case .aac: return .aac
        case .lpcm: return .lpcm
        case .opus, nil: return nil
        }
    }

    func start() throws {
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
        rtcpSender.onReport = { [weak self] block in self?.onLoss?(block.fractionLost) }
        rtcpSender.start(sinkHost: config.sinkIP, rtcpPort: config.rtcpPort, localPort: config.localRTPPort + 1) { [weak self] in
            guard let self else { return .init(rtpTimestamp: 0, packets: 0, octets: 0) }
            return self.muxQueue.sync {
                .init(rtpTimestamp: self.lastRTPTimestamp, packets: self.packetizer.packetCount,
                      octets: self.packetizer.octetCount)
            }
        }
    }

    func beginClock(baseHost: Double) {
        muxQueue.sync {
            self.baseHost = baseHost
            clockStarted = true
        }
    }

    func sendVideo(_ accessUnit: Data, captureHost: Double, isKeyframe: Bool) -> Bool {
        muxQueue.async { [self] in
            guard clockStarted, !paused, !stopped else { return }
            let pcr = pcr27M()
            let ts = muxer.muxVideo(accessUnit: accessUnit, pts90k: pts90k(captureHost), pcr27M: pcr, isKeyframe: isKeyframe)
            emit(ts, pcr: pcr)
        }
        return true
    }

    func sendAudio(_ frame: Data, captureHost: Double) {
        muxQueue.async { [self] in
            guard clockStarted, !paused, !stopped else { return }
            let pcr = pcr27M()
            let ts = muxer.muxAudio(frame, pts90k: pts90k(captureHost), pcr27M: pcr)
            emit(ts, pcr: pcr)
        }
    }

    func setPaused(_ p: Bool) {
        muxQueue.async { self.paused = p }
    }

    // Packets queued in the network stack for more than ~250 ms of stream time means
    // the Wi-Fi can't carry the current rate.
    func congestion(bitrate: Int) -> BitrateController.Signal? {
        guard config.tunnel == nil else { return nil }
        let packetsPerSecond = max(1, bitrate / 8 / 1328)
        let backlog = rtpSender.backlog
        return backlog > max(60, packetsPerSecond / 4) ? .sendCongestion(backlog: backlog) : nil
    }

    func stop() {
        rtcpSender.stop()
        muxQueue.sync {
            stopped = true
            rtpSender.disconnect()
            try? dumpHandle?.close()
            dumpHandle = nil
        }
    }

    var counters: TransportCounters {
        if let tunnel = config.tunnel {
            return TransportCounters(bytesSent: tunnel.mediaBytesSent, packetsSent: tunnel.mediaPacketsSent, encrypted: true)
        }
        return TransportCounters(bytesSent: rtpSender.bytesSent, packetsSent: rtpSender.packetsSent,
                                 sendErrors: rtpSender.sendErrors)
    }

    // MARK: - Mux (muxQueue only)

    private func pts90k(_ host: Double) -> UInt64 {
        UInt64(max(0, host - baseHost + config.ptsDelay + 1.0) * 90_000)
    }

    private func pcr27M() -> UInt64 {
        UInt64(max(0, MediaPipeline.hostNow() - baseHost + 1.0) * 27_000_000)
    }

    private func emit(_ ts: [Data], pcr: UInt64) {
        if let dumpHandle { for p in ts { dumpHandle.write(p) } }
        let rtpTS = UInt32(truncatingIfNeeded: pcr / 300) &+ rtpTimestampOffset
        lastRTPTimestamp = rtpTS
        let packets = packetizer.packetize(tsPackets: ts, rtpTimestamp: rtpTS, flush: true)
        guard !packets.isEmpty else { return }
        if let tunnel = config.tunnel { tunnel.sendMedia(packets) } else { rtpSender.send(packets) }
    }
}
