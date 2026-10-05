import Foundation
import CoreGraphics
import Network

// `Mira doctor`: checks the local causes of "the adapter never shows anything".
enum Doctor {

    private static var emit: (String) -> Void = { print($0) }

    // The same checks as `run()`, returned as text (for the diagnostics bundle).
    static func report() -> String {
        var text = ""
        let previous = emit
        emit = { text += $0 + "\n" }
        run()
        emit = previous
        return text
    }

    static func run() {
        emit("Mira doctor\n")
        checkScreenRecording()
        checkFirewall()
        checkPort(7236, what: "RTSP (the sink connects here)")
        checkPort(19000, what: "RTP source port")
        checkInterfaces()
        checkVPN()
        checkExtendMode()
        checkCodecs()
        checkRemoteInput()
        emit("""

        Local Network permission: if `Mira list` finds nothing although the adapter is on, make sure Mira is
        enabled in System Settings -> Privacy & Security -> Local Network (macOS reports no error when it's off).

        Also check on the adapter side:
          - A Microsoft *4K* Wireless Display Adapter. The older non-4K model has no Wi-Fi/infrastructure mode.
          - Joined to the same 5 GHz WPA2/WPA3-Personal network via the Microsoft Wireless Display Adapter app
            on a Windows 10/11 PC, with current firmware. Enterprise (802.1X) and captive-portal networks are not supported.
          - The network allows device-to-device traffic (guest Wi-Fi / "client isolation" breaks this).
          - `Mira list` (or `dns-sd -B _display._tcp`) shows the adapter.
        """)
    }

    private static func checkScreenRecording() {
        if CGPreflightScreenCaptureAccess() {
            ok("Screen Recording permission granted")
        } else {
            warn("Screen Recording permission not granted to this process (the terminal app when run from a shell).",
                 fix: "System Settings -> Privacy & Security -> Screen & System Audio Recording -> enable your terminal, then restart it. `--test-pattern` works without it.")
        }
    }

    private static func checkCodecs() {
        if VideoEncoder.hevcAvailable {
            ok("HEVC (H.265) encoder available - used for 4K on displays that support Miracast 2 HEVC")
        } else {
            emit("  [info] No HEVC encoder on this Mac; Mira uses H.264 (which every display supports)")
        }
    }

    private static func checkRemoteInput() {
        if InputInjector.hasPermission {
            ok("Accessibility permission granted (needed for \"Allow TV input\" / --remote-input)")
        } else {
            emit("  [info] Accessibility permission not granted. Only needed for \"Allow TV input\" (--remote-input):\n"
                 + "         System Settings -> Privacy & Security -> Accessibility -> enable Mira (or your terminal)")
        }
    }

    private static func checkFirewall() {
        let fw = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        let state = shell(fw, ["--getglobalstate"])
        guard state.contains("enabled") || state.contains("State = 1") || state.contains("State = 2") else {
            ok("Application firewall is off")
            return
        }
        if shell(fw, ["--getblockall"]).lowercased().contains("enabled") {
            warn("Firewall blocks ALL incoming connections - the adapter cannot connect back to Mira.",
                 fix: "System Settings -> Network -> Firewall -> Options -> turn off 'Block all incoming connections'.")
            return
        }
        let exe = CommandLine.arguments[0].hasPrefix("/") ? CommandLine.arguments[0]
            : FileManager.default.currentDirectoryPath + "/" + CommandLine.arguments[0]
        // `--getappblocked` claims "permitted" even for unknown paths, so consult the
        // actual allow list instead.
        let apps = shell(fw, ["--listapps"]).components(separatedBy: "\n")
        let entry = apps.firstIndex { $0.contains(exe) }
        let allowed = entry.map { i in apps[i...].prefix(2).joined().contains("Allow incoming") } ?? false
        if allowed {
            ok("Firewall is on and explicitly allows \(exe)")
        } else {
            warn("Firewall is on. The sink must open a TCP connection to this Mac on port 7236.",
                 fix: "Either allow Mira when macOS asks, or run:\n      sudo \(fw) --add \(exe)\n      sudo \(fw) --unblockapp \(exe)\n    (Ad-hoc signed debug builds change identity on every build, so macOS may ask again.)")
        }
    }

    private static func checkPort(_ port: UInt16, what: String) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        // Same as Mira's listener: lingering TIME_WAIT sockets from a previous session don't count.
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if r == 0 { ok("Port \(port) is free - \(what)") }
        else { warn("Port \(port) is in use - \(what)", fix: "Quit the other process (`lsof -i :\(port)`), or pass --rtsp-port/--rtp-port.") }
    }

    private static func checkInterfaces() {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return }
        defer { freeifaddrs(addrs) }
        var found: [String] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let name = String(cString: ifa.ifa_name)
            if name.hasPrefix("en") || name.hasPrefix("bridge") { found.append("\(name) \(String(cString: host))") }
        }
        if found.isEmpty { warn("No active IPv4 network interface", fix: "Connect to the same Wi-Fi as the adapter.") }
        else { ok("IPv4 interfaces: \(found.joined(separator: ", ")) - the adapter must be on the same subnet") }
    }

    // A VPN that captures LAN traffic hides the adapter. Split tunnels are fine.
    private static func checkVPN() {
        let nwi = shell("/usr/sbin/scutil", ["--nwi"])
        guard nwi.contains("VPN server") else { return }
        emit("  [info] A VPN is connected. Discovery handles that, but if the adapter can't be reached, try disconnecting it.")
    }


    // Creates and drops a small virtual display to see whether Extend mode can work here.
    private static func checkExtendMode() {
        guard ExtendedDisplay.isSupported else {
            emit("  [info] Extend (second screen) mode is not available on this macOS version; Mirror mode works")
            return
        }
        var result: Bool?
        Task { @MainActor in result = await ExtendedDisplay.probe() }
        while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if result == true { ok("Extend (second screen) mode works on this Mac") }
        else { emit("  [info] Extend (second screen) mode: macOS didn't switch the virtual display on, so Mira will mirror instead") }
    }

    private static func ok(_ s: String) { emit("  [ok]   \(s)") }
    private static func warn(_ s: String, fix: String) { emit("  [warn] \(s)\n         -> \(fix)") }

    private static func shell(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
