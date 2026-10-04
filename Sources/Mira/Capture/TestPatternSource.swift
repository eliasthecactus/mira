import Foundation
import CoreVideo
import CoreGraphics
import CoreText
import CoreMedia

// Synthetic video + audio for testing without Screen Recording permission:
// colour bars, a sweeping bar, a frame counter and clock, and a 1 kHz beep once a
// second. Motion makes dropped/stuck frames obvious on the sink; the beep makes
// audio/video sync easy to judge (it plays when the white flash is on screen).
final class TestPatternSource: VideoSource, AudioSource {

    var onAudio: ((_ interleaved: [Float], _ pts: Double) -> Void)?

    let width: Int
    let height: Int
    private var pool: CVPixelBufferPool?
    private var frameIndex = 0
    private let startTime = Date()
    private var audioTimer: DispatchSourceTimer?
    private let audioQueue = DispatchQueue(label: "mira.testtone", qos: .userInteractive)
    private var audioFramesSent = 0
    private var audioStartHost: Double = 0

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    func start() async throws {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        startTone()
        Log.info("Capture", "Test pattern \(width)×\(height) with 1 kHz beep each second")
    }

    func stop() {
        audioTimer?.cancel()
        audioTimer = nil
    }

    // MARK: - Video

    func currentFrame() -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb else { return nil }
        frameIndex += 1

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return pb }

        let w = CGFloat(width), h = CGFloat(height)
        let bars: [(CGFloat, CGFloat, CGFloat)] = [(0.75, 0.75, 0.75), (0.75, 0.75, 0), (0, 0.75, 0.75),
                                                    (0, 0.75, 0), (0.75, 0, 0.75), (0.75, 0, 0), (0, 0, 0.75)]
        let barWidth = w / CGFloat(bars.count)
        for (i, c) in bars.enumerated() {
            ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            ctx.fill(CGRect(x: CGFloat(i) * barWidth, y: h * 0.35, width: barWidth + 1, height: h * 0.65))
        }
        ctx.setFillColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.35))

        // Sweeping bar: one full pass every 2 s.
        let elapsed = Date().timeIntervalSince(startTime)
        let x = CGFloat(elapsed.truncatingRemainder(dividingBy: 2) / 2) * w
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: x, y: 0, width: max(8, w / 120), height: h * 0.35))

        // White flash in sync with the beep (first 100 ms of each second).
        if elapsed.truncatingRemainder(dividingBy: 1) < 0.1 {
            ctx.fill(CGRect(x: w - h * 0.15, y: h * 0.1, width: h * 0.12, height: h * 0.12))
        }

        let text = String(format: "Mira test pattern   %dx%d   frame %d   t=%.1fs", width, height, frameIndex, elapsed)
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, h / 22, nil)
        let attr = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ])
        ctx.textPosition = CGPoint(x: w * 0.03, y: h * 0.2)
        CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        return pb
    }

    // MARK: - Audio (1 kHz beep, 100 ms each second)

    private func startTone() {
        audioStartHost = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        audioFramesSent = 0
        let t = DispatchSource.makeTimerSource(queue: audioQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.emitAudio() }
        t.resume()
        audioTimer = t
    }

    private func emitAudio() {
        let rate = AACEncoder.sampleRate
        let now = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let target = Int((now - audioStartHost) * rate)
        let count = target - audioFramesSent
        guard count > 0 else { return }
        var samples = [Float](repeating: 0, count: count * 2)
        for i in 0..<count {
            let n = audioFramesSent + i
            let t = Double(n) / rate
            let v: Float = t.truncatingRemainder(dividingBy: 1) < 0.1 ? Float(sin(2 * .pi * 1000 * t) * 0.3) : 0
            samples[2 * i] = v
            samples[2 * i + 1] = v
        }
        let pts = audioStartHost + Double(audioFramesSent) / rate
        audioFramesSent = target
        onAudio?(samples, pts)
    }
}
