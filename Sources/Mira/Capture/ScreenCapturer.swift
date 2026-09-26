import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

// Captures the main display using ScreenCaptureKit.
// Delivers CVPixelBuffers at 30fps to the onFrame callback.
@available(macOS 12.3, *)
final class ScreenCapturer: NSObject {

    struct Config {
        var width: Int    = 1280
        var height: Int   = 720
        var fps: Int      = 30
        var displayIndex: Int = 0  // 0 = main display
    }

    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onError: ((Error) -> Void)?

    private var stream: SCStream?
    private let config: Config
    private let sampleQueue = DispatchQueue(label: "mira.capture.video", qos: .userInteractive)

    init(config: Config = Config()) {
        self.config = config
    }

    func start() async throws {
        // Request permission and get available content
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.permissionDenied
        }

        let displays = content.displays
        guard displays.indices.contains(config.displayIndex) else {
            throw CaptureError.noDisplayFound
        }
        let display = displays[config.displayIndex]

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let cfg = SCStreamConfiguration()
        cfg.width  = config.width
        cfg.height = config.height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.scalesToFit = true
        cfg.showsCursor = true
        cfg.capturesAudio = false

        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await s.startCapture()
        self.stream = s
        print("[Capture] Screen capture started \(config.width)×\(config.height) @\(config.fps)fps")
    }

    func stop() {
        stream?.stopCapture(completionHandler: nil)
        stream = nil
    }

    enum CaptureError: Error {
        case permissionDenied
        case noDisplayFound
    }
}

@available(macOS 12.3, *)
extension ScreenCapturer: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onFrame?(pixelBuffer, pts)
    }
}
