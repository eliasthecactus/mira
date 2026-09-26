import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusBar: StatusBarController!
    private let controller = MiraController()
    private var discoveredDevices: [MiracastDevice] = []
    private var statsTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController()

        statusBar.onMirrorRequested = { [weak self] device in
            self?.startMirroring(to: device)
        }
        statusBar.onStopRequested = { [weak self] in
            self?.stopMirroring()
        }

        // Wire controller device discovery into UI
        controller.onDeviceDiscovered = { [weak self] devices in
            guard let self else { return }
            self.discoveredDevices = devices
            self.statusBar.updateDevices(devices)
        }

        Task {
            await controller.run()
        }
    }

    private func startMirroring(to device: MiracastDevice) {
        Task {
            await controller.connectTo(device: device)
        }
        startStatsTimer()
    }

    private func stopMirroring() {
        controller.stop()
        stopStatsTimer()
        statusBar.setStreamingState(device: nil, fps: 0, kbps: 0)
    }

    // MARK: - Stats

    private func startStatsTimer() {
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let stats = self.controller.currentStats
            if stats.isStreaming {
                self.statusBar.setStreamingState(device: stats.device, fps: stats.fps, kbps: stats.kbps)
            }
        }
    }

    private func stopStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = nil
    }
}
