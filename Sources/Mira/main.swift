import Foundation

// Usage:
//   swift run Mira              — browse mDNS for Miracast devices, mirror to first found
//   swift run Mira 192.168.1.5  — connect directly to that IP (skip discovery)

let directIP: String? = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil

if let ip = directIP {
    print("[Mira] Direct mode → \(ip)")
} else {
    print("[Mira] Discovery mode — scanning for Miracast receivers on local network")
    print("[Mira] Tip: if discovery fails, rerun with the adapter's IP as argument")
}

let controller = MiraController()
Task {
    await controller.run(connectDirectlyTo: directIP)
}

// Handle Ctrl-C gracefully
let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSrc.setEventHandler {
    print("\n[Mira] Stopping...")
    controller.stop()
    exit(0)
}
signal(SIGINT, SIG_IGN)
sigintSrc.resume()

RunLoop.main.run()
