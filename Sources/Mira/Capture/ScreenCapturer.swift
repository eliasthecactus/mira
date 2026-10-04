import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AudioToolbox

// Something the frame pump can pull the most recent picture from.
protocol VideoSource: AnyObject {
    func start() async throws
    func stop()
    func currentFrame() -> CVPixelBuffer?
}

// Delivers interleaved Float32 stereo 48 kHz PCM with host-clock timestamps.
protocol AudioSource: AnyObject {
    var onAudio: ((_ interleaved: [Float], _ pts: Double) -> Void)? { get set }
}

// Captures the main display (and optionally system audio) with ScreenCaptureKit.
// ScreenCaptureKit only delivers a frame when the screen changes, so we just keep
// the latest one; FramePump samples it at a constant rate.
final class ScreenCapturer: NSObject, VideoSource, AudioSource {

    struct Config {
        var width: Int = 1920
        var height: Int = 1080
        var fps: Int = 30
        var captureAudio = true
        var displayID: CGDirectDisplayID? = nil   // nil = main display
        var requireDisplay = false                 // fail instead of falling back (virtual display)
        var target: CaptureTarget = .screen
    }

    var onAudio: ((_ interleaved: [Float], _ pts: Double) -> Void)?
    var onStopped: ((Error?) -> Void)?

    private var stream: SCStream?
    private let config: Config
    private var display: SCDisplay?
    private(set) var target: CaptureTarget = .screen
    private let videoQueue = DispatchQueue(label: "mira.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "mira.capture.audio", qos: .userInteractive)
    private let lock = NSLock()
    private var latest: CVPixelBuffer?

    init(config: Config) {
        self.config = config
    }

    func start() async throws {
        var content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permissionDenied(error)
        }
        let wanted = config.displayID ?? CGMainDisplayID()
        // A display that was just created (extend mode) can take a moment to show up.
        var attempts = 0
        while !content.displays.contains(where: { $0.displayID == wanted }), config.displayID != nil, attempts < 15 {
            attempts += 1
            try await Task.sleep(nanoseconds: 200_000_000)
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        let exact = content.displays.first(where: { $0.displayID == wanted })
        if exact == nil, config.requireDisplay { throw CaptureError.noDisplayFound }
        if exact == nil, config.displayID != nil {
            Log.warn("Capture", "Display \(wanted) is gone; mirroring the main display instead")
        }
        guard let display = exact ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw CaptureError.noDisplayFound
        }

        self.display = display
        let filter: SCContentFilter
        do {
            filter = try makeFilter(config.target, content: content, display: display)
            target = config.target
        } catch CaptureError.targetGone(let why) {
            Log.warn("Capture", "Can't share \(config.target) (\(why)); sharing the entire screen instead")
            filter = try makeFilter(.screen, content: content, display: display)
            target = .screen
        }

        let cfg = SCStreamConfiguration()
        cfg.width  = config.width
        cfg.height = config.height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        cfg.scalesToFit = true
        if #available(macOS 14.0, *) { cfg.preservesAspectRatio = true }   // letterbox windows/apps
        cfg.showsCursor = true
        cfg.queueDepth = 6
        cfg.capturesAudio = config.captureAudio
        cfg.sampleRate = Int(AACEncoder.sampleRate)
        cfg.channelCount = 2
        cfg.excludesCurrentProcessAudio = true

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if config.captureAudio {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await s.startCapture()
        stream = s
        Log.info("Capture", "Display \(display.displayID) (\(display.width)×\(display.height)) → \(config.width)×\(config.height) @\(config.fps)fps, audio \(config.captureAudio ? "on" : "off"), sharing \(target)")
    }

    // Switches what's shared without restarting the stream (the TV doesn't notice).
    func updateTarget(_ newTarget: CaptureTarget) async throws {
        guard let stream, let display else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter = try makeFilter(newTarget, content: content, display: display)
        try await stream.updateContentFilter(filter)
        target = newTarget
        Log.info("Capture", "Now sharing \(newTarget)")
    }

    private func makeFilter(_ target: CaptureTarget, content: SCShareableContent, display: SCDisplay) throws -> SCContentFilter {
        let me = ProcessInfo.processInfo.processIdentifier
        switch target {
        case .screen:
            // Don't mirror Mira's own windows (the menu bar popover).
            let ownApp = content.applications.filter { $0.processID == me }
            return SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
        case .app(let bundleID, let name):
            guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
                throw CaptureError.targetGone("\(name) isn't running")
            }
            // Use the display that holds most of the app's windows.
            let windows = content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleID && $0.windowLayer == 0 }
            let best = content.displays.max { a, b in
                windows.reduce(0) { $0 + $1.frame.intersection(a.frame).width * $1.frame.intersection(a.frame).height }
                    < windows.reduce(0) { $0 + $1.frame.intersection(b.frame).width * $1.frame.intersection(b.frame).height }
            } ?? display
            return SCContentFilter(display: best, including: [app], exceptingWindows: [])
        case .window(let id, let title):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw CaptureError.targetGone("the window “\(title)” is closed")
            }
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    func stop() {
        stream?.stopCapture(completionHandler: nil)
        stream = nil
        lock.withLock { latest = nil }
    }

    func currentFrame() -> CVPixelBuffer? { lock.withLock { latest } }

    enum CaptureError: LocalizedError {
        case permissionDenied(Error)
        case noDisplayFound
        case targetGone(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied(let e):
                return "Screen Recording permission missing (\(e.localizedDescription)). Grant it in System Settings → Privacy & Security → Screen & System Audio Recording to the app running Mira (e.g. Terminal), then restart it."
            case .noDisplayFound:
                return "No display found to capture"
            case .targetGone(let why):
                return "Can't share that: \(why)"
            }
        }
    }
}

extension ScreenCapturer: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        switch type {
        case .screen:
            // Only "complete" frames carry a new picture; idle/blank updates don't.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: statusRaw) == .complete,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            lock.withLock { latest = pixelBuffer }
        case .audio:
            guard let onAudio, let samples = Self.interleavedStereo(from: sampleBuffer) else { return }
            onAudio(samples, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("Capture", "Stream stopped: \(error.localizedDescription)")
        onStopped?(error)
    }

    // SCStream audio is Float32, usually non-interleaved. Normalize to interleaved stereo.
    static func interleavedStereo(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 else { return nil }

        var blockBuffer: CMBlockBuffer?
        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: 16)
        defer { raw.deallocate() }
        let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer) == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return nil }
        var out = [Float](repeating: 0, count: frames * 2)
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        if nonInterleaved {
            guard let l = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return nil }
            let r = (buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil) ?? l
            for i in 0..<frames { out[2 * i] = l[i]; out[2 * i + 1] = r[i] }
        } else {
            guard let p = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return nil }
            let ch = Int(asbd.mChannelsPerFrame)
            for i in 0..<frames {
                out[2 * i] = p[i * ch]
                out[2 * i + 1] = ch > 1 ? p[i * ch + 1] : p[i * ch]
            }
        }
        return out
    }
}
