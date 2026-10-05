import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusBar: StatusBarController!
    private let controller = MiraController(options: Settings.options())
    private var statsTimer: Timer?
    private var updateTimer: Timer?
    private var hotKey: GlobalHotKey?
    private var privacyHotKey: GlobalHotKey?
    private var pendingAutoConnect: MiracastDevice?
    private var devices: [MiracastDevice] = []
    private var lastGatewayDevice: MiracastDevice?     // last hotel-gateway TV the user tried
    private var scanner: QRScannerWindowController?
    private var pairing: CastPairing?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Mira", "Menu bar app \(AppInfo.version) (\(AppInfo.build)) started; log file \(Log.logFileURL.path)")
        MacAudioMuter.restoreAfterCrash()
        statusBar = StatusBarController()

        statusBar.onMirrorRequested = { [weak self] device in self?.startMirroring(to: device) }
        statusBar.onStopRequested = { [weak self] in self?.controller.stop() }

        controller.onDevicesChanged = { [weak self] devices in
            DispatchQueue.main.async {
                guard let self else { return }
                self.devices = devices
                self.statusBar.updateDevices(devices)
                // Reconnect on launch: wait until the remembered display shows up.
                if let want = self.pendingAutoConnect, let d = devices.first(where: { $0.name == want.name }) {
                    self.pendingAutoConnect = nil
                    Log.info("Mira", "Reconnecting to \(d.name) (reconnect on launch)")
                    self.startMirroring(to: d)
                }
            }
        }
        controller.pinProvider = { completion in
            DispatchQueue.main.async { completion(Self.askForPIN()) }
        }
        controller.onPairingNeeded = { [weak self] device in
            DispatchQueue.main.async {
                self?.lastGatewayDevice = device
                self?.askToPair(device)
            }
        }
        statusBar.onPairRequested = { [weak self] in
            guard let self else { return }
            self.askToPair(self.lastGatewayDevice ?? self.devices.first(where: CastPairing.isBehindGateway))
        }
        controller.onStatusChanged = { [weak self] status in
            DispatchQueue.main.async { self?.statusChanged(status) }
        }
        controller.startDiscovery()

        hotKey = GlobalHotKey(id: 1, keyCode: GlobalHotKey.toggleMirroring.keyCode) { [weak self] in self?.toggleMirroring() }
        privacyHotKey = GlobalHotKey(id: 2, keyCode: GlobalHotKey.togglePrivacy.keyCode) { [weak self] in self?.togglePrivacy() }
        statusBar.onPrivacyToggle = { [weak self] in self?.togglePrivacy() }
        statusBar.onTargetChange = { [weak self] target in self?.controller.setTarget(target) }

        if Settings.reconnectOnLaunch, let last = Settings.lastDevice {
            if last.name == last.ipAddress {
                // Added by IP, so it may never appear in discovery.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.startMirroring(to: last) }
            } else {
                pendingAutoConnect = last
                // Fall back to the remembered address if discovery doesn't find it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                    guard let self, let want = self.pendingAutoConnect else { return }
                    self.pendingAutoConnect = nil
                    self.startMirroring(to: want)
                }
            }
        }

        // A menu-bar-only app is easy to miss: show the popover on first launch.
        if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.statusBar.showPopover() }
        }

        checkForUpdates()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdates()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stopAndWait()
        Log.flush()
    }

    private func startMirroring(to device: MiracastDevice) {
        if device.kind == .airplay {
            explainAirPlay(device)
            return
        }
        if CastPairing.isBehindGateway(device) { lastGatewayDevice = device }
        let options = Settings.options()
        if !options.testPattern && !CGPreflightScreenCaptureAccess() {
            requestScreenRecordingPermission()
            return
        }
        controller.options = options
        controller.connect(to: device)
    }

    // Ctrl+Opt+Cmd+M: stop if mirroring, otherwise reconnect to the last display.
    private func toggleMirroring() {
        switch controller.status {
        case .streaming, .connecting:
            controller.stop()
        default:
            if let last = Settings.lastDevice { startMirroring(to: last) } else { statusBar.showPopover() }
        }
    }

    private func togglePrivacy() {
        let mode = controller.togglePrivacy(Settings.privacyMode)
        statusBar.setPrivacy(mode != .off)
    }

    private static func askForPIN() -> String? {
        let alert = NSAlert()
        alert.messageText = "Enter the PIN shown on the TV"
        alert.informativeText = "The display asked for PIN pairing."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "12345678"
        field.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let digits = field.stringValue.filter(\.isNumber)
        return digits.isEmpty ? nil : digits
    }

    // MARK: - Hotel / venue TVs: pairing

    // `device` is the TV to connect to afterwards (nil: just pair the Mac).
    private func askToPair(_ device: MiracastDevice?, prefill: String = "", note: String? = nil) {
        let alert = NSAlert()
        alert.messageText = device.map { "Pair this Mac with \($0.name)" } ?? "Pair this Mac with a TV"
        alert.informativeText = (note.map { $0 + "\n\n" } ?? "") + """
        This TV is behind the hotel's (or venue's) casting system, which only lets paired devices connect. \
        Enter the code shown on the TV, paste the link from its QR code, or scan the QR code with a camera.
        """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Code (like 7F6GY) or link"
        field.stringValue = prefill
        alert.accessoryView = field
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Scan QR Code...")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            runPairing(field.stringValue, device: device)
        case .alertSecondButtonReturn:
            let s = QRScannerWindowController()
            scanner = s
            s.onResult = { [weak self] text in
                self?.scanner = nil
                guard let self else { return }
                if let text { self.runPairing(text, device: device) }
                else { self.askToPair(device) }
            }
            s.start()
        default:
            break
        }
    }

    private func runPairing(_ text: String, device: MiracastDevice?) {
        guard let input = CastPairing.parse(text) else {
            askToPair(device, prefill: text, note: CastPairing.PairingError.invalidInput.localizedDescription)
            return
        }
        // Which gateway? The TV's address, or the host of the link.
        var host = device?.ipAddress
        if host == nil, case .link(let url) = input { host = url.host }
        guard let host else {
            askToPair(nil, prefill: text, note: "Mira hasn't seen the TV yet. Paste the link from the TV's QR code (it names the casting system), or wait until the TV shows up in the list.")
            return
        }
        let port = device?.port ?? devices.first(where: { $0.ipAddress == host && $0.kind == .googleCast })?.port ?? CastChannel.defaultPort
        let p = CastPairing(gatewayHost: host, devicePort: port)
        pairing = p
        p.openInBrowser = { url in NSWorkspace.shared.open(url) }
        p.progress = { [weak self] message in DispatchQueue.main.async { self?.statusBar.showMessage(message) } }
        statusBar.showMessage("Pairing...")
        statusBar.showPopover()
        p.pair(input) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pairing = nil
                switch result {
                case .success:
                    Log.info("Cast", "Paired with the casting system at \(host)")
                    if let device {
                        self.statusBar.showMessage("Paired - connecting to \(device.name)...")
                        self.startMirroring(to: device)
                    } else {
                        self.statusBar.showMessage("Paired. Choose the TV in the list.")
                    }
                case .failure(let error):
                    Log.warn("Cast", "Pairing: \(error.localizedDescription)")
                    self.askToPair(device, prefill: text, note: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - AirPlay displays

    private func explainAirPlay(_ device: MiracastDevice) {
        let alert = NSAlert()
        alert.messageText = "\(device.name) supports AirPlay"
        alert.informativeText = """
        macOS mirrors to AirPlay displays by itself, with less delay than any other way:

        Control Center (menu bar) -> Screen Mirroring -> \(device.name)

        Or in System Settings -> Displays, add it with the + button to use it as a second screen.
        """
        alert.addButton(withTitle: "Open Displays Settings")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
        }
    }

    private func requestScreenRecordingPermission() {
        // Triggers the system prompt the first time; afterwards macOS only allows
        // granting it in System Settings, and Mira must be relaunched.
        CGRequestScreenCaptureAccess()
        let alert = NSAlert()
        alert.messageText = "Mira needs Screen Recording permission"
        alert.informativeText = """
        To mirror your screen, allow Mira in System Settings -> Privacy & Security -> Screen & System Audio Recording, then quit and reopen Mira.

        You can try a display without it: turn on 'Test pattern' in Mira's settings.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    private func checkForUpdates() {
        UpdateChecker.check { [weak self] release in
            DispatchQueue.main.async {
                if let release { Log.info("Mira", "Update available: \(release.version)") }
                self?.statusBar.setUpdate(release)
            }
        }
    }

    private func statusChanged(_ status: MiraController.Status) {
        statusBar.setStatus(status)
        if case .failed = status { statusBar.showPopover() }
        if case .streaming(let device, _) = status { Settings.lastDevice = device }
        if case .streaming = status {
            if statsTimer == nil {
                statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    let s = self.controller.currentStats
                    if s.isStreaming { self.statusBar.setStats(s) }
                }
            }
        } else {
            statsTimer?.invalidate()
            statsTimer = nil
            statusBar.setPrivacy(false)
        }
    }
}
