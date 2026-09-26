import AppKit
import Foundation

// Menu bar status item + popover UI.
final class StatusBarController: NSObject {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var listVC: DeviceListViewController!
    private var eventMonitor: Any?

    override init() {
        super.init()
        listVC = DeviceListViewController()
        popover.contentViewController = listVC
        popover.behavior = .transient
        popover.animates = true

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display.and.arrow.down", accessibilityDescription: "Mira")
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Close when clicking outside
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

    // Called by MiraController to update device list and streaming state
    func updateDevices(_ devices: [MiracastDevice]) {
        DispatchQueue.main.async { self.listVC.updateDevices(devices) }
    }

    func setStreamingState(device: MiracastDevice?, fps: Double, kbps: Int) {
        DispatchQueue.main.async {
            self.listVC.setStreamingState(device: device, fps: fps, kbps: kbps)
            if let button = self.statusItem.button {
                button.image = device != nil
                    ? NSImage(systemSymbolName: "display.and.arrow.down.fill", accessibilityDescription: "Mira active")
                    : NSImage(systemSymbolName: "display.and.arrow.down", accessibilityDescription: "Mira")
            }
        }
    }

    var onMirrorRequested: ((MiracastDevice) -> Void)? {
        get { listVC.onMirrorRequested }
        set { listVC.onMirrorRequested = newValue }
    }

    var onStopRequested: (() -> Void)? {
        get { listVC.onStopRequested }
        set { listVC.onStopRequested = newValue }
    }
}
