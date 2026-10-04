import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusBar: StatusBarController!
    private let controller = MiraController(options: Settings.options())
    private var statsTimer: Timer?
    private var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Mira", "Menu bar app \(AppInfo.version) (\(AppInfo.build)) started; log file \(Log.logFileURL.path)")
        statusBar = StatusBarController()

        statusBar.onMirrorRequested = { [weak self] device in self?.startMirroring(to: device) }
        statusBar.onStopRequested = { [weak self] in self?.controller.stop() }

        controller.onDevicesChanged = { [weak self] devices in
            DispatchQueue.main.async { self?.statusBar.updateDevices(devices) }
        }
        controller.onStatusChanged = { [weak self] status in
            DispatchQueue.main.async { self?.statusChanged(status) }
        }
        controller.startDiscovery()

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

    private func requestScreenRecordingPermission() {
        // Triggers the system prompt the first time; afterwards macOS only allows
        // granting it in System Settings, and Mira must be relaunched.
        CGRequestScreenCaptureAccess()
        let alert = NSAlert()
        alert.messageText = "Mira needs Screen Recording permission"
        alert.informativeText = """
        To mirror your screen, allow Mira in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen Mira.

        You can try a display without it: turn on “Test pattern” in Mira's settings.
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
        }
    }
}
