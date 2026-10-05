import Foundation

// Headless command-line front end. Designed for bring-up against real hardware:
// every RTSP message goes to ~/Library/Logs/Mira/mira.log, and --verbose also
// prints them.
enum CLI {

    static let usage = """
    Mira - screen mirroring from macOS to Miracast (MS-MICE) and Google Cast displays

    USAGE
      Mira                              Menu bar app
      Mira list [--timeout <s>]         Scan the network for Miracast and Google Cast displays
      Mira connect <ip|name> [options]  Mirror headless until Ctrl-C
      Mira displays                     List this Mac's displays (for --display)
      Mira windows                      List apps and windows that can be shared (for --app / --window)
      Mira doctor                       Check firewall/permissions/network for common problems
      Mira diagnose [--out <file.zip>]  Save a diagnostics bundle (log, doctor, system & network info)
      Mira update [--check]             Install the newest release from GitHub (app installs only)
      Mira --version

    CONNECT OPTIONS
      --test-pattern          Send a generated test pattern + beep (no Screen Recording permission needed)
      --display <n>           Which display to mirror (number from `Mira displays`; default: main)
      --app <name|bundle-id>  Share only this app's windows (everything else stays black)
      --window <title|id>     Share only this window (from `Mira windows`)
      --no-audio              Video only
      --audio-codec <c>       auto (default: AAC, else LPCM) | aac | lpcm
      --resolution <r>        auto (default, up to 1080p) | 4k | 1080p | 720p
      --codec <c>             auto (default: H.264, HEVC for 4K if the display has it) | h264 | hevc
      --legacy-formats        Negotiate like a Miracast 1 source (H.264 only) for displays that misbehave
      --remote-input          Let the TV's keyboard/mouse/touch control this Mac (UIBC; needs Accessibility)
      --low-latency           Smaller buffer + LPCM audio + low-latency encoder (~100 ms less delay)
      --fps <n>               30 (default) or 60 (only if the sink supports it)
      --bitrate <mbps|auto>   auto (default): adapts to the Wi-Fi, up to --max-bitrate; a number = fixed
      --max-bitrate <mbps>    Ceiling for auto bitrate (default 12)
      --extend                Use the TV as a second screen instead of mirroring (virtual display)
      --security <s>          auto (default) | off | encrypted | pin   (MS-MICE DTLS / PIN pairing)
      --pin <digits>          PIN shown on the TV (otherwise asked for when needed)
      --keep-mac-audio        Don't mute the Mac's speakers while mirroring
      --delay <ms>            Sink buffer / latency (default: 200 AAC, 150 LPCM, 120 video-only)
      --name <text>           Name shown on the TV (default: this Mac's name)
      --cast / --miracast / --dlna   Protocol when connecting by IP (default: detected)
      --dlna-url <url>        The TV's UPnP description URL (skips SSDP discovery)
      --port <n>              Device port (Miracast 7250, Cast 8009, or the port a hotel gateway uses)
      --pair <code|link>      Pair with a hotel/venue TV first (the code or QR-code link it shows)
      --rtsp-port <n>         Local RTSP port the sink connects to (default 7236)
      --rtp-port <n>          Local UDP source port for RTP (default 19000)
      --dump-ts <file.ts>     Also save the exact MPEG-TS stream sent (play with ffplay)
      --no-reconnect          Exit instead of retrying when a working session drops
      --probe-wfd2            Also ask the display for more Miracast 2 / vendor capabilities (logged)
      --verbose               Print full RTSP/MICE messages

    Log file: \(Log.logFileURL.path)
    """

    struct ParseError: Error, CustomStringConvertible { let description: String }

    static func run(_ args: [String]) -> Never {
        var args = args
        if args.contains("--verbose") || args.contains("-v") {
            Log.consoleLevel = .debug
            args.removeAll { $0 == "--verbose" || $0 == "-v" }
        }
        MacAudioMuter.restoreAfterCrash()       // unmute if a previous session was killed
        let command = args.first ?? "help"
        do {
            switch command {
            case "list":
                try list(Array(args.dropFirst()))
            case "connect":
                try connect(Array(args.dropFirst()))
            case "doctor":
                Doctor.run()
                exit(0)
            case "diagnose":
                var out: URL?
                if let i = args.firstIndex(of: "--out"), i + 1 < args.count { out = URL(fileURLWithPath: args[i + 1]) }
                var result: Result<URL, Error>?
                Task { do { result = .success(try await Diagnostics.export(to: out)) } catch { result = .failure(error) } }
                while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                switch result! {
                case .success(let url): print("Saved \(url.path)\nAttach it to a GitHub issue: \(AppInfo.releasesURL.deletingLastPathComponent().appendingPathComponent("issues/new/choose"))")
                case .failure(let e): FileHandle.standardError.write(Data("error: \(e.localizedDescription)\n".utf8)); exit(1)
                }
                exit(0)
            case "displays":
                for (i, d) in DisplayInfo.all().enumerated() { print("  \(i + 1)  \(d.label)") }
                exit(0)
            case "windows":
                let items = try shareableItems()
                print("Apps (use --app <name>):")
                for a in items.apps { print("  \(a.name)\t\(a.bundleID)\t\(a.windowCount) window\(a.windowCount == 1 ? "" : "s")") }
                print("\nWindows (use --window <id or title>):")
                for w in items.windows { print("  \(w.id)\t\(w.appName) - \(w.title)  (\(Int(w.size.width))x\(Int(w.size.height)))") }
                exit(0)
            case "update":
                let checkOnly = args.contains("--check")
                var result: Result<String, Error>?
                Task {
                    do {
                        guard let r = try await Updater.latest(includePrereleases: args.contains("--beta") ? true : nil) else {
                            result = .success("Mira \(AppInfo.version) is the newest version."); return
                        }
                        if checkOnly { result = .success("Mira \(r.version) is available: \(r.page)"); return }
                        let app = try await Updater.install(r) { print($0) }
                        result = .success("Updated to \(r.version) at \(app.path). Restart Mira to use it.")
                    } catch { result = .failure(error) }
                }
                while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                switch result! {
                case .success(let msg): print(msg); exit(0)
                case .failure(let e): FileHandle.standardError.write(Data("error: \(e.localizedDescription)\n".utf8)); exit(1)
                }
            case "--version", "version":
                print("Mira \(AppInfo.version)")
                exit(0)
            case "help", "--help", "-h":
                print(usage)
                exit(0)
            default:
                // Backwards compatible: `Mira <ip>`
                if command.first?.isNumber == true { try connect(args) }
                throw ParseError(description: "Unknown command '\(command)'")
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n\n\(usage)\n".utf8))
            exit(2)
        }
    }

    // MARK: - list

    private static func list(_ args: [String]) throws -> Never {
        var timeout: TimeInterval = 8
        var i = 0
        while i < args.count {
            if args[i] == "--timeout", i + 1 < args.count, let t = TimeInterval(args[i + 1]) { timeout = t; i += 2 }
            else { throw ParseError(description: "Unknown option \(args[i])") }
        }
        let browsers = [DeviceBrowser(kind: .miracast), DeviceBrowser(kind: .googleCast), DeviceBrowser(kind: .airplay)]
        var found: [MiracastDevice] = []
        for browser in browsers {
            browser.onDeviceFound = { d in
                DispatchQueue.main.async {
                    guard !found.contains(where: { $0.kind == d.kind && $0.serviceName == d.serviceName }) else { return }
                    found.append(d)
                    let extra = d.containerID.map { "\tcontainer_id=\($0)" } ?? d.model.map { "\t\($0)" } ?? ""
                    if d.kind == .airplay {
                        print("  \(d.name)\tAirPlay - use macOS Screen Mirroring (Control Center)\t\(d.ipAddress)\(extra)")
                    } else {
                        let hotel = CastPairing.isBehindGateway(d) ? "\t(hotel casting system: may need --pair <code>)" : ""
                        print("  \(d.name)\t\(d.kind.label)\t\(d.ipAddress):\(d.port)\(extra)\(hotel)")
                    }
                }
            }
            browser.start()
        }
        let ssdp = SSDPDiscovery()
        ssdp.onFound = { d, _ in
            DispatchQueue.main.async {
                guard !found.contains(where: { $0.serviceName == d.serviceName }) else { return }
                found.append(d)
                print("  \(d.name)\tDLNA\t\(d.ipAddress)\t\(d.model ?? "")")
            }
        }
        ssdp.start()
        print("Scanning for Miracast, Google Cast, DLNA and AirPlay displays for \(Int(timeout))s...")
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            browsers.forEach { $0.stop() }
            ssdp.stop()
            if found.isEmpty {
                print("""
                No displays found. Check that:
                  - the adapter is a Microsoft 4K Wireless Display Adapter (the older model has no Wi-Fi mode),
                    or a Chromecast / Google TV / TV with Chromecast built-in,
                  - it is on this Wi-Fi network (the Microsoft adapter needs the Microsoft Wireless Display Adapter app once),
                  - this Mac is on the same network/VLAN (guest networks often block device-to-device traffic).
                In a hotel: the TV usually shows a code or QR code to pair your device first; hotel casting
                systems may only show the TV after that. `mira connect <ip> --cast --port <port> --pair <code>`.
                Tip: `dns-sd -B _display._tcp` / `dns-sd -B _googlecast._tcp` show raw mDNS results. You can also connect by IP.
                """)
            }
            Log.flush()
            exit(found.isEmpty ? 1 : 0)
        }
        RunLoop.main.run()
        exit(0)
    }

    // MARK: - connect

    private static func connect(_ args: [String]) throws -> Never {
        var opts = MiraController.Options()
        opts.prefs.bitrate = Settings.autoBitrateMax * 1_000_000
        var fixedBitrate = false
        var maxBitrate: Int?
        var target: String?
        var micePort: UInt16?
        var forcedKind: MiracastDevice.Kind?
        var dlnaURL: URL?
        var pairText: String?
        var i = 0

        func value(_ name: String) throws -> String {
            guard i + 1 < args.count else { throw ParseError(description: "\(name) needs a value") }
            i += 1
            return args[i]
        }
        func number<T: FixedWidthInteger>(_ name: String) throws -> T {
            let v = try value(name)
            guard let n = T(v) else { throw ParseError(description: "\(name): '\(v)' is not a number") }
            return n
        }

        while i < args.count {
            let a = args[i]
            switch a {
            case "--test-pattern": opts.testPattern = true
            case "--app":
                let q = try value(a)
                guard let app = try shareableItems().app(matching: q) else {
                    throw ParseError(description: "No running app with a window matches '\(q)' (see `Mira windows`)")
                }
                opts.target = .app(bundleID: app.bundleID, name: app.name)
            case "--window":
                let q = try value(a)
                guard let w = try shareableItems().window(matching: q) else {
                    throw ParseError(description: "No window matches '\(q)' (see `Mira windows`)")
                }
                opts.target = .window(id: w.id, title: w.title)
            case "--display":
                let n: Int = try number(a)
                let displays = DisplayInfo.all()
                guard displays.indices.contains(n - 1) else {
                    throw ParseError(description: "--display must be 1...\(displays.count) (see `Mira displays`)")
                }
                opts.displayID = displays[n - 1].id
            case "--no-audio": opts.prefs.audio = false
            case "--audio-codec":
                let v = try value(a)
                guard let c = StreamPreferences.AudioCodecChoice(rawValue: v) else {
                    throw ParseError(description: "--audio-codec must be auto, aac or lpcm")
                }
                opts.prefs.audioCodec = c
            case "--no-reconnect": opts.autoReconnect = false
            case "--resolution":
                let v = try value(a)
                guard let r = StreamPreferences.ResolutionChoice(rawValue: v.lowercased()) else {
                    throw ParseError(description: "--resolution must be auto, 4k, 1080p or 720p")
                }
                opts.prefs.resolution = r
            case "--fps": opts.prefs.fps = try number(a)
            case "--bitrate":
                let v = try value(a)
                if v == "auto" {
                    opts.adaptiveBitrate = true
                } else {
                    guard let mbps = Double(v), mbps > 0.2, mbps <= 40 else { throw ParseError(description: "--bitrate auto, or Mbit/s, e.g. 6") }
                    opts.prefs.bitrate = Int(mbps * 1_000_000)
                    opts.adaptiveBitrate = false
                    fixedBitrate = true
                }
            case "--max-bitrate":
                let v = try value(a)
                guard let mbps = Double(v), mbps > 0.5, mbps <= 40 else { throw ParseError(description: "--max-bitrate in Mbit/s, e.g. 12") }
                maxBitrate = Int(mbps * 1_000_000)
            case "--extend": opts.extendDisplay = true
            case "--probe-wfd2": opts.prefs.extraM3Parameters = StreamPreferences.wfd2ProbeParameters
            case "--codec":
                let v = try value(a).lowercased()
                guard let c = WFDNegotiatedFormat.CodecChoice(rawValue: v == "h265" ? "hevc" : v == "avc" ? "h264" : v) else {
                    throw ParseError(description: "--codec must be auto, h264 or hevc")
                }
                opts.prefs.codec = c
            case "--legacy-formats": opts.prefs.legacyFormats = true
            case "--remote-input", "--uibc": opts.remoteInput = true
            case "--low-latency":
                opts.lowLatency = true
                opts.prefs.lowLatency = true
            case "--keep-mac-audio": opts.muteMac = false
            case "--security":
                let v = try value(a)
                guard let c = MiraController.SecurityChoice(rawValue: v) else {
                    throw ParseError(description: "--security must be auto, off, encrypted or pin")
                }
                opts.security = c
            case "--pin":
                let v = try value(a)
                guard !v.isEmpty, v.allSatisfy(\.isNumber) else { throw ParseError(description: "--pin takes the digits shown on the TV") }
                opts.pin = v
            case "--delay":
                let ms: Int = try number(a)
                opts.ptsDelay = Double(ms) / 1000
            case "--name": opts.friendlyName = try value(a)
            case "--port": micePort = try number(a)
            case "--cast": forcedKind = .googleCast
            case "--miracast": forcedKind = .miracast
            case "--dlna": forcedKind = .dlna
            case "--pair":
                pairText = try value(a)
                guard CastPairing.parse(pairText!) != nil else {
                    throw ParseError(description: "--pair takes the code shown on the TV (like 7F6GY) or the link from its QR code")
                }
            case "--dlna-url":
                guard let u = URL(string: try value(a)), u.host != nil else {
                    throw ParseError(description: "--dlna-url takes the TV's UPnP description URL, e.g. http://192.168.1.20:9197/dmr")
                }
                dlnaURL = u
                forcedKind = .dlna
            case "--rtsp-port": opts.rtspPort = try number(a)
            case "--rtp-port": opts.localRTPPort = try number(a)
            case "--dump-ts": opts.dumpTS = URL(fileURLWithPath: try value(a))
            default:
                if a.hasPrefix("-") { throw ParseError(description: "Unknown option \(a)") }
                guard target == nil else { throw ParseError(description: "Only one target allowed") }
                target = a
            }
            i += 1
        }
        guard let target else { throw ParseError(description: "connect needs an IP address or device name") }
        if !fixedBitrate, let maxBitrate { opts.prefs.bitrate = maxBitrate }
        Log.info("Mira", "Mira \(AppInfo.version) - log file: \(Log.logFileURL.path)")

        let controller = MiraController(options: opts)
        let console = ConsoleCommands(controller: controller)
        // PIN entry in the terminal, if the display asks for one and --pin wasn't given.
        controller.pinProvider = { completion in
            FileHandle.standardError.write(Data("\nEnter the PIN shown on the TV: ".utf8))
            console.awaitLine(completion)
        }
        console.start()

        // SIGUSR1 toggles the privacy pause (for scripts / hotkey tools).
        let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        usr1.setEventHandler { console.togglePrivacy(.freeze) }
        signal(SIGUSR1, SIG_IGN)
        usr1.resume()
        var everStreamed = false
        controller.onStatusChanged = { status in
            switch status {
            case .streaming(let d, let res):
                everStreamed = true
                Log.info("Mira", "Mirroring to \(d.name) at \(res). Commands: p = pause screen (freeze), b = pause (black), q = stop. Ctrl-C also stops.")
            case .failed:
                // The controller already logged the reason.
                Log.info("Mira", "Failed. Full log: \(Log.logFileURL.path)")
                exitSoon(everStreamed ? 0 : 1)
            case .idle:
                if everStreamed {
                    Log.info("Mira", "Session ended")
                } else {
                    Log.error("Mira", "Session ended before streaming started. Full log: \(Log.logFileURL.path)")
                }
                exitSoon(everStreamed ? 0 : 1)
            case .connecting:
                break
            }
        }

        let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sig.setEventHandler {
            Log.info("Mira", "Stopping...")
            controller.stopAndWait()
            Log.flush()
            exit(0)
        }
        signal(SIGINT, SIG_IGN)
        sig.resume()

        var statsTimer: DispatchSourceTimer?
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler {
            let s = controller.currentStats
            if s.isStreaming {
                Log.info("Stats", String(format: "%.1f fps, %d kbit/s sent (target %d)%@", s.fps, s.kbps, s.targetKbps,
                                         s.encrypted ? ", encrypted" : ""))
            }
        }
        t.resume()
        statsTimer = t
        _ = statsTimer

        // --pair: unlock a hotel/venue casting gateway for this Mac before connecting.
        let start = { (device: MiracastDevice) in
            guard let pairText, let input = CastPairing.parse(pairText), device.kind == .googleCast else {
                controller.connect(to: device)
                return
            }
            let pairing = CastPairing(gatewayHost: device.ipAddress, devicePort: device.port)
            pairing.openInBrowser = { url in
                Log.info("Cast", "Finish the pairing in the browser page that just opened")
                let p = Process()
                // MIRA_OPEN_COMMAND replaces `open` (tests use /usr/bin/true).
                p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIRA_OPEN_COMMAND"] ?? "/usr/bin/open")
                p.arguments = [url.absoluteString]
                try? p.run()
            }
            pairing.progress = { Log.info("Cast", $0) }
            let wait = ProcessInfo.processInfo.environment["MIRA_PAIR_WAIT"].flatMap(TimeInterval.init) ?? 120
            pairing.pair(input, waitAfterBrowser: wait) { result in
                DispatchQueue.main.async {
                    _ = pairing
                    switch result {
                    case .success:
                        Log.info("Cast", "Paired; connecting")
                        controller.connect(to: device)
                    case .failure(let error):
                        Log.error("Cast", error.localizedDescription)
                        Log.flush()
                        exit(1)
                    }
                }
            }
        }

        if isIPAddress(target) {
            let connect = { (kind: MiracastDevice.Kind) in
                start(MiracastDevice(name: target, ipAddress: target, port: micePort, kind: kind,
                                     location: kind == .dlna ? dlnaURL : nil))
            }
            if pairText != nil, forcedKind == nil { forcedKind = .googleCast }
            if let kind = forcedKind ?? (micePort != nil ? .miracast : nil) {
                connect(kind)
            } else {
                // Which protocol? Ask the device (Cast answers on 8009, MS-MICE on 7250).
                DeviceProbe.kind(of: target) { kind in
                    DispatchQueue.main.async {
                        if let kind { Log.info("Mira", "\(target) is a \(kind.label) device") }
                        else { Log.info("Mira", "\(target) did not answer as Google Cast (8009) or Miracast (7250); trying DLNA") }
                        connect(kind ?? .dlna)
                    }
                }
            }
        } else {
            Log.info("Mira", "Looking for a sink named '\(target)'...")
            var done = false
            controller.onDevicesChanged = { devices in
                guard !done, let d = devices.first(where: { $0.name.localizedCaseInsensitiveContains(target) }) else { return }
                done = true
                controller.stopDiscovery()
                start(d)
            }
            controller.startDiscovery()
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                guard !done else { return }
                Log.error("Mira", "No sink matching '\(target)' found. Try `Mira list`, or connect by IP.")
                Log.flush()
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(0)
    }

    // ScreenCaptureKit is async; the CLI resolves targets before its run loop starts.
    static func shareableItems() throws -> ShareableItems {
        var result: Result<ShareableItems, Error>?
        Task { do { result = .success(try await ShareableItems.load()) } catch { result = .failure(error) } }
        while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        switch result! {
        case .success(let items): return items
        case .failure(let e): throw ParseError(description: "Can't list windows (Screen Recording permission?): \(e.localizedDescription)")
        }
    }

    // Reads terminal lines: answers a pending PIN prompt, otherwise runs commands.
    final class ConsoleCommands: @unchecked Sendable {
        private let controller: MiraController
        private let lock = NSLock()
        private var pending: ((String?) -> Void)?

        init(controller: MiraController) { self.controller = controller }

        func start() {
            Thread.detachNewThread { [self] in
                while let line = readLine() {
                    let waiter: ((String?) -> Void)? = lock.withLock { defer { pending = nil }; return pending }
                    if let waiter { waiter(line); continue }
                    let cmd = line.trimmingCharacters(in: .whitespaces)
                    let lower = cmd.lowercased()
                    switch lower {
                    case "p": DispatchQueue.main.async { self.togglePrivacy(.freeze) }
                    case "b": DispatchQueue.main.async { self.togglePrivacy(.black) }
                    case "q": DispatchQueue.main.async { kill(getpid(), SIGINT) }
                    case "screen": controller.setTarget(.screen)
                    case "": break
                    default:
                        if lower.hasPrefix("app ") || lower.hasPrefix("window ") {
                            let isApp = lower.hasPrefix("app ")
                            let query = String(cmd.dropFirst(isApp ? 4 : 7))
                            Task {
                                guard let items = try? await ShareableItems.load() else { return }
                                if isApp, let a = items.app(matching: query) {
                                    self.controller.setTarget(.app(bundleID: a.bundleID, name: a.name))
                                } else if !isApp, let w = items.window(matching: query) {
                                    self.controller.setTarget(.window(id: w.id, title: w.title))
                                } else {
                                    FileHandle.standardError.write(Data("Nothing matches '\(query)' (see `Mira windows`)\n".utf8))
                                }
                            }
                        } else {
                            FileHandle.standardError.write(Data("Commands: p = pause (freeze), b = pause (black), screen, app <name>, window <title>, q = stop\n".utf8))
                        }
                    }
                }
            }
        }

        func awaitLine(_ completion: @escaping (String?) -> Void) {
            lock.withLock { pending = completion }
        }

        func togglePrivacy(_ mode: MediaPipeline.PrivacyMode) {
            let now = controller.togglePrivacy(mode)
            Log.info("Mira", now == .off ? "Screen resumed" : "Screen paused (\(now.rawValue)) - type p again to resume")
        }
    }

    // Status callbacks run on the controller's queue; exiting right there would kill the
    // process before queued work (e.g. an encrypted STOP_PROJECTION) reaches the wire.
    private static func exitSoon(_ code: Int32) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            Log.flush()
            exit(code)
        }
    }

    static func isIPAddress(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1 || s == "localhost"
    }
}
