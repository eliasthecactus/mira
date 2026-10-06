import AppKit
import Foundation

// Menu bar status item + popover UI.
final class StatusBarController: NSObject {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let listVC = DeviceListViewController()
    private var eventMonitor: Any?

    var onMirrorRequested: ((MiracastDevice) -> Void)? {
        get { listVC.onMirrorRequested }
        set { listVC.onMirrorRequested = newValue }
    }

    var onStopRequested: (() -> Void)? {
        get { listVC.onStopRequested }
        set { listVC.onStopRequested = newValue }
    }

    var onTargetChange: ((CaptureTarget) -> Void)? {
        get { listVC.onTargetChange }
        set { listVC.onTargetChange = newValue }
    }

    var onPairRequested: (() -> Void)? {
        get { listVC.onPairRequested }
        set { listVC.onPairRequested = newValue }
    }

    func showMessage(_ text: String) {
        listVC.showMessage(text)
    }

    var onPrivacyToggle: (() -> Void)? {
        get { listVC.onPrivacyToggle }
        set { listVC.onPrivacyToggle = newValue }
    }

    private var streaming = false
    private var privacyOn = false
    private var updateAvailable = false

    var onPopoverOpened: (() -> Void)?
    var onCheckForUpdates: (() -> Void)? {
        get { listVC.onCheckForUpdates }
        set { listVC.onCheckForUpdates = newValue }
    }

    func setPrivacy(_ on: Bool) {
        privacyOn = on
        listVC.setPrivacy(on)
        updateIcon()
    }

    private func updateIcon() {
        let symbol = privacyOn ? "eye.slash" : (streaming ? "rectangle.fill.on.rectangle.fill" : "rectangle.on.rectangle")
        let description = privacyOn ? "Mira (paused)" : streaming ? "Mira (mirroring)" : updateAvailable ? "Mira (update available)" : "Mira"
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: description) else { return }
        statusItem.button?.image = updateAvailable ? Self.withDot(base) : base
    }

    override init() {
        super.init()
        popover.contentViewController = listVC
        popover.behavior = .transient
        popover.animates = true

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Mira")
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    @objc private func togglePopover() {
        popover.isShown ? closePopover() : openPopover()
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        onPopoverOpened?()
        NSApp.activate(ignoringOtherApps: true)
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    func updateDevices(_ devices: [MiracastDevice]) {
        listVC.updateDevices(devices)
    }

    func setStatus(_ status: MiraController.Status) {
        listVC.setStatus(status)
        if case .streaming = status { streaming = true } else { streaming = false; privacyOn = false }
        updateIcon()
    }

    func setStats(_ stats: MiraStats) {
        listVC.setStats(stats)
    }

    func setUpdate(_ release: UpdateChecker.Release?) {
        listVC.setUpdate(release)
        updateAvailable = release != nil
        updateIcon()
    }

    func showUpdateMessage(_ text: String) {
        listVC.showMessage(text)
    }

    // The menu bar symbol with a small dot in the corner: "update available".
    static func withDot(_ base: NSImage) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            // Drawn when shown, in the menu bar's appearance: tint the symbol like the
            // menu bar text (light or dark), then add the dot.
            let symbolRect = NSRect(x: 0, y: 1, width: 16, height: 16)
            base.draw(in: symbolRect)
            NSColor.labelColor.set()
            symbolRect.fill(using: .sourceAtop)
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 7, y: rect.maxY - 7, width: 7, height: 7)).fill()
            return true
        }
        image.isTemplate = false      // keep the dot orange; the symbol follows the menu bar style
        return image
    }

    func showPopover() {
        if !popover.isShown { openPopover() }
    }
}
