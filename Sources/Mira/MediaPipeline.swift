import Foundation
import CoreMedia
import CoreVideo

// Capture -> H.264/H.265 + AAC/LPCM/Opus -> a MediaTransport (Miracast or Google Cast).
//
// Timing: everything uses the host clock. The stream clock starts after encoder
// warm-up and capture start-up; frames carry their capture time, and the transport
// turns that into protocol timestamps.
final class MediaPipeline: @unchecked Sendable {

    // Privacy pause: what the TV shows while the Mac's screen is hidden.
    enum PrivacyMode: String, CaseIterable { case off, freeze, black }

    struct Config {
        var format: StreamFormat
        var transport: MediaTransport
        var bitrate: Int
        var testPattern = false
        var displayID: CGDirectDisplayID? = nil
        var adaptiveBitrate = true
        var minBitrate = 1_500_000
        var extendedDisplayID: CGDirectDisplayID? = nil   // virtual monitor to stream (extend mode)
        var muteMac = true                  // silence the Mac's speakers while sending system audio
        var lowLatency = false
        var target: CaptureTarget = .screen
        var keyframeIntervalSeconds: Int32 = 2
    }

    struct Stats {
        var framesEncoded: UInt64 = 0
        var keyframes: UInt64 = 0
        var audioFrames: UInt64 = 0
        var bytesSent: UInt64 = 0
        var packetsSent: UInt64 = 0
        var sendErrors: UInt64 = 0
        var retransmissions: UInt64 = 0
        var bitrate: Int = 0
        var encrypted = false
        var extended = false
    }

    var onFatalError: ((Error) -> Void)?

    let config: Config
    private var transport: MediaTransport { config.transport }
    private let encoder: VideoEncoder
    private var audioEncoder: AudioEncoding?
    private var source: VideoSource?
    private var pumpTimer: DispatchSourceTimer?
    private let pumpQueue = DispatchQueue(label: "mira.pump", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "mira.audio", qos: .userInteractive)
    private var baseHost: Double = 0
    private var stopped = false
    private let statsLock = NSLock()
    private var _stats = Stats()
    private var lastNoFrameWarning: Double = 0
    private var lastFrameSlot: Int64 = -1
    private let bitrate: BitrateController
    private let controlQueue = DispatchQueue(label: "mira.bitrate")
    private var controlTimer: DispatchSourceTimer?
    private let sleepGuard = SleepGuard()
    private let muter = MacAudioMuter()
    private let privacyLock = NSLock()
    private var privacy: PrivacyMode = .off
    private var privacyFrame: CVPixelBuffer?
    var privacyMode: PrivacyMode { privacyLock.withLock { privacy } }
    private var pausedForInput = false   // privacyLock
    // Input from the TV is ignored while the TV can't see the real screen.
    var inputSuspended: Bool { privacyLock.withLock { privacy != .off || pausedForInput || stopped } }

    // What the TV shows, in global screen coordinates, for mapping its input back.
    func inputRegion() -> InputInjector.Region? {
        guard let rect = (source as? ScreenCapturer)?.contentRect() else { return nil }
        return .init(content: rect, streamWidth: config.format.width, streamHeight: config.format.height)
    }

    var stats: Stats {
        var s = statsLock.withLock { _stats }
        let c = transport.counters
        s.bytesSent = c.bytesSent
        s.packetsSent = c.packetsSent
        s.sendErrors = c.sendErrors
        s.retransmissions = c.retransmissions
        s.encrypted = c.encrypted
        s.bitrate = controlQueue.sync { bitrate.current }
        s.extended = config.extendedDisplayID != nil
        return s
    }

    init(config: Config) {
        self.config = config
        let f = config.format
        encoder = VideoEncoder(config: .init(width: Int32(f.width), height: Int32(f.height),
                                             fps: Int32(f.fps), bitrate: config.bitrate,
                                             codec: f.codec,
                                             levelBit: f.h264LevelBit,
                                             h264Profile: f.h264Profile,
                                             lowLatency: config.lowLatency,
                                             keyframeIntervalSeconds: config.keyframeIntervalSeconds))
        let maxRate = config.bitrate
        bitrate = BitrateController(config: .init(
            initial: config.adaptiveBitrate ? min(maxRate, max(config.minBitrate, maxRate * 2 / 3)) : maxRate,
            minimum: config.adaptiveBitrate ? min(config.minBitrate, maxRate) : maxRate,
            maximum: maxRate))
    }

    // Encoder timestamps start here (seconds); the warm-up frame uses 0.
    static let encoderEpoch: Double = 1

    static func hostNow() -> Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }

    func start() async throws {
        baseHost = Self.hostNow()   // provisional; reset right before the first frame
        let f = config.format

        try transport.start()
        transport.onLoss = { [weak self] fraction in
            guard let self else { return }
            self.controlQueue.async { self.bitrate.report(.loss(fraction: fraction)) }
        }
        transport.onKeyframeRequest = { [weak self] in self?.sinkRequestedKeyframe() }
        bitrate.onChange = { [weak self] bps in self?.encoder.setBitrate(bps) }

        let hevc = f.isHEVC
        encoder.onEncoded = { [weak self] sb, isKey in
            let au = hevc ? HEVCBitstream.accessUnit(from: sb, isKeyframe: isKey)
                          : H264Bitstream.accessUnit(from: sb, isKeyframe: isKey)
            guard let self, let au, !self.stopped else { return }
            let pts = self.baseHost + CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)) - Self.encoderEpoch
            self.statsLock.withLock {
                self._stats.framesEncoded += 1
                if isKey { self._stats.keyframes += 1 }
            }
            if !self.transport.sendVideo(au, captureHost: pts, isKeyframe: isKey) {
                self.encoder.forceKeyframe()
            }
        }
        try encoder.start()
        encoder.setBitrate(bitrate.current)
        encoder.warmUp()

        if let audio = f.audio {
            let enc: AudioEncoding
            switch audio {
            case .lpcm: enc = LPCMEncoder()
            case .aac: enc = try CompressedAudioEncoder(codec: .aac)
            case .opus: enc = try CompressedAudioEncoder(codec: .opus)
            }
            enc.onEncoded = { [weak self] frame, pts in
                guard let self else { return }
                self.statsLock.withLock { self._stats.audioFrames += 1 }
                self.transport.sendAudio(frame, captureHost: pts)
            }
            audioEncoder = enc
        }

        // Extend mode: the controller created the virtual display before connecting.
        let captureDisplay = config.extendedDisplayID ?? config.displayID

        let src: VideoSource
        if config.testPattern {
            src = TestPatternSource(width: f.width, height: f.height)
        } else {
            let cap = ScreenCapturer(config: .init(width: f.width, height: f.height, fps: f.fps,
                                                   captureAudio: f.audio != nil,
                                                   displayID: captureDisplay,
                                                   requireDisplay: config.extendedDisplayID != nil,
                                                   target: config.extendedDisplayID == nil ? config.target : .screen))
            cap.onStopped = { [weak self] err in if let err { self?.onFatalError?(err) } }
            src = cap
        }
        if let audioSrc = src as? AudioSource, let enc = audioEncoder {
            audioSrc.onAudio = { [weak self] samples, pts in
                guard let self else { return }
                // Privacy pause silences audio but keeps the timeline running.
                let out = self.privacyMode == .off ? samples : [Float](repeating: 0, count: samples.count)
                self.audioQueue.async { enc.encode(interleaved: out, pts: pts) }
            }
        }
        try await src.start()
        source = src
        sleepGuard.begin(reason: "Mirroring to a display")
        if config.muteMac, !config.testPattern, f.audio != nil { muter.mute() }
        // Start the stream clock only now, after encoder warm-up and capture start-up.
        baseHost = Self.hostNow()
        transport.beginClock(baseHost: baseHost)
        startPump()
        startBitrateControl()
        let c = transport.counters
        Log.info("Pipeline", "Streaming \(f.description) at \(String(format: "%.1f", Double(bitrate.current) / 1e6)) Mbit/s\(config.adaptiveBitrate ? " (adaptive, max \(config.bitrate / 1_000_000))" : "")\(c.encrypted ? ", encrypted" : "")")
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
        transport.stop()
        let s = stats
        Log.info("Pipeline", "Stopped: \(s.framesEncoded) frames (\(s.keyframes) key), \(s.audioFrames) audio frames, \(s.packetsSent) packets\(s.retransmissions > 0 ? " (\(s.retransmissions) resent)" : ""), \(s.bytesSent / 1024) KiB, \(s.sendErrors) send errors")
    }

    func forceKeyframe() { encoder.forceKeyframe() }

    // Live switch between screen / app / window.
    func setTarget(_ target: CaptureTarget) async throws {
        guard let capturer = source as? ScreenCapturer else { return }
        try await capturer.updateTarget(target)
        encoder.forceKeyframe()
    }

    var currentTarget: CaptureTarget { (source as? ScreenCapturer)?.target ?? .screen }

    // Freeze (last frame) or black out what the TV shows, and silence audio.
    func setPrivacy(_ mode: PrivacyMode) {
        let frame: CVPixelBuffer?
        let f = config.format
        switch mode {
        case .off: frame = nil
        case .freeze: frame = source?.currentFrame() ?? Self.blackFrame(width: f.width, height: f.height)
        case .black: frame = Self.blackFrame(width: f.width, height: f.height)
        }
        privacyLock.withLock {
            privacy = mode
            privacyFrame = frame
        }
        encoder.forceKeyframe()      // switch over immediately, in either direction
        Log.info("Pipeline", mode == .off ? "Privacy pause off" : "Privacy pause on (\(mode.rawValue))")
    }

    static func blackFrame(width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
              let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            // BGRA (0,0,0,255): opaque black
            let count = CVPixelBufferGetDataSize(pb) / 4
            base.bindMemory(to: UInt32.self, capacity: count).initialize(repeating: 0xFF00_0000, count: count)
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    // The sink asked for a keyframe: its decoder lost data - also a sign the link is struggling.
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
            if let signal = self.transport.congestion(bitrate: self.bitrate.current) {
                self.bitrate.report(signal)
            }
            self.bitrate.tick()
        }
        t.resume()
        controlTimer = t
    }

    func setPaused(_ p: Bool) {
        privacyLock.withLock { pausedForInput = p }
        transport.setPaused(p)
        if !p { encoder.forceKeyframe() }
    }

    // MARK: - Frame pump

    // Encodes the most recent frame at a constant rate. Re-encoding an unchanged
    // frame costs almost nothing (all-skip P-frames) and keeps the receiver's clock
    // and decoder fed while the screen is static.
    private func startPump() {
        let fps = config.format.fps
        let interval = 1.0 / Double(fps)
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: pumpQueue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            let held = self.privacyLock.withLock { self.privacy == .off ? nil : self.privacyFrame }
            guard let frame = held ?? source.currentFrame() else {
                let now = Self.hostNow()
                if now - self.baseHost > 3, now - self.lastNoFrameWarning > 10 {
                    self.lastNoFrameWarning = now
                    Log.warn("Pipeline", "No frames from screen capture yet")
                }
                return
            }
            // Snap to the 1/fps grid and keep PTS strictly increasing: timer jitter
            // would otherwise produce uneven or duplicate timestamps, which receivers
            // with a fixed display cadence handle badly.
            let slot = max(self.lastFrameSlot + 1, Int64(((Self.hostNow() - self.baseHost) * Double(fps)).rounded()))
            self.lastFrameSlot = slot
            // Session-relative timestamps: VideoToolbox's HEVC encoder falls behind real
            // time when fed large absolute (host clock) timestamps.
            let pts = CMTime(value: CMTimeValue(Self.encoderEpoch) * CMTimeValue(fps) + CMTimeValue(slot),
                             timescale: CMTimeScale(fps))
            self.encoder.encode(frame, pts: pts, duration: duration)
        }
        t.resume()
        pumpTimer = t
    }
}
