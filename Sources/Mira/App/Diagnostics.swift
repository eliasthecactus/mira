import Foundation
import AppKit

// Bundles everything needed to debug a failed session into one zip: the log (with
// every MICE/RTSP message), `doctor` output, system/display/network facts, settings,
// what discovery sees, and recent crash reports.
enum Diagnostics {

    static func export(to destination: URL? = nil) async throws -> URL {
        let stamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            return f.string(from: Date())
        }()
        let name = "Mira-Diagnostics-\(stamp)"
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        Log.info("Mira", "Collecting diagnostics...")
        Log.flush()

        func write(_ file: String, _ text: String) {
            try? text.write(to: work.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }

        write("README.txt", """
        Mira diagnostics (\(AppInfo.version), \(stamp))

        mira.log        Everything Mira logged, incl. every message exchanged with the display
        mira.1.log      The previous log (if it was rotated)
        doctor.txt      Output of `mira doctor`
        system.txt      macOS / Mac / Mira version, displays
        network.txt     Interfaces, routes, VPN state, displays found on the network
        settings.txt    Mira's settings
        crashes/        Recent Mira crash reports, if any

        These files contain IP addresses and device names from your network. Review them
        before attaching them to a public GitHub issue.
        """)

        write("doctor.txt", Doctor.report())
        write("system.txt", systemInfo())
        write("settings.txt", settings())
        write("network.txt", await networkInfo())

        let fm = FileManager.default
        for (src, dst) in [(Log.logFileURL, "mira.log"), (Log.previousLogFileURL, "mira.1.log")] where fm.fileExists(atPath: src.path) {
            try? fm.copyItem(at: src, to: work.appendingPathComponent(dst))
        }
        let reports = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        if let crashes = try? fm.contentsOfDirectory(at: reports, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter({ $0.lastPathComponent.hasPrefix("Mira") })
            .sorted(by: { (a, b) in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }).prefix(3), !crashes.isEmpty {
            let dir = work.appendingPathComponent("crashes", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for c in crashes { try? fm.copyItem(at: c, to: dir.appendingPathComponent(c.lastPathComponent)) }
        }

        let target = destination ?? defaultDestination(name: name)
        try? fm.removeItem(at: target)
        _ = shell("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", work.path, target.path])
        try? fm.removeItem(at: work)
        guard fm.fileExists(atPath: target.path) else {
            throw NSError(domain: "Mira", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not write \(target.path)"])
        }
        Log.info("Mira", "Diagnostics saved to \(target.path)")
        return target
    }

    private static func defaultDestination(name: String) -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return dir.appendingPathComponent(name + ".zip")
    }

    private static func systemInfo() -> String {
        var lines = [
            "Mira \(AppInfo.version) (build \(AppInfo.build))",
            "Bundle: \(Bundle.main.bundlePath)",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Model: \(sysctl("hw.model"))  CPU: \(sysctl("machdep.cpu.brand_string"))  arch: \(shell("/usr/bin/uname", ["-m"]).trimmingCharacters(in: .whitespacesAndNewlines))",
            "Locale: \(Locale.current.identifier)",
            "Virtual displays (Extend mode) API present: \(ExtendedDisplay.isSupported)",
            "",
            "Displays:",
        ]
        lines += DisplayInfo.all().map { "  \($0.id)  \($0.label)" }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func settings() -> String {
        let domain = Bundle.main.bundleIdentifier ?? "io.github.eliasthecactus.mira"
        let dict = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        return dict.sorted { $0.key < $1.key }
            .filter { !$0.key.hasPrefix("NS") && !$0.key.hasPrefix("Apple") }
            .map { "\($0.key) = \($0.value)" }
            .joined(separator: "\n") + "\n"
    }

    private static func networkInfo() async -> String {
        var out = "== scutil --nwi\n" + shell("/usr/sbin/scutil", ["--nwi"])
        out += "\n== route to the default gateway\n" + shell("/sbin/route", ["-n", "get", "default"])
        out += "\n== interfaces\n" + shell("/sbin/ifconfig", ["-a"]).components(separatedBy: "\n")
            .filter { $0.hasPrefix("en") || $0.hasPrefix("utun") || $0.contains("inet ") || $0.contains("status:") }
            .joined(separator: "\n")
        out += "\n\n== Miracast displays found in 5 s (_display._tcp)\n"
        out += await discover().joined(separator: "\n")
        return out + "\n"
    }

    private static func discover() async -> [String] {
        await withCheckedContinuation { cont in
            let browser = DeviceBrowser()
            let lock = NSLock()
            var found: [String] = []
            browser.onDeviceFound = { d in
                lock.withLock { found.append("\(d.name)  \(d.ipAddress):\(d.port)  container_id=\(d.containerID ?? "-")") }
            }
            browser.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                browser.stop()
                let list = lock.withLock { found }
                cont.resume(returning: list.isEmpty ? ["(none - check Local Network permission and that the display is on this network)"] : list)
            }
        }
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }

    @discardableResult
    static func shell(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "(\(path) failed: \(error.localizedDescription))\n" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
