import AppKit
import Foundation

// CLI: swift run Mira [<ip>]   — runs headless (no Dock icon, no menu bar)
// App: make run                — menu bar app with device picker
//
// Environment variable MIRA_HEADLESS=1 forces CLI mode even when built as app.

let isHeadless = CommandLine.arguments.count > 1 || ProcessInfo.processInfo.environment["MIRA_HEADLESS"] == "1"

if isHeadless {
    // ── Headless CLI mode ───────────────────────────────────────────────
    let directIP: String? = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil

    if let ip = directIP {
        print("[Mira] Direct mode → \(ip)")
    } else {
        print("[Mira] Discovery mode — scanning for Miracast receivers")
        print("[Mira] Tip: if mDNS fails, pass the adapter IP as argument")
    }

    let controller = MiraController()
    Task { await controller.run(connectDirectlyTo: directIP) }

    let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sig.setEventHandler { print("\n[Mira] Stopping..."); controller.stop(); exit(0) }
    signal(SIGINT, SIG_IGN)
    sig.resume()

    RunLoop.main.run()
} else {
    // ── Menu bar app mode ────────────────────────────────────────────────
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // no Dock icon
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
