import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

// Wraps VTCompressionSession for real-time H.264 (Constrained Baseline, Constrained
// High, or Restricted High 2) or H.265 Main - never B-frames.
// Output is length-prefixed CMSampleBuffers -> H264Bitstream/HEVCBitstream.accessUnit for Annex B.
final class VideoEncoder {

    struct Config {
        var width: Int32  = 1920
        var height: Int32 = 1080
        var fps: Int32    = 30
        var bitrate: Int  = 6_000_000
        var codec: VideoCodec = .h264
        var levelBit: UInt8 = 0x04          // WFD H.264 level bit (0x01=3.1 ... 0x80=5.2)
        var h264Profile: H264Profile = .constrainedBaseline
        var highProfile: Bool { h264Profile != .constrainedBaseline }
        // WFD forbids CABAC in Constrained Baseline and Constrained High (RHP); only
        // the R2 "Restricted High 2" profile allows it.
        var cabac: Bool { h264Profile == .restrictedHigh2 }
        var lowLatency = false              // VideoToolbox low-latency rate control
        var keyframeIntervalSeconds: Int32 = 2
    }

    private(set) var usingLowLatency = false

    var onEncoded: ((_ sampleBuffer: CMSampleBuffer, _ isKeyframe: Bool) -> Void)?

    let config: Config
    private var session: VTCompressionSession?
    private let forceKeyLock = NSLock()
    private var forceNextKeyframe = true
    private var discardOutput = false

    init(config: Config) {
        self.config = config
    }

    static func profileLevel(forLevelBit bit: UInt8, high: Bool = false) -> CFString {
        // Constrained High has no fixed-level constants; the auto level is the lowest that
        // fits the size and rate, i.e. the level we negotiated.
        if high { return kVTProfileLevel_H264_ConstrainedHigh_AutoLevel }
        switch bit {
        case 0x01: return kVTProfileLevel_H264_Baseline_3_1
        case 0x02: return kVTProfileLevel_H264_Baseline_3_2
        case 0x04: return kVTProfileLevel_H264_Baseline_4_0
        case 0x08: return kVTProfileLevel_H264_Baseline_4_1
        case 0x10: return kVTProfileLevel_H264_Baseline_4_2
        case 0x20: return kVTProfileLevel_H264_Baseline_5_0
        case 0x40: return kVTProfileLevel_H264_Baseline_5_1
        default:   return kVTProfileLevel_H264_Baseline_5_2
        }
    }

    // Whether this Mac can encode HEVC (hardware on 2017+ Macs). Probed once.
    static let hevcAvailable: Bool = {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: 640, height: 480,
                                                codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        if let session { VTCompressionSessionInvalidate(session) }
        return status == noErr && session != nil
    }()

    func start() throws {
        if config.lowLatency {
            do {
                try createSession(lowLatency: true)
                usingLowLatency = true
                return
            } catch {
                Log.warn("Encoder", "Low-latency encoder unavailable (\(error)); using the normal one")
            }
        }
        try createSession(lowLatency: false)
    }

    private func createSession(lowLatency: Bool) throws {
        var session: VTCompressionSession?
        var spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
        ]
        if lowLatency {
            // Frame-by-frame rate control without lookahead (macOS 11.3+ for H.264, newer
            // releases for HEVC; creation fails cleanly where it isn't supported).
            spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true
        }
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: config.width,
            height: config.height,
            codecType: config.codec == .h265 ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, flags, sampleBuffer in
                guard let refcon else { return }
                let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
                encoder.handleOutput(status: status, flags: flags, sampleBuffer: sampleBuffer)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw EncoderError.sessionCreationFailed(status)
        }
        self.session = session

        let profile: CFString
        if config.codec == .h265 {
            // Auto level = the lowest that fits size and rate, i.e. what we negotiated.
            profile = kVTProfileLevel_HEVC_Main_AutoLevel
        } else if lowLatency && !config.highProfile {
            profile = kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel
        } else {
            profile = Self.profileLevel(forLevelBit: config.levelBit, high: config.highProfile)
        }
        var props: [(CFString, Any)] = [
            (kVTCompressionPropertyKey_ProfileLevel,          profile),
            (kVTCompressionPropertyKey_RealTime,              true),
            (kVTCompressionPropertyKey_AllowFrameReordering,  false),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval,   config.fps * config.keyframeIntervalSeconds),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, config.keyframeIntervalSeconds),
            (kVTCompressionPropertyKey_ExpectedFrameRate,     config.fps),
            (kVTCompressionPropertyKey_AverageBitRate,        config.bitrate),
            // Cap bursts at 1.5x the average over any 1 s window to spare the Wi-Fi link.
            (kVTCompressionPropertyKey_DataRateLimits,        [config.bitrate * 3 / 16, 1] as CFArray),
        ]
        if config.codec == .h264 {
            props.append((kVTCompressionPropertyKey_H264EntropyMode, config.cabac ? kVTH264EntropyMode_CABAC : kVTH264EntropyMode_CAVLC))
        }
        if lowLatency && config.codec == .h264 {   // the HEVC encoder rejects this key
            props.append((kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, true))
        }
        for (key, value) in props {
            let s = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            if s != noErr { Log.warn("Encoder", "Property \(key) not accepted (\(s))") }
        }

        VTCompressionSessionPrepareToEncodeFrames(session)
        let what = config.codec == .h265 ? "H.265 Main" : "H.264 \(config.h264Profile.rawValue)"
        Log.info("Encoder", "\(what) \(config.width)x\(config.height) @\(config.fps)fps \(config.bitrate / 1000) kbps, level bit 0x\(String(config.levelBit, radix: 16))\(lowLatency ? ", low-latency" : "")")
    }

    // The first frame through a fresh session can take hundreds of ms (much more with
    // the software encoder on machines without a hardware one). Push one black
    // frame through and drop the output so the stream's first real frame is on time.
    func warmUp() {
        guard let session else { return }
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(nil, Int(config.width), Int(config.height),
                                  kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess, let pb else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            memset(base, 0, CVPixelBufferGetDataSize(pb))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        let start = Date()
        discardOutput = true
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: .zero,
                                        duration: .invalid, frameProperties: nil,
                                        sourceFrameRefcon: nil, infoFlagsOut: nil)
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        discardOutput = false
        forceKeyframe()
        Log.info("Encoder", String(format: "Warm-up frame took %.0f ms", Date().timeIntervalSince(start) * 1000))
    }

    // Changes the target bitrate of the running session (used by adaptive bitrate).
    func setBitrate(_ bps: Int) {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: [bps * 3 / 16, 1] as CFArray)
    }

    func forceKeyframe() {
        forceKeyLock.withLock { forceNextKeyframe = true }
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        guard let session else { return }
        let force = forceKeyLock.withLock { () -> Bool in
            defer { forceNextKeyframe = false }
            return forceNextKeyframe
        }
        let props = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(session,
                                                     imageBuffer: pixelBuffer,
                                                     presentationTimeStamp: pts,
                                                     duration: duration,
                                                     frameProperties: props,
                                                     sourceFrameRefcon: nil,
                                                     infoFlagsOut: nil)
        // kVTInvalidSessionErr right after stop() is a frame that raced the teardown.
        if status != noErr, !(status == kVTInvalidSessionErr && self.session == nil) {
            Log.warn("Encoder", "EncodeFrame failed: \(status)")
        }
    }

    func stop() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    private func handleOutput(status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr, let sampleBuffer else {
            if status != noErr { Log.warn("Encoder", "Encode error \(status)") }
            return
        }
        if flags.contains(.frameDropped) { return }
        if discardOutput { return }

        var isKeyframe = true
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = arr.first {
            isKeyframe = (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        }
        onEncoded?(sampleBuffer, isKeyframe)
    }

    enum EncoderError: Error {
        case sessionCreationFailed(OSStatus)
    }
}
