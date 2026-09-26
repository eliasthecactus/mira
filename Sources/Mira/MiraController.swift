import Foundation
import CoreMedia
import VideoToolbox

// Orchestrates the full pipeline:
// Discovery → WFD session → Capture → Encode → Packetize → Send
@available(macOS 13.0, *)
final class MiraController {

    private let browser = DeviceBrowser()
    private var session: WFDSession?
    private var capturer: ScreenCapturer?
    private let encoder = H264Encoder(config: .init(width: 1280, height: 720, fps: 30, bitrate: 4_000_000))
    private let ssrc = UInt32.random(in: 0...UInt32.max)
    private lazy var packetizer = RTPPacketizer(ssrc: ssrc)
    private let rtpSender  = RTPSender(localPort: WFDCapabilities.rtpVideoPort)
    private lazy var rtcpSender = RTCPSender(ssrc: ssrc)

    private var isStreaming = false
    private var startPTS: CMTime = .invalid
    // 90kHz clock units per frame at 30fps = 3000
    private let ticksPerFrame: UInt32 = 3000
    private var currentRTPTimestamp: UInt32 = 0

    // MARK: - Entry point

    func run(connectDirectlyTo ip: String? = nil) async {
        setupEncoder()

        if let ip = ip {
            // Direct connect (skip discovery)
            let device = MiracastDevice(name: "Direct", ipAddress: ip)
            print("[Mira] Connecting directly to \(ip):7236")
            startSession(for: device)
        } else {
            // Browse mDNS
            browser.onDeviceFound = { [weak self] device in
                guard let self, self.session == nil else { return }
                print("[Mira] Found device: \(device)")
                self.browser.stop()
                self.startSession(for: device)
            }
            print("[Mira] Browsing for Miracast devices...")
            browser.start()
        }
    }

    func stop() {
        isStreaming = false
        capturer?.stop()
        rtpSender.disconnect()
        rtcpSender.stop()
        session?.disconnect()
        encoder.stop()
    }

    // MARK: - Session

    private func startSession(for device: MiracastDevice) {
        let s = WFDSession(device: device)
        s.onReady = { [weak self] ip, sinkPort in
            self?.startStreaming(sinkIP: ip, sinkRTPPort: sinkPort)
        }
        s.onError = { err in print("[Mira] Session error: \(err)") }
        session = s
        s.connect()
    }

    // MARK: - Streaming pipeline

    private func startStreaming(sinkIP: String, sinkRTPPort: UInt16) {
        let sinkRTCPPort = sinkRTPPort + 1

        rtpSender.connect(toHost: sinkIP, port: sinkRTPPort)
        rtcpSender.connect(toHost: sinkIP, rtcpPort: sinkRTCPPort)
        rtcpSender.startReports { [weak self] in self?.currentRTPTimestamp ?? 0 }

        isStreaming = true
        print("[Mira] RTP pipeline active → \(sinkIP):\(sinkRTPPort)")

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.startCapture()
            } catch {
                print("[Mira] Capture error: \(error)")
            }
        }
    }

    private func startCapture() async throws {
        let cap = ScreenCapturer(config: .init(width: 1280, height: 720, fps: 30))
        cap.onFrame = { [weak self] pixelBuffer, pts in
            self?.handleFrame(pixelBuffer: pixelBuffer, pts: pts)
        }
        capturer = cap
        try await cap.start()
    }

    // MARK: - Encode & send

    private func setupEncoder() {
        encoder.onEncoded = { [weak self] sampleBuffer, isKeyframe in
            guard let self, self.isStreaming else { return }

            // On keyframe, prepend SPS + PPS
            var nalus: [Data] = []
            if isKeyframe, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
                nalus.append(contentsOf: AnnexBConverter.extractParameterSets(from: fmt))
            }
            nalus.append(contentsOf: AnnexBConverter.extractNALUs(from: sampleBuffer))
            guard !nalus.isEmpty else { return }

            let pts90k = self.currentRTPTimestamp
            let packets = self.packetizer.packetize(nalus: nalus, pts90k: pts90k, isKeyframe: isKeyframe)
            let totalBytes = packets.reduce(0) { $0 + $1.count }
            self.rtpSender.send(packets)
            self.rtcpSender.record(packets: UInt32(packets.count), octets: UInt32(totalBytes))
        }

        do {
            try encoder.start()
        } catch {
            print("[Mira] Encoder start failed: \(error)")
        }
    }

    private func handleFrame(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard isStreaming else { return }

        if startPTS == .invalid { startPTS = pts }
        let elapsed = CMTimeSubtract(pts, startPTS)
        // Convert to 90kHz ticks
        let ticks = UInt32(CMTimeGetSeconds(elapsed) * 90000)
        currentRTPTimestamp = ticks

        let duration = CMTime(value: 1, timescale: 30)
        encoder.encode(pixelBuffer, pts: pts, duration: duration)
    }
}
