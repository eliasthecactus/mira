import AppKit
import Foundation

final class DeviceListViewController: NSViewController {

    var onMirrorRequested: ((MiracastDevice) -> Void)?
    var onStopRequested: (() -> Void)?

    private var devices: [MiracastDevice] = []
    private var streamingDevice: MiracastDevice?
    private var streamFPS: Double = 0
    private var streamKbps: Int = 0

    // MARK: - View

    private let stackView = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "Mira")
    private let statusLabel = NSTextField(labelWithString: "Scanning…")
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let stopButton = NSButton(title: "Stop Mirroring", target: nil, action: nil)

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 300))
        view.wantsLayer = true
        if let layer = view.layer {
            layer.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }

        // Title
        titleLabel.font = .boldSystemFont(ofSize: 14)
        titleLabel.textColor = .labelColor

        // Status
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        // Table
        let col = NSTableColumn(identifier: .init("device"))
        col.title = ""
        col.width = 260
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 44
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.frame = NSRect(x: 0, y: 0, width: 280, height: 220)

        // Stop button
        stopButton.bezelStyle = .rounded
        stopButton.isHidden = true
        stopButton.target = self
        stopButton.action = #selector(stopTapped)

        // Layout
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 4
        stackView.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(statusLabel)
        stackView.addArrangedSubview(scrollView)
        stackView.addArrangedSubview(stopButton)

        view.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: view.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.widthAnchor.constraint(equalToConstant: 256),
            scrollView.heightAnchor.constraint(equalToConstant: 200),
        ])
    }

    // MARK: - Update

    func updateDevices(_ newDevices: [MiracastDevice]) {
        devices = newDevices
        tableView.reloadData()
        statusLabel.stringValue = devices.isEmpty ? "Scanning for Miracast devices…" : "\(devices.count) device\(devices.count == 1 ? "" : "s") found"
    }

    func setStreamingState(device: MiracastDevice?, fps: Double, kbps: Int) {
        streamingDevice = device
        streamFPS = fps
        streamKbps = kbps
        stopButton.isHidden = (device == nil)

        if let d = device {
            statusLabel.stringValue = "Mirroring to \(d.name) · \(Int(fps))fps · \(kbps)kbps"
        } else {
            statusLabel.stringValue = devices.isEmpty ? "Scanning…" : "\(devices.count) device(s) found"
        }
        tableView.reloadData()
    }

    @objc private func stopTapped() {
        onStopRequested?()
    }

    @objc private func mirrorTapped(_ sender: NSButton) {
        let row = sender.tag
        guard devices.indices.contains(row) else { return }
        onMirrorRequested?(devices[row])
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension DeviceListViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { devices.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let device = devices[row]
        let isStreaming = (streamingDevice?.ipAddress == device.ipAddress)

        let cell = NSView(frame: NSRect(x: 0, y: 0, width: 256, height: 44))

        // Device name label
        let nameLabel = NSTextField(labelWithString: device.name)
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = .labelColor
        nameLabel.frame = NSRect(x: 8, y: 22, width: 160, height: 16)

        // IP label
        let ipLabel = NSTextField(labelWithString: "\(device.ipAddress):\(device.port)")
        ipLabel.font = .systemFont(ofSize: 10)
        ipLabel.textColor = .secondaryLabelColor
        ipLabel.frame = NSRect(x: 8, y: 6, width: 160, height: 14)

        // Mirror button
        let btn = NSButton(frame: NSRect(x: 178, y: 10, width: 70, height: 24))
        btn.title = isStreaming ? "Live" : "Mirror"
        btn.bezelStyle = .rounded
        btn.font = .systemFont(ofSize: 11)
        btn.isEnabled = !isStreaming
        btn.tag = row
        btn.target = self
        btn.action = #selector(mirrorTapped)

        cell.addSubview(nameLabel)
        cell.addSubview(ipLabel)
        cell.addSubview(btn)
        return cell
    }
}
