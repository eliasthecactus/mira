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
        let active: Bool
        if case .streaming = status { active = true } else { active = false }
        statusItem.button?.image = NSImage(systemSymbolName: active ? "rectangle.fill.on.rectangle.fill" : "rectangle.on.rectangle",
                                           accessibilityDescription: active ? "Mira (mirroring)" : "Mira")
    }

    func setStats(_ stats: MiraStats) {
        listVC.setStats(stats)
    }

    func setUpdate(_ release: UpdateChecker.Release?) {
        listVC.setUpdate(release)
    }

    func showPopover() {
        if !popover.isShown { openPopover() }
    }
}
