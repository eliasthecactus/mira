import Foundation

// Headless command-line front end. Designed for bring-up against real hardware:
// every RTSP message goes to ~/Library/Logs/Mira/mira.log, and --verbose also
// prints them.
enum CLI {

    static let usage = """
    Mira — Miracast (MS-MICE) screen mirroring for macOS

    USAGE
      Mira                              Menu bar app
      Mira list [--timeout <s>]         Scan the network for Miracast-over-Wi-Fi sinks
      Mira connect <ip|name> [options]  Mirror headless until Ctrl-C
      Mira displays                     List this Mac's displays (for --display)
      Mira doctor                       Check firewall/permissions/network for common problems
      Mira --version

    CONNECT OPTIONS
      --test-pattern          Send a generated test pattern + beep (no Screen Recording permission needed)
      --display <n>           Which display to mirror (number from `Mira displays`; default: main)
      --no-audio              Video only
      --audio-codec <c>       auto (default: AAC, else LPCM) | aac | lpcm
      --resolution <r>        auto (default) | 1080p | 720p
      --fps <n>               30 (default) or 60 (only if the sink supports it)
      --bitrate <mbps>        Video bitrate in Mbit/s (default 6)
      --delay <ms>            Sink buffer / latency (default: 200 AAC, 150 LPCM, 120 video-only)
      --name <text>           Name shown on the TV (default: this Mac's name)
      --port <n>              Sink's MICE port (default 7250)
      --rtsp-port <n>         Local RTSP port the sink connects to (default 7236)
      --rtp-port <n>          Local UDP source port for RTP (default 19000)
      --dump-ts <file.ts>     Also save the exact MPEG-TS stream sent (play with ffplay)
      --no-reconnect          Exit instead of retrying when a working session drops
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
            case "displays":
                for (i, d) in DisplayInfo.all().enumerated() { print("  \(i + 1)  \(d.label)") }
                exit(0)
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
        let browser = DeviceBrowser()
        var found: [MiracastDevice] = []
        browser.onDeviceFound = { d in
            if !found.contains(d) {
                found.append(d)
                print("  \(d.name)\t\(d.ipAddress):\(d.port)\(d.containerID.map { "\tcontainer_id=\($0)" } ?? "")")
            }
        }
        print("Scanning for \(DeviceBrowser.serviceType) for \(Int(timeout))s…")
        browser.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            browser.stop()
            if found.isEmpty {
                print("""
                No sinks found. Check that:
                  • the adapter is a Microsoft 4K Wireless Display Adapter (the older model has no Wi-Fi mode),
                  • it was joined to this Wi-Fi network with the Microsoft Wireless Display Adapter app,
                  • this Mac is on the same network/VLAN (guest networks often block device-to-device traffic).
                Tip: `dns-sd -B _display._tcp` shows raw mDNS results. You can also connect by IP.
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
        var target: String?
        var micePort = MiracastDevice.defaultMICEPort
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
            case "--display":
                let n: Int = try number(a)
                let displays = DisplayInfo.all()
                guard displays.indices.contains(n - 1) else {
                    throw ParseError(description: "--display must be 1…\(displays.count) (see `Mira displays`)")
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
                guard let r = StreamPreferences.ResolutionChoice(rawValue: v) else {
                    throw ParseError(description: "--resolution must be auto, 1080p or 720p")
                }
                opts.prefs.resolution = r
            case "--fps": opts.prefs.fps = try number(a)
            case "--bitrate":
                let v = try value(a)
                guard let mbps = Double(v), mbps > 0.2, mbps <= 40 else { throw ParseError(description: "--bitrate in Mbit/s, e.g. 6") }
                opts.prefs.bitrate = Int(mbps * 1_000_000)
            case "--delay":
                let ms: Int = try number(a)
                opts.ptsDelay = Double(ms) / 1000
            case "--name": opts.friendlyName = try value(a)
            case "--port": micePort = try number(a)
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
        Log.info("Mira", "Mira \(AppInfo.version) — log file: \(Log.logFileURL.path)")

        let controller = MiraController(options: opts)
        var everStreamed = false
        controller.onStatusChanged = { status in
            switch status {
            case .streaming(let d, let res):
                everStreamed = true
                Log.info("Mira", "✅ Mirroring to \(d.name) at \(res). Press Ctrl-C to stop.")
            case .failed:
                // The controller already logged the reason.
                Log.info("Mira", "❌ Failed. Full log: \(Log.logFileURL.path)")
                Log.flush()
                exit(everStreamed ? 0 : 1)
            case .idle:
                if everStreamed {
                    Log.info("Mira", "Session ended")
                } else {
                    Log.error("Mira", "❌ Session ended before streaming started. Full log: \(Log.logFileURL.path)")
                }
                Log.flush()
                exit(everStreamed ? 0 : 1)
            case .connecting:
                break
            }
        }

        let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sig.setEventHandler {
            Log.info("Mira", "Stopping…")
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
            if s.isStreaming { Log.info("Stats", String(format: "%.1f fps, %d kbit/s", s.fps, s.kbps)) }
        }
        t.resume()
        statsTimer = t
        _ = statsTimer

        if isIPAddress(target) {
            controller.connect(to: MiracastDevice(name: target, ipAddress: target, port: micePort))
        } else {
            Log.info("Mira", "Looking for a sink named “\(target)”…")
            var done = false
            controller.onDevicesChanged = { devices in
                guard !done, let d = devices.first(where: { $0.name.localizedCaseInsensitiveContains(target) }) else { return }
                done = true
                controller.stopDiscovery()
                controller.connect(to: d)
            }
            controller.startDiscovery()
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                guard !done else { return }
                Log.error("Mira", "No sink matching “\(target)” found. Try `Mira list`, or connect by IP.")
                Log.flush()
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(0)
    }

    static func isIPAddress(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1 || s == "localhost"
    }
}
