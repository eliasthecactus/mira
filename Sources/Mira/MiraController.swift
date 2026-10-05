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
//   2. [security handshake / PIN] then SOURCE_READY -> sink:7250   (MICEClient)
//   3. sink connects in, M1...M7           (WFDSession)
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
        var remoteInput = false                      // UIBC: let the TV's keyboard/mouse/touch control the Mac
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
    // A Cast TV behind a hotel/venue gateway refused us: the Mac has to be paired first.
    var onPairingNeeded: ((MiracastDevice) -> Void)?
    // Asks the user for the PIN shown on the TV (called on an arbitrary queue).
    var pinProvider: ((@escaping (String?) -> Void) -> Void)?

    var options: Options
    private(set) var status: Status = .idle { didSet { if status != oldValue { onStatusChanged?(status) } } }

    private let queue = DispatchQueue(label: "mira.control")
    private let browsers = [DeviceBrowser(kind: .miracast), DeviceBrowser(kind: .googleCast), DeviceBrowser(kind: .airplay)]
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
    private var uibc: UIBCServer?
    private var cast: CastSession?
    private let ssdp = SSDPDiscovery()
    private var renderers: [String: DLNARenderer] = [:]      // by UDN
    private var dlna: (renderer: DLNARenderer, monitor: DispatchSourceTimer)?
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
        for browser in browsers {
            let kind = browser.kind
            browser.onDeviceFound = { [weak self] device in
                guard let self else { return }
                self.queue.async {
                    self.devices.removeAll { $0.kind == kind && $0.serviceName == device.serviceName }
                    self.devices.append(device)
                    self.devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    self.onDevicesChanged?(self.devices)
                }
            }
            browser.onDeviceLost = { [weak self] name in
                guard let self else { return }
                self.queue.async {
                    self.devices.removeAll { $0.kind == kind && $0.serviceName == name }
                    self.onDevicesChanged?(self.devices)
                }
            }
            browser.start()
        }
        ssdp.onFound = { [weak self] device, renderer in
            guard let self else { return }
            self.queue.async {
                self.renderers[renderer.udn] = renderer
                self.devices.removeAll { $0.kind == .dlna && $0.serviceName == device.serviceName }
                // A TV that also speaks Google Cast or Miracast is better served that way.
                guard !self.devices.contains(where: { $0.ipAddress == device.ipAddress && [.miracast, .googleCast].contains($0.kind) }) else { return }
                self.devices.append(device)
                self.devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self.onDevicesChanged?(self.devices)
            }
        }
        ssdp.start()
    }

    func stopDiscovery() {
        browsers.forEach { $0.stop() }
        ssdp.stop()
    }

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

    // Sink buffer (PTS - PCR). Low-latency mode trims it to what encode + capture need.
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
        if device.kind == .airplay {
            sessionEnded(device: device, error: MiraError.useAirPlay(device.name))
            return
        }
        if device.kind == .googleCast {
            startCastSession(device, gen: gen)
            return
        }
        if device.kind == .dlna {
            startDLNASession(device, gen: gen)
            return
        }
        var prefs = options.prefs
        prefs.allowHEVC = prefs.allowHEVC && VideoEncoder.hevcAvailable
        if options.remoteInput {
            if !InputInjector.hasPermission && !options.testPattern { InputInjector.requestPermission() }
            let server = UIBCServer()
            prefs.uibcPort = server.start()
            uibc = server
        }
        let s = WFDSession(rtspPort: options.rtspPort, serverRTPPort: options.localRTPPort,
                           prefs: prefs, queue: queue)
        session = s
        if let server = uibc {
            server.allowedHost = { [weak s] in s?.sinkAddress }
            s.onUIBCSetting = { [weak server] on in server?.setEnabled(on) }
        }

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
                Log.info("Mira", "Waiting for \(device.name) to connect back - if the display shows an \"allow projection\" prompt, accept it")
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
        // 4K needs about 2.5x the bits of 1080p for the same quality.
        var maxBitrate = options.adaptiveBitrate && format.resolution.is4K ? options.prefs.bitrate * 5 / 2 : options.prefs.bitrate
        if let limit = format.maxBitrate, maxBitrate > limit {
            Log.info("Mira", "Capping the bitrate at \(limit / 1_000_000) Mbit/s (HEVC level limit)")
            maxBitrate = limit
        }
        let stream = StreamFormat(format)
        let transport = WFDTransport(config: .init(
            sinkIP: sinkIP, rtpPort: rtpPort, rtcpPort: rtcpPort, localRTPPort: options.localRTPPort,
            audio: WFDTransport.audioFormat(stream.audio), hevc: stream.isHEVC,
            ptsDelay: options.ptsDelay ?? Self.defaultDelay(format.audio, lowLatency: options.lowLatency),
            dumpTS: options.dumpTS,
            tunnel: currentSecurity == .none ? nil : mice?.tunnel))
        runPipeline(device: device, stream: stream, transport: transport, bitrate: maxBitrate,
                    inputBackChannel: format.uibc != nil, gen: gen)
    }

    private func runPipeline(device: MiracastDevice, stream: StreamFormat, transport: MediaTransport,
                             bitrate: Int, keyframeInterval: Int32 = 2, inputBackChannel: Bool, gen: Int) {
        let cfg = MediaPipeline.Config(format: stream, transport: transport, bitrate: bitrate,
                                       testPattern: options.testPattern,
                                       displayID: options.displayID,
                                       adaptiveBitrate: options.adaptiveBitrate,
                                       extendedDisplayID: extended?.displayID,
                                       muteMac: options.muteMac,
                                       lowLatency: options.lowLatency,
                                       target: options.target,
                                       keyframeIntervalSeconds: keyframeInterval)
        let p = MediaPipeline(config: cfg)
        p.onFatalError = { [weak self] err in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation else { return }
                self.sessionEnded(device: device, error: err)
            }
        }
        pipeline = p
        if inputBackChannel, let server = uibc {
            server.isSuspended = { [weak p] in p?.inputSuspended ?? true }
            server.activate(streamWidth: stream.width, streamHeight: stream.height) { [weak p] in
                p?.inputRegion()
            }
        } else if let server = uibc {
            Log.info("UIBC", "The display does not offer input back to the Mac")
            server.stop()
            uibc = nil
        }
        Task {
            do {
                try await p.start()
                self.queue.async {
                    guard gen == self.generation else { return }
                    self.reconnectAttempts = 0
                    self.status = .streaming(device, stream.description)
                }
            } catch {
                self.queue.async {
                    guard gen == self.generation else { return }
                    self.sessionEnded(device: device, error: error)
                }
            }
        }
    }

    // MARK: - DLNA (TV media player)

    private func startDLNASession(_ device: MiracastDevice, gen: Int) {
        let found: (DLNARenderer?) -> Void = { [weak self] renderer in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation else { return }
                guard let renderer else {
                    self.sessionEnded(device: device, error: DLNAError.notARenderer(device.ipAddress))
                    return
                }
                self.renderers[renderer.udn] = renderer
                self.playOnRenderer(renderer, device: device, gen: gen)
            }
        }
        if let known = renderers.values.first(where: { $0.udn == device.serviceName || $0.location == device.location }) {
            found(known)
        } else if let location = device.location {
            URLSession.shared.dataTask(with: URLRequest(url: location, timeoutInterval: 5)) { data, _, _ in
                found(data.flatMap { DLNARenderer.parse($0, location: location) })
            }.resume()
        } else {
            // Connect by IP: ask the network which renderer lives there.
            Log.info("DLNA", "Looking for a DLNA renderer at \(device.ipAddress)...")
            ssdp.start()
            queue.asyncAfter(deadline: .now() + 4) { [weak self] in
                found(self?.ssdp.renderer(for: device.ipAddress))
            }
        }
    }

    private func playOnRenderer(_ renderer: DLNARenderer, device: MiracastDevice, gen: Int) {
        let prefs = options.prefs
        let size = prefs.resolution == .p720 ? (1280, 720) : (1920, 1080)
        let transport = HTTPStreamTransport(audio: prefs.audio ? .aac : nil, ptsDelay: 0.3)
        do { try transport.start() } catch { sessionEnded(device: device, error: error); return }
        guard let host = DeviceProbe.localAddress(toward: device.ipAddress) else {
            sessionEnded(device: device, error: DLNAError.noRoute(device.ipAddress))
            return
        }
        let url = URL(string: "http://\(host):\(transport.port)\(HTTPStreamTransport.path)")!
        let stream = StreamFormat(width: size.0, height: size.1, fps: 30, codec: .h264,
                                  h264Profile: .restrictedHigh2, h264LevelBit: 0x10,
                                  audio: prefs.audio ? .aac : nil)
        // TVs buffer a few seconds anyway; frequent key frames let them start quickly.
        runPipeline(device: device, stream: stream, transport: transport, bitrate: min(prefs.bitrate, 10_000_000),
                    keyframeInterval: 1, inputBackChannel: false, gen: gen)
        Log.info("DLNA", "Asking \(renderer.friendlyName) to play \(url.absoluteString)")
        renderer.play(url: url, title: "Mira - \(options.friendlyName)") { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation else { return }
                if let error { self.sessionEnded(device: device, error: error); return }
                Log.info("DLNA", "The TV accepted the stream; it usually starts playing within a few seconds")
                self.monitorRenderer(renderer, transport: transport, device: device, gen: gen)
            }
        }
    }

    // The session ends when the TV stops playing (remote control) or never fetches the stream.
    private func monitorRenderer(_ renderer: DLNARenderer, transport: HTTPStreamTransport, device: MiracastDevice, gen: Int) {
        let started = Date()
        var wasPlaying = false
        var stoppedSince: Date?
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3, repeating: 3)
        t.setEventHandler { [weak self] in
            guard let self, gen == self.generation else { return }
            let viewers = transport.viewerCount
            if viewers == 0, !transport.everConnected, Date().timeIntervalSince(started) > 25 {
                self.sessionEnded(device: device, error: DLNAError.neverFetched)
                return
            }
            renderer.transportState { state in
                self.queue.async {
                    guard gen == self.generation, let state else { return }
                    if state == "PLAYING" || state == "TRANSITIONING" { wasPlaying = true; stoppedSince = nil; return }
                    guard wasPlaying || transport.everConnected else { return }
                    let since = stoppedSince ?? Date()
                    stoppedSince = since
                    if (state == "STOPPED" || state == "NO_MEDIA_PRESENT") && Date().timeIntervalSince(since) > 4 {
                        Log.info("DLNA", "The TV stopped playing")
                        self.sessionEnded(device: device, error: nil)
                    }
                }
            }
        }
        t.resume()
        dlna = (renderer, t)
    }

    enum DLNAError: LocalizedError {
        case notARenderer(String)
        case noRoute(String)
        case neverFetched

        var errorDescription: String? {
            switch self {
            case .notARenderer(let ip): return "Nothing at \(ip) answered as a Miracast adapter (port 7250), Google Cast device (8009) or DLNA TV. Check the address and that the device is on and on this network."
            case .noRoute(let ip): return "No network route to \(ip)"
            case .neverFetched: return "The TV accepted the stream but never started fetching it. Some TVs only play files from DLNA, not live streams; check that the Mac's firewall allows incoming connections for Mira."
            }
        }
    }

    // MARK: - Google Cast

    private func startCastSession(_ device: MiracastDevice, gen: Int) {
        if options.remoteInput { Log.info("Cast", "Input from the TV is not available with Google Cast") }
        let prefs = options.prefs
        let size: (Int, Int)
        switch prefs.resolution {
        case .p2160: size = (3840, 2160)
        case .p720: size = (1280, 720)
        case .auto, .p1080: size = (1920, 1080)
        }
        let hevc = VideoEncoder.hevcAvailable
        let videoCodecs: [VideoCodec]
        switch prefs.codec {
        case .hevc: videoCodecs = hevc ? [.h265, .h264] : [.h264]
        case .h264: videoCodecs = [.h264]
        case .auto: videoCodecs = hevc && size.0 > 1920 ? [.h265, .h264] : [.h264]
        }
        let audioCodecs: [StreamFormat.Audio] = prefs.audio
            ? (CompressedAudioEncoder.opusAvailable && prefs.audioCodec != .aac ? [.opus, .aac] : [.aac]) : []
        let maxBitrate = size.0 > 1920 ? prefs.bitrate * 5 / 2 : prefs.bitrate
        let delayMs = options.ptsDelay.map { Int($0 * 1000) } ?? (options.lowLatency ? 150 : 250)

        let session = CastSession(host: device.ipAddress, port: device.port, queue: queue)
        cast = session
        session.makeOffer = {
            CastOffer.make(videoCodecs: videoCodecs, audioCodecs: audioCodecs, width: size.0, height: size.1,
                           fps: prefs.fps, maxBitRate: maxBitrate, targetDelayMs: delayMs)
        }
        session.onAnswer = { [weak self] offer, answer in
            guard let self, gen == self.generation else { return }
            self.startCastPipeline(device: device, offer: offer, answer: answer, size: size,
                                   maxBitrate: maxBitrate, gen: gen)
        }
        session.onClosed = { [weak self] error in
            guard let self, gen == self.generation else { return }
            if case CastChannel.ChannelError.refused? = error, CastPairing.isBehindGateway(device) {
                self.sessionEnded(device: device, error: MiraError.castGatewayNeedsPairing(device))
                self.onPairingNeeded?(device)
                return
            }
            self.sessionEnded(device: device, error: error)
        }
        session.start()
    }

    private func startCastPipeline(device: MiracastDevice, offer: CastOffer, answer: CastAnswer,
                                   size: (Int, Int), maxBitrate: Int, gen: Int) {
        var video: CastTransport.StreamSetup?
        var audio: CastTransport.StreamSetup?
        for (i, index) in answer.sendIndexes.enumerated() {
            guard let s = offer.streams.first(where: { $0.index == index }) else { continue }
            let setup = CastTransport.StreamSetup(offer: s, receiverSSRC: answer.ssrcs[i])
            if s.kind == .video, video == nil { video = setup }
            if s.kind == .audio, audio == nil { audio = setup }
        }
        guard let videoSetup = video else {
            sessionEnded(device: device, error: CastSession.SessionError.answerRejected("the device picked no video stream"))
            return
        }
        let fit = answer.fit(width: size.0, height: size.1, fps: options.prefs.fps)
        let bitrate = min(maxBitrate, answer.maxVideoBitRate ?? maxBitrate)
        let stream = StreamFormat(width: fit.width, height: fit.height, fps: fit.fps,
                                  codec: videoSetup.offer.codecName == "hevc" ? .h265 : .h264,
                                  h264Profile: .restrictedHigh2, h264LevelBit: 0x40,
                                  audio: audio.map { $0.offer.codecName == "opus" ? .opus : .aac })
        let transport = CastTransport(receiverIP: device.ipAddress, udpPort: answer.udpPort, video: video, audio: audio)
        // Cast receivers ask for keyframes when they need one; periodic ones only waste bits.
        runPipeline(device: device, stream: stream, transport: transport, bitrate: bitrate,
                    keyframeInterval: 10, inputBackChannel: false, gen: gen)
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
        cast?.onClosed = nil
        cast?.stop(); cast = nil
        if let d = dlna {
            d.monitor.cancel()
            d.renderer.stop()
            dlna = nil
        }
        uibc?.stop(); uibc = nil
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
    case castGatewayNeedsPairing(MiracastDevice)
    case useAirPlay(String)

    var errorDescription: String? {
        switch self {
        case .miceFailed(let d, let e):
            return "Could not reach \(d.name) at \(d.ipAddress):\(d.port) (\(e)). Is the adapter joined to this Wi-Fi network and powered on? Is Mira allowed under System Settings -> Privacy & Security -> Local Network? (The original non-4K Microsoft adapter does not support Miracast over Wi-Fi at all.)"
        case .castGatewayNeedsPairing(let d):
            return "\(d.name) is behind the hotel's (or venue's) casting system, which only lets paired devices connect. Pair this Mac: enter the code shown on the TV, or scan the TV's QR code with Mira (or open its link on this Mac), then connect again."
        case .useAirPlay(let name):
            return "\(name) is an AirPlay display. macOS mirrors to it by itself: Control Center -> Screen Mirroring -> \(name)."
        }
    }
}
