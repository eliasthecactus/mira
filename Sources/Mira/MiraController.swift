import Foundation
import AppKit

// Stats snapshot for the UI
struct MiraStats {
    var isStreaming: Bool = false
    var device: MiracastDevice? = nil
    var resolution: String = ""
    var fps: Double = 0
    var kbps: Int = 0
    var targetKbps: Int = 0
    var encrypted = false
    var extended = false
    var extendFailure: String? = nil
    var privacy: MediaPipeline.PrivacyMode = .off
}

// Orchestrates one projection:
//   1. listen for RTSP on 7236          (WFDSession)
//   2. [security handshake / PIN] then SOURCE_READY → sink:7250   (MICEClient)
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
        var security: SecurityChoice = .auto
        var pin: String? = nil                       // preset PIN (CLI --pin); otherwise asked for
        var adaptiveBitrate = true
        var extendDisplay = false
        var muteMac = true
        var lowLatency = false
        var target: CaptureTarget = .screen
    }

    // auto = plain session (any compliant sink accepts it); if the display ignores it,
    // retry once with PIN pairing, since that's the only reason a sink should refuse.
    enum SecurityChoice: String, CaseIterable {
        case auto, off, encrypted, pin

        var initial: MICESecurity {
            switch self {
            case .auto, .off: return .none
            case .encrypted: return .encrypted
            case .pin: return .pin
            }
        }
    }

    enum Status: Equatable {
        case idle
        case connecting(MiracastDevice)
        case streaming(MiracastDevice, String)
        case failed(String)
    }

    var onDevicesChanged: (([MiracastDevice]) -> Void)?
    var onStatusChanged: ((Status) -> Void)?
    // Asks the user for the PIN shown on the TV (called on an arbitrary queue).
    var pinProvider: ((@escaping (String?) -> Void) -> Void)?

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
    private var currentSecurity: MICESecurity = .none
    private var extended: ExtendedDisplay?
    private var extendFailure: String?
    private static var extendUnavailable: String?      // remembered for the rest of the run

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
            self.start(device, security: self.options.security.initial)
        }
    }

    func stop() {
        queue.sync {
            userStopped = true
            tearDownCurrent(reason: "stopped by user")
            status = .idle
        }
    }

    // Changes what's shared; applies live if a session is running.
    func setTarget(_ target: CaptureTarget, completion: ((Error?) -> Void)? = nil) {
        queue.async {
            self.options.target = target
            guard let pipeline = self.pipeline else { completion?(nil); return }
            Task {
                do { try await pipeline.setTarget(target); completion?(nil) }
                catch { Log.warn("Mira", error.localizedDescription); completion?(error) }
            }
        }
    }

    // Privacy pause: `mode` .freeze/.black hides the Mac's screen, .off resumes.
    func setPrivacy(_ mode: MediaPipeline.PrivacyMode) {
        queue.async { self.pipeline?.setPrivacy(mode) }
    }

    // Toggles between off and `mode`; returns the new state.
    @discardableResult
    func togglePrivacy(_ mode: MediaPipeline.PrivacyMode = .freeze) -> MediaPipeline.PrivacyMode {
        queue.sync {
            guard let pipeline else { return .off }
            let next: MediaPipeline.PrivacyMode = pipeline.privacyMode == .off ? mode : .off
            pipeline.setPrivacy(next)
            return next
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
            return MiraStats(isStreaming: true, device: device, resolution: res, fps: fps, kbps: kbps,
                             targetKbps: s.bitrate / 1000, encrypted: s.encrypted,
                             extended: s.extended, extendFailure: extendFailure,
                             privacy: pipeline.privacyMode)
        }
    }

    // Sink buffer (PTS − PCR). Low-latency mode trims it to what encode + capture need.
    static func defaultDelay(_ audio: WFDAudioCodec?, lowLatency: Bool = false) -> Double {
        switch (audio?.format, lowLatency) {
        case ("AAC", false):  return 0.2
        case ("AAC", true):   return 0.15      // AAC's ~65 ms lookahead sets the floor
        case ("LPCM", false): return 0.15
        case ("LPCM", true):  return 0.1       // ScreenCaptureKit delivers audio up to ~70 ms late
        case (_, false):      return 0.12
        case (_, true):       return 0.05      // encode takes ~15 ms with the low-latency encoder
        }
    }

    // MARK: - Internals (queue only)

    private func start(_ device: MiracastDevice, security: MICESecurity) {
        generation += 1
        let gen = generation
        activeDevice = device
        currentSecurity = security
        status = .connecting(device)
        Log.info("Mira", "Connecting to \(device) as \"\(options.friendlyName)\" (security: \(security.rawValue))")

        // Extend mode: create the virtual monitor before contacting the display, so the
        // stream can start the moment the display says PLAY.
        if options.extendDisplay && !options.testPattern && extended == nil {
            if let reason = Self.extendUnavailable {
                extendFailure = reason
            } else {
                let size = options.prefs.resolution == .p720 ? (1280, 720) : (1920, 1080)
                Task { @MainActor in
                    var created: ExtendedDisplay?
                    var failure: String?
                    do {
                        created = try await ExtendedDisplay.create(name: "Mira (\(device.name))", width: size.0,
                                                                   height: size.1, fps: self.options.prefs.fps)
                    } catch {
                        failure = error.localizedDescription
                    }
                    self.queue.async {
                        guard gen == self.generation else { return }
                        self.extended = created
                        if let failure {
                            Self.extendUnavailable = failure
                            self.extendFailure = failure
                            Log.warn("Mira", "\(failure) Mirroring instead.")
                        }
                        self.startSession(device, security: security, gen: gen)
                    }
                }
                return
            }
        }
        startSession(device, security: security, gen: gen)
    }

    private func startSession(_ device: MiracastDevice, security: MICESecurity, gen: Int) {
        let s = WFDSession(rtspPort: options.rtspPort, serverRTPPort: options.localRTPPort,
                           prefs: options.prefs, queue: queue)
        session = s

        s.onPlay = { [weak self] format, sinkIP, rtpPort, rtcpPort in
            guard let self, gen == self.generation else { return }
            self.startPipeline(device: device, format: format, sinkIP: sinkIP, rtpPort: rtpPort, rtcpPort: rtcpPort, gen: gen)
        }
        s.onIDRRequest = { [weak self] in self?.pipeline?.sinkRequestedKeyframe() }
        s.onPause = { [weak self] in self?.pipeline?.setPaused(true) }
        s.onResume = { [weak self] in self?.pipeline?.setPaused(false) }
        s.onClosed = { [weak self] error in
            guard let self, gen == self.generation else { return }
            self.sessionEnded(device: device, error: error)
        }

        s.listen { [weak self] in
            guard let self, gen == self.generation else { return }
            let m = MICEClient(host: device.ipAddress, port: device.port, friendlyName: self.options.friendlyName,
                               sourceID: Self.sourceID, security: security, queue: self.queue)
            m.onSourceReady = { [weak self] in
                guard let self, gen == self.generation else { return }
                // Receivers like Windows' "Projecting to this PC" may first ask the person at
                // the screen to accept, so allow time for that before giving up / trying PIN.
                let wait: TimeInterval = 30
                Log.info("Mira", "Waiting for \(device.name) to connect back — if the display shows an \"allow projection\" prompt, accept it")
                self.session?.armConnectTimeout(wait)
            }
            m.pinProvider = { [weak self] completion in
                guard let self else { completion(nil); return }
                if let preset = self.options.pin { completion(preset); return }
                guard let provider = self.pinProvider else { completion(nil); return }
                provider(completion)
            }
            m.onStopProjection = { [weak self] in
                guard let self, gen == self.generation else { return }
                Log.info("Mira", "Sink ended the projection")
                self.session?.teardown()
            }
            m.onError = { [weak self] err in
                guard let self, gen == self.generation else { return }
                // Security failures speak for themselves; anything else is "couldn't reach it".
                let wrapped: Error = (err is MICEClient.MICEError || err is DTLSTunnel.TunnelError)
                    ? err : MiraError.miceFailed(device, err)
                self.sessionEnded(device: device, error: wrapped)
            }
            self.mice = m
            m.connect(rtspPort: self.options.rtspPort)
        }
    }

    private func startPipeline(device: MiracastDevice, format: WFDNegotiatedFormat, sinkIP: String,
                               rtpPort: UInt16, rtcpPort: UInt16?, gen: Int) {
        // 4K needs about 2.5× the bits of 1080p for the same quality.
        let maxBitrate = options.adaptiveBitrate && format.resolution.is4K ? options.prefs.bitrate * 5 / 2 : options.prefs.bitrate
        let cfg = MediaPipeline.Config(format: format, sinkIP: sinkIP, rtpPort: rtpPort, rtcpPort: rtcpPort,
                                       localRTPPort: options.localRTPPort, bitrate: maxBitrate,
                                       fps: format.resolution.fps, testPattern: options.testPattern,
                                       displayID: options.displayID,
                                       dumpTS: options.dumpTS,
                                       ptsDelay: options.ptsDelay ?? Self.defaultDelay(format.audio, lowLatency: options.lowLatency),
                                       adaptiveBitrate: options.adaptiveBitrate,
                                       extendedDisplayID: extended?.displayID,
                                       muteMac: options.muteMac,
                                       lowLatency: options.lowLatency,
                                       target: options.target,
                                       tunnel: currentSecurity == .none ? nil : mice?.tunnel)
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

        // auto security: a compliant sink always answers a plain SOURCE_READY, so being
        // ignored suggests it insists on PIN pairing. Try that once.
        if case WFDSession.SessionError.sinkNeverConnected = error,
           options.security == .auto, currentSecurity == .none, !userStopped {
            Log.info("Mira", "The display didn't answer a plain connection; retrying with PIN pairing")
            let gen = generation
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, gen == self.generation, !self.userStopped else { return }
                self.start(device, security: .pin)
            }
            return
        }

        // Only retry sessions that were working; a failure during setup would just repeat.
        if wasStreaming, options.autoReconnect, !userStopped, reconnectAttempts < 3 {
            reconnectAttempts += 1
            Log.info("Mira", "Reconnecting in 3s (attempt \(reconnectAttempts)/3)")
            status = .connecting(device)
            let gen = generation
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, gen == self.generation, !self.userStopped else { return }
                self.start(device, security: self.currentSecurity)
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
        extendFailure = nil
        if let ext = extended {
            extended = nil
            DispatchQueue.main.async { _ = ext }   // the virtual display lives on the main queue
        }
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
