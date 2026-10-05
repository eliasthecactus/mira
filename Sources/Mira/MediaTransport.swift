import Foundation

// What the TV receives, independent of the protocol: one implementation per protocol
// (Miracast: MPEG-TS over RTP; Google Cast: Cast Streaming RTP). The MediaPipeline
// captures and encodes, the transport packages and sends.
protocol MediaTransport: AnyObject {
    // Loss reported by the receiver (0...1), drives the adaptive bitrate.
    var onLoss: ((Double) -> Void)? { get set }
    // The receiver lost the picture and needs a keyframe.
    var onKeyframeRequest: (() -> Void)? { get set }

    func start() throws
    // The stream clock starts (host time of timestamp zero); nothing is sent before.
    func beginClock(baseHost: Double)
    // Annex B access unit; `captureHost` is the capture time on the host clock.
    // Returns false if the frame could not be sent and the next one must be a keyframe.
    @discardableResult
    func sendVideo(_ accessUnit: Data, captureHost: Double, isKeyframe: Bool) -> Bool
    func sendAudio(_ frame: Data, captureHost: Double)
    func setPaused(_ paused: Bool)
    // Polled once a second: a congestion signal for the bitrate controller, if any.
    func congestion(bitrate: Int) -> BitrateController.Signal?
    func stop()

    var counters: TransportCounters { get }
}

struct TransportCounters {
    var bytesSent: UInt64 = 0
    var packetsSent: UInt64 = 0
    var sendErrors: UInt64 = 0
    var retransmissions: UInt64 = 0
    var encrypted = false
}

// What the pipeline encodes.
struct StreamFormat: Equatable {
    enum Audio: String { case aac = "AAC", lpcm = "LPCM", opus = "Opus" }

    var width: Int
    var height: Int
    var fps: Int
    var codec: VideoCodec = .h264
    var h264Profile: H264Profile = .constrainedBaseline
    var h264LevelBit: UInt8 = 0x04
    var audio: Audio?

    var isHEVC: Bool { codec == .h265 }
    var description: String { "\(width)x\(height)p\(fps)" + (isHEVC ? " HEVC" : "") }
}

extension StreamFormat {
    init(_ wfd: WFDNegotiatedFormat) {
        self.init(width: wfd.resolution.width, height: wfd.resolution.height, fps: wfd.resolution.fps,
                  codec: wfd.codec, h264Profile: wfd.h264Profile, h264LevelBit: wfd.h264LevelBit,
                  audio: wfd.audio.flatMap { Audio(rawValue: $0.format) })
    }
}
