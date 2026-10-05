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

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Mira", "Menu bar app \(AppInfo.version) (\(AppInfo.build)) started; log file \(Log.logFileURL.path)")
        MacAudioMuter.restoreAfterCrash()
        statusBar = StatusBarController()

        statusBar.onMirrorRequested = { [weak self] device in self?.startMirroring(to: device) }
        statusBar.onStopRequested = { [weak self] in self?.controller.stop() }

        controller.onDevicesChanged = { [weak self] devices in
            DispatchQueue.main.async {
                guard let self else { return }
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
