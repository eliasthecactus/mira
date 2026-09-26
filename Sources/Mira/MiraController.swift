import Foundation
import CoreMedia
import VideoToolbox

// Stats snapshot for the UI
struct MiraStats {
    var isStreaming: Bool = false
    var device: MiracastDevice? = nil
    var fps: Double = 0
    var kbps: Int = 0
}

// Orchestrates the full pipeline:
// Discovery → WFD session → Capture → Encode → Packetize → Send
final class MiraController {

    // UI callbacks
    var onDeviceDiscovered: (([MiracastDevice]) -> Void)?

    private let browser = DeviceBrowser()
    private var session: WFDSession?
    private var capturer: ScreenCapturer?
    private let encoder = H264Encoder(config: .init(width: 1280, height: 720, fps: 30, bitrate: 4_000_000))
    private let ssrc = UInt32.random(in: 0...UInt32.max)
    private lazy var packetizer = RTPPacketizer(ssrc: ssrc)
    private let rtpSender = RTPSender(localPort: WFDCapabilities.rtpVideoPort)
    private lazy var rtcpSender = RTCPSender(ssrc: ssrc)

    private var isStreaming = false
    private var startPTS: CMTime = .invalid
    private var currentRTPTimestamp: UInt32 = 0
    private var activeDevice: MiracastDevice?
    private var discoveredDevices: [MiracastDevice] = []

    // Stats (read from UI timer)
    private var frameCount: UInt64 = 0
    private var lastStatsTime: Date = Date()
    private var lastFrameCount: UInt64 = 0

    var currentStats: MiraStats {
        let elapsed = Date().timeIntervalSince(lastStatsTime)
        let framesElapsed = Double(frameCount - lastFrameCount)
        let fps = elapsed > 0 ? framesElapsed / elapsed : 0
        let kbps = Int(Double(rtpSender.bytesSent) / max(elapsed, 1) * 8 / 1000)
        return MiraStats(isStreaming: isStreaming, device: activeDevice, fps: fps, kbps: kbps)
    }

    // MARK: - Entry point (auto-browse mode)

    func run(connectDirectlyTo ip: String? = nil) async {
        setupEncoder()

        if let ip = ip {
            let device = MiracastDevice(name: "Direct", ipAddress: ip)
            print("[Mira] Direct connect → \(ip)")
            startSession(for: device)
        } else {
            browser.onDeviceFound = { [weak self] device in
                guard let self else { return }
                if !self.discoveredDevices.contains(where: { $0.ipAddress == device.ipAddress }) {
                    self.discoveredDevices.append(device)
                    self.onDeviceDiscovered?(self.discoveredDevices)
                    // Auto-connect in CLI mode (no UI)
                    if self.onDeviceDiscovered == nil, self.session == nil {
                        self.browser.stop()
                        self.startSession(for: device)
                    }
                }
            }
            print("[Mira] Browsing for Miracast devices...")
            browser.start()
        }
    }

    // UI-triggered connect to a specific device
    func connectTo(device: MiracastDevice) async {
        setupEncoder()
        startSession(for: device)
    }

    func stop() {
        isStreaming = false
        activeDevice = nil
        capturer?.stop()
        capturer = nil
        rtpSender.disconnect()
        rtcpSender.stop()
        session?.disconnect()
        session = nil
        startPTS = .invalid
    }

    // MARK: - Session

    private func startSession(for device: MiracastDevice) {
        session?.disconnect()
        let s = WFDSession(device: device)
        s.onReady = { [weak self] ip, sinkPort in
            self?.activeDevice = device
            self?.startStreaming(sinkIP: ip, sinkRTPPort: sinkPort)
        }
        s.onError = { [weak self] err in
            print("[Mira] Session error: \(err)")
            // Reconnect after 5s
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.session != nil else { return }
                print("[Mira] Reconnecting to \(device)...")
                self.startSession(for: device)
            }
        }
        session = s
        s.connect()
    }

    // MARK: - Streaming pipeline

    private func startStreaming(sinkIP: String, sinkRTPPort: UInt16) {
        rtpSender.connect(toHost: sinkIP, port: sinkRTPPort)
        rtcpSender.connect(toHost: sinkIP, rtcpPort: sinkRTPPort + 1)
        rtcpSender.startReports { [weak self] in self?.currentRTPTimestamp ?? 0 }
        isStreaming = true
        print("[Mira] Streaming → \(sinkIP):\(sinkRTPPort)")
        Task { [weak self] in
            do { try await self?.startCapture() }
            catch { print("[Mira] Capture error: \(error)") }
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
        guard encoder.onEncoded == nil else { return }  // only once
        encoder.onEncoded = { [weak self] sampleBuffer, isKeyframe in
            guard let self, self.isStreaming else { return }

            var nalus: [Data] = []
            if isKeyframe, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
                nalus.append(contentsOf: AnnexBConverter.extractParameterSets(from: fmt))
            }
            nalus.append(contentsOf: AnnexBConverter.extractNALUs(from: sampleBuffer))
            guard !nalus.isEmpty else { return }

            let pts90k = self.currentRTPTimestamp
            let packets = self.packetizer.packetize(nalus: nalus, pts90k: pts90k, isKeyframe: isKeyframe)
            let totalBytes = UInt32(packets.reduce(0) { $0 + $1.count })
            self.rtpSender.send(packets)
            self.rtcpSender.record(packets: UInt32(packets.count), octets: totalBytes)
            self.frameCount += 1
        }
        do { try encoder.start() }
        catch { print("[Mira] Encoder start failed: \(error)") }
    }

    private func handleFrame(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard isStreaming else { return }
        if startPTS == .invalid { startPTS = pts }
        let elapsed = CMTimeSubtract(pts, startPTS)
        currentRTPTimestamp = UInt32(CMTimeGetSeconds(elapsed) * 90000)
        encoder.encode(pixelBuffer, pts: pts, duration: CMTime(value: 1, timescale: 30))
    }
}
