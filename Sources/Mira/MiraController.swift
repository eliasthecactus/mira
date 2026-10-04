import Foundation
import AppKit

// Stats snapshot for the UI
struct MiraStats {
    var isStreaming: Bool = false
    var device: MiracastDevice? = nil
    var resolution: String = ""
    var fps: Double = 0
    var kbps: Int = 0
}

// Orchestrates one projection:
//   1. listen for RTSP on 7236          (WFDSession)
//   2. SOURCE_READY → sink:7250          (MICEClient)
//   3. sink connects in, M1…M7           (WFDSession)
//   4. stream MPEG-TS/RTP                (MediaPipeline)
final class MiraController: @unchecked Sendable {   // state is confined to `queue`

    struct Options {
        var prefs = StreamPreferences()
        var testPattern = false
        var displayID: CGDirectDisplayID? = nil      // nil = main display
        var dumpTS: URL? = nil
        var rtspPort: UInt16 = 7236
        var localRTPPort: UInt16 = 19000
        // Sink buffer. nil = auto: 200 ms with AAC (encoder lookahead + capture
        // latency need the room), 150 ms with LPCM, 120 ms video-only.
        var ptsDelay: Double? = nil
        var friendlyName: String = Host.current().localizedName ?? "Mac"
        var autoReconnect = true
    }

    enum Status: Equatable {
        case idle
        case connecting(MiracastDevice)
        case streaming(MiracastDevice, String)
        case failed(String)
    }

    var onDevicesChanged: (([MiracastDevice]) -> Void)?
    var onStatusChanged: ((Status) -> Void)?

    var options: Options
    private(set) var status: Status = .idle { didSet { if status != oldValue { onStatusChanged?(status) } } }

    private let queue = DispatchQueue(label: "mira.control")
    private let browser = DeviceBrowser()
    private var devices: [MiracastDevice] = []
    private var mice: MICEClient?
    private var session: WFDSession?
    private var pipeline: MediaPipeline?
    private var activeDevice: MiracastDevice?
    private var userStopped = false
    private var reconnectAttempts = 0
    private var generation = 0

    // Stats rate tracking
    private var lastStatsTime = Date()
    private var lastFrames: UInt64 = 0
    private var lastBytes: UInt64 = 0

    init(options: Options = Options()) {
        self.options = options
    }

    // Stable per-Mac 16-byte MICE Source ID.
    static let sourceID: Data = {
        let key = "MiraSourceID"
        if let s = UserDefaults.standard.string(forKey: key), let uuid = UUID(uuidString: s) {
            return withUnsafeBytes(of: uuid.uuid) { Data($0) }
        }
        let uuid = UUID()
        UserDefaults.standard.set(uuid.uuidString, forKey: key)
        return withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }()

    // MARK: - Discovery

    func startDiscovery() {
        browser.onDeviceFound = { [weak self] device in
            guard let self else { return }
            self.queue.async {
                self.devices.removeAll { $0.name == device.name }
                self.devices.append(device)
                self.devices.sort { $0.name < $1.name }
                self.onDevicesChanged?(self.devices)
            }
        }
        browser.onDeviceLost = { [weak self] name in
            guard let self else { return }
            self.queue.async {
                self.devices.removeAll { $0.name == name }
                self.onDevicesChanged?(self.devices)
            }
        }
        browser.start()
    }

    func stopDiscovery() { browser.stop() }

    // MARK: - Projection

    func connect(to device: MiracastDevice) {
        queue.async {
            self.tearDownCurrent(reason: "switching device")
            self.userStopped = false
            self.reconnectAttempts = 0
            self.start(device)
        }
    }

    func stop() {
        queue.sync {
            userStopped = true
            tearDownCurrent(reason: "stopped by user")
            status = .idle
        }
    }

    // Blocks until the sink has been told to stop (used on quit).
    func stopAndWait(timeout: TimeInterval = 2) {
        stop()
        Thread.sleep(forTimeInterval: min(timeout, 0.5))
    }

    var currentStats: MiraStats {
        queue.sync {
            guard case .streaming(let device, let res) = status, let pipeline else { return MiraStats() }
            let s = pipeline.stats
            let now = Date()
            let dt = max(now.timeIntervalSince(lastStatsTime), 0.001)
            let fps = Double(s.framesEncoded &- lastFrames) / dt
            let kbps = Int(Double(s.bytesSent &- lastBytes) * 8 / dt / 1000)
            lastStatsTime = now; lastFrames = s.framesEncoded; lastBytes = s.bytesSent
            return MiraStats(isStreaming: true, device: device, resolution: res, fps: fps, kbps: kbps)
        }
    }

    static func defaultDelay(_ audio: WFDAudioCodec?) -> Double {
        switch audio?.format {
        case "AAC":  return 0.2
        case "LPCM": return 0.15
        default:     return 0.12
        }
    }

    // MARK: - Internals (queue only)

    private func start(_ device: MiracastDevice) {
        generation += 1
        let gen = generation
        activeDevice = device
        status = .connecting(device)
        Log.info("Mira", "Connecting to \(device) as \"\(options.friendlyName)\"")

        let s = WFDSession(rtspPort: options.rtspPort, serverRTPPort: options.localRTPPort,
                           prefs: options.prefs, queue: queue)
        session = s

        s.onPlay = { [weak self] format, sinkIP, rtpPort, rtcpPort in
            guard let self, gen == self.generation else { return }
            self.startPipeline(device: device, format: format, sinkIP: sinkIP, rtpPort: rtpPort, rtcpPort: rtcpPort, gen: gen)
        }
        s.onIDRRequest = { [weak self] in self?.pipeline?.forceKeyframe() }
        s.onPause = { [weak self] in self?.pipeline?.setPaused(true) }
        s.onResume = { [weak self] in self?.pipeline?.setPaused(false) }
        s.onClosed = { [weak self] error in
            guard let self, gen == self.generation else { return }
            self.sessionEnded(device: device, error: error)
        }

        s.listen { [weak self] in
            guard let self, gen == self.generation else { return }
            let m = MICEClient(host: device.ipAddress, port: device.port, friendlyName: self.options.friendlyName,
                               sourceID: Self.sourceID, queue: self.queue)
            m.onConnected = { [weak m, weak self] in
                guard let self else { return }
                m?.sendSourceReady(rtspPort: self.options.rtspPort)
            }
            m.onStopProjection = { [weak self] in
                guard let self, gen == self.generation else { return }
                Log.info("Mira", "Sink ended the projection")
                self.session?.teardown()
            }
            m.onError = { [weak self] err in
                guard let self, gen == self.generation else { return }
                self.sessionEnded(device: device, error: MiraError.miceFailed(device, err))
            }
            self.mice = m
            m.connect()
        }
    }

    private func startPipeline(device: MiracastDevice, format: WFDNegotiatedFormat, sinkIP: String,
                               rtpPort: UInt16, rtcpPort: UInt16?, gen: Int) {
        let cfg = MediaPipeline.Config(format: format, sinkIP: sinkIP, rtpPort: rtpPort, rtcpPort: rtcpPort,
                                       localRTPPort: options.localRTPPort, bitrate: options.prefs.bitrate,
                                       fps: format.resolution.fps, testPattern: options.testPattern,
                                       displayID: options.displayID,
                                       dumpTS: options.dumpTS,
                                       ptsDelay: options.ptsDelay ?? Self.defaultDelay(format.audio))
        let p = MediaPipeline(config: cfg)
        p.onFatalError = { [weak self] err in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation else { return }
                self.sessionEnded(device: device, error: err)
            }
        }
        pipeline = p
        Task {
            do {
                try await p.start()
                self.queue.async {
                    guard gen == self.generation else { return }
                    self.reconnectAttempts = 0
                    self.status = .streaming(device, format.resolution.description)
                }
            } catch {
                self.queue.async {
                    guard gen == self.generation else { return }
                    self.sessionEnded(device: device, error: error)
                }
            }
        }
    }

    private func sessionEnded(device: MiracastDevice, error: Error?) {
        let wasStreaming: Bool
        if case .streaming = status { wasStreaming = true } else { wasStreaming = false }
        tearDownCurrent(reason: error == nil ? "session ended" : "error")

        guard let error else {
            status = .idle
            return
        }
        Log.error("Mira", error.localizedDescription)

        // Only retry sessions that were working; a failure during setup would just repeat.
        if wasStreaming, options.autoReconnect, !userStopped, reconnectAttempts < 3 {
            reconnectAttempts += 1
            Log.info("Mira", "Reconnecting in 3s (attempt \(reconnectAttempts)/3)")
            status = .connecting(device)
            let gen = generation
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, gen == self.generation, !self.userStopped else { return }
                self.start(device)
            }
        } else {
            status = .failed(error.localizedDescription)
        }
    }

    private func tearDownCurrent(reason: String) {
        generation += 1
        pipeline?.stop(); pipeline = nil
        session?.onClosed = nil
        session?.teardown(); session = nil
        mice?.onError = nil
        mice?.stop(); mice = nil
        activeDevice = nil
    }
}

enum MiraError: LocalizedError {
    case miceFailed(MiracastDevice, Error)

    var errorDescription: String? {
        switch self {
        case .miceFailed(let d, let e):
            return "Could not reach \(d.name) at \(d.ipAddress):\(d.port) (\(e)). Is the adapter joined to this Wi-Fi network and powered on? Is Mira allowed under System Settings → Privacy & Security → Local Network? (The original non-4K Microsoft adapter does not support Miracast over Wi-Fi at all.)"
        }
    }
}
