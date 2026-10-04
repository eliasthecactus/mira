import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

// Wraps VTCompressionSession for real-time H.264 (Baseline, no B-frames).
// Output is AVCC CMSampleBuffers → H264Bitstream.accessUnit for Annex B.
final class H264Encoder {

    struct Config {
        var width: Int32  = 1920
        var height: Int32 = 1080
        var fps: Int32    = 30
        var bitrate: Int  = 6_000_000
        var levelBit: UInt8 = 0x04          // WFD level bit (0x01=3.1 … 0x10=4.2)
        var keyframeIntervalSeconds: Int32 = 2
    }

    var onEncoded: ((_ sampleBuffer: CMSampleBuffer, _ isKeyframe: Bool) -> Void)?

    let config: Config
    private var session: VTCompressionSession?
    private let forceKeyLock = NSLock()
    private var forceNextKeyframe = true
    private var discardOutput = false

    init(config: Config) {
        self.config = config
    }

    static func profileLevel(forLevelBit bit: UInt8) -> CFString {
        switch bit {
        case 0x01: return kVTProfileLevel_H264_Baseline_3_1
        case 0x02: return kVTProfileLevel_H264_Baseline_3_2
        case 0x04: return kVTProfileLevel_H264_Baseline_4_0
        case 0x08: return kVTProfileLevel_H264_Baseline_4_1
        default:   return kVTProfileLevel_H264_Baseline_4_2
        }
    }

    func start() throws {
        var session: VTCompressionSession?
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
        ]
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: config.width,
            height: config.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, flags, sampleBuffer in
                guard let refcon else { return }
                let encoder = Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
                encoder.handleOutput(status: status, flags: flags, sampleBuffer: sampleBuffer)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw EncoderError.sessionCreationFailed(status)
        }
        self.session = session

        let props: [(CFString, Any)] = [
            (kVTCompressionPropertyKey_ProfileLevel,          Self.profileLevel(forLevelBit: config.levelBit)),
            (kVTCompressionPropertyKey_RealTime,              true),
            (kVTCompressionPropertyKey_AllowFrameReordering,  false),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval,   config.fps * config.keyframeIntervalSeconds),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, config.keyframeIntervalSeconds),
            (kVTCompressionPropertyKey_ExpectedFrameRate,     config.fps),
            (kVTCompressionPropertyKey_AverageBitRate,        config.bitrate),
            // Cap bursts at 1.5× the average over any 1 s window to spare the Wi-Fi link.
            (kVTCompressionPropertyKey_DataRateLimits,        [config.bitrate * 3 / 16, 1] as CFArray),
            (kVTCompressionPropertyKey_H264EntropyMode,       kVTH264EntropyMode_CAVLC),
        ]
        for (key, value) in props {
            let s = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            if s != noErr { Log.warn("Encoder", "Property \(key) not accepted (\(s))") }
        }

        VTCompressionSessionPrepareToEncodeFrames(session)
        Log.info("Encoder", "H.264 \(config.width)×\(config.height) @\(config.fps)fps \(config.bitrate / 1000) kbps, level bit 0x\(String(config.levelBit, radix: 16))")
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
        if status != noErr { Log.warn("Encoder", "EncodeFrame failed: \(status)") }
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
