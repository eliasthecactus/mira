import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

// Wraps VTCompressionSession for real-time H.264 encoding.
// Produces AVCC-format CMSampleBuffers → pass to AnnexBConverter for NAL extraction.
final class H264Encoder {

    struct Config {
        var width: Int32  = 1280
        var height: Int32 = 720
        var fps: Int32    = 30
        var bitrate: Int  = 4_000_000  // 4 Mbps
    }

    var onEncoded: ((_ sampleBuffer: CMSampleBuffer, _ isKeyframe: Bool) -> Void)?

    private var session: VTCompressionSession?
    private let config: Config
    private var lastFormatDescription: CMFormatDescription?
    private var formatDescriptionSent = false

    init(config: Config = Config()) {
        self.config = config
    }

    func start() throws {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: config.width,
            height: config.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, flags, sampleBuffer in
                guard let refcon, status == noErr, let sampleBuffer else { return }
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
            (kVTCompressionPropertyKey_ProfileLevel,          kVTProfileLevel_H264_Baseline_3_2),
            (kVTCompressionPropertyKey_RealTime,              true),
            (kVTCompressionPropertyKey_AllowFrameReordering,  false),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval,   config.fps * 3),
            (kVTCompressionPropertyKey_ExpectedFrameRate,     config.fps),
            (kVTCompressionPropertyKey_AverageBitRate,        config.bitrate),
            (kVTCompressionPropertyKey_DataRateLimits,        [config.bitrate / 8, 1] as CFArray),
            (kVTCompressionPropertyKey_H264EntropyMode,       kVTH264EntropyMode_CAVLC),
        ]
        for (key, value) in props {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }

        VTCompressionSessionPrepareToEncodeFrames(session)
        print("[Encoder] H.264 session ready \(config.width)×\(config.height) @\(config.fps)fps \(config.bitrate/1000)kbps")
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        guard let session else { return }
        var flags = VTEncodeInfoFlags()
        VTCompressionSessionEncodeFrame(session,
                                        imageBuffer: pixelBuffer,
                                        presentationTimeStamp: pts,
                                        duration: duration,
                                        frameProperties: nil,
                                        sourceFrameRefcon: nil,
                                        infoFlagsOut: &flags)
    }

    func stop() {
        guard let session else { return }
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    // MARK: - Output callback

    private func handleOutput(status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer) {
        guard status == noErr else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        let isKeyframe: Bool
        if let arr = attachments as? [[CFString: Any]], let first = arr.first {
            isKeyframe = first[kCMSampleAttachmentKey_NotSync] == nil
        } else {
            isKeyframe = true
        }

        // On new format description (IDR + format change), send parameter sets first
        if let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            if !formatDescriptionSent || fmt !== lastFormatDescription {
                lastFormatDescription = fmt
                formatDescriptionSent = true
            }
        }

        onEncoded?(sampleBuffer, isKeyframe)
    }

    enum EncoderError: Error {
        case sessionCreationFailed(OSStatus)
    }
}
