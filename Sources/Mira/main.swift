import AppKit
import Foundation

// Mira                      menu bar app (default)
// Mira <command> [...]      headless CLI - see `Mira help`
// MIRA_HEADLESS=1 Mira      CLI help instead of the menu bar app

let cliArgs = Array(CommandLine.arguments.dropFirst())

if !cliArgs.isEmpty || ProcessInfo.processInfo.environment["MIRA_HEADLESS"] == "1" {
    CLI.run(cliArgs)
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // no Dock icon
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
