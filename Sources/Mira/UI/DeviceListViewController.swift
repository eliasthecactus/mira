import AppKit
import Foundation
import ServiceManagement

final class DeviceListViewController: NSViewController {

    var onMirrorRequested: ((MiracastDevice) -> Void)?
    var onStopRequested: (() -> Void)?

    private var devices: [MiracastDevice] = []
    private var status: MiraController.Status = .idle
    private var displays: [DisplayInfo] = []
    private var update: UpdateChecker.Release?
    private let startedAt = Date()
    private var hintTimer: Timer?

    private let titleLabel = NSTextField(labelWithString: "Mira")
    private let versionLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let stopButton = NSButton(title: "Stop Mirroring", target: nil, action: nil)
    private let ipField = NSTextField()
    private let ipButton = NSButton(title: "Connect", target: nil, action: nil)
    private let displayPopup = NSPopUpButton()
    private let resolutionPopup = NSPopUpButton()
    private let bitratePopup = NSPopUpButton()
    private let audioCheckbox = NSButton(checkboxWithTitle: "Audio", target: nil, action: nil)
    private let testPatternCheckbox = NSButton(checkboxWithTitle: "Test pattern", target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: "Open at login", target: nil, action: nil)
    private let updateButton = NSButton(title: "", target: nil, action: nil)

    private static let width: CGFloat = 320
    private static let bitrates = [3, 4, 6, 8, 12, 16]
    private static let resolutions: [StreamPreferences.ResolutionChoice] = [.auto, .p1080, .p720]

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 460))
        let inner = Self.width - 24

        titleLabel.font = .boldSystemFont(ofSize: 14)
        versionLabel.font = .systemFont(ofSize: 10)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.stringValue = "v\(AppInfo.version)"
        let titleRow = NSStackView(views: [titleLabel, NSView(), versionLabel])

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.preferredMaxLayoutWidth = inner

        let col = NSTableColumn(identifier: .init("device"))
        col.width = inner - 4
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 40
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        stopButton.bezelStyle = .rounded
        stopButton.isHidden = true
        stopButton.target = self
        stopButton.action = #selector(stopTapped)

        // Manual IP entry — for networks where mDNS discovery is filtered.
        ipField.placeholderString = "Adapter IP address (if not listed)"
        ipField.stringValue = Settings.lastManualIP
        ipField.font = .systemFont(ofSize: 11)
        ipField.target = self
        ipField.action = #selector(ipConnectTapped)
        ipButton.bezelStyle = .rounded
        ipButton.controlSize = .small
        ipButton.target = self
        ipButton.action = #selector(ipConnectTapped)
        let ipRow = NSStackView(views: [ipField, ipButton])
        ipRow.spacing = 6

        // Settings (apply to the next connection)
        for popup in [displayPopup, resolutionPopup, bitratePopup] {
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: 11)
            popup.target = self
            popup.action = #selector(settingsChanged)
        }
        displayPopup.toolTip = "Display to mirror"
        resolutionPopup.addItems(withTitles: ["Auto", "1080p", "720p"])
        resolutionPopup.selectItem(at: Self.resolutions.firstIndex(of: Settings.resolution) ?? 0)
        resolutionPopup.toolTip = "Resolution (Auto = best the display supports)"
        bitratePopup.addItems(withTitles: Self.bitrates.map { "\($0) Mbit/s" })
        bitratePopup.selectItem(at: Self.bitrates.firstIndex(of: Settings.bitrateMbps) ?? 2)
        bitratePopup.toolTip = "Video bitrate — lower it if the picture stutters"
        for box in [audioCheckbox, testPatternCheckbox, loginCheckbox] {
            box.controlSize = .small
            box.font = .systemFont(ofSize: 11)
            box.target = self
        }
        audioCheckbox.state = Settings.audio ? .on : .off
        audioCheckbox.action = #selector(settingsChanged)
        testPatternCheckbox.state = Settings.testPattern ? .on : .off
        testPatternCheckbox.action = #selector(settingsChanged)
        testPatternCheckbox.toolTip = "Send colour bars and a beep instead of the screen — for testing a new display"
        loginCheckbox.action = #selector(loginToggled)
        loginCheckbox.isHidden = !AppInfo.isAppBundle
        refreshLoginCheckbox()

        let settingsTitle = NSTextField(labelWithString: "Settings — apply to the next connection")
        settingsTitle.font = .systemFont(ofSize: 10)
        settingsTitle.textColor = .tertiaryLabelColor
        let row2 = NSStackView(views: [resolutionPopup, bitratePopup, audioCheckbox])
        row2.spacing = 6
        let row3 = NSStackView(views: [testPatternCheckbox, loginCheckbox])
        row3.spacing = 12

        updateButton.bezelStyle = .inline
        updateButton.controlSize = .small
        updateButton.isHidden = true
        updateButton.target = self
        updateButton.action = #selector(openUpdate)

        let logButton = Self.linkButton("Log", self, #selector(openLog))
        let helpButton = Self.linkButton("Help", self, #selector(openHelp))
        let quitButton = Self.linkButton("Quit", self, #selector(quit))
        let footer = NSStackView(views: [logButton, helpButton, NSView(), quitButton])

        let stack = NSStackView(views: [titleRow, statusLabel, scrollView, stopButton, ipRow,
                                        settingsTitle, displayPopup, row2, row3, updateButton, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: ipRow)
        stack.setCustomSpacing(4, after: settingsTitle)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: Self.width),
            titleRow.widthAnchor.constraint(equalToConstant: inner),
            scrollView.widthAnchor.constraint(equalToConstant: inner),
            scrollView.heightAnchor.constraint(equalToConstant: 140),
            ipRow.widthAnchor.constraint(equalToConstant: inner),
            displayPopup.widthAnchor.constraint(equalToConstant: inner),
            footer.widthAnchor.constraint(equalToConstant: inner),
            statusLabel.widthAnchor.constraint(equalToConstant: inner),
        ])
        refreshStatusText()
        hintTimer = Timer.scheduledTimer(withTimeInterval: 16, repeats: false) { [weak self] _ in
            guard let self, case .idle = self.status else { return }
            self.refreshStatusText()
            self.resizeToFit()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshDisplays()
        refreshLoginCheckbox()
        refreshStatusText()
        resizeToFit()
    }

    // The popover takes its size from preferredContentSize; derive it from the
    // stack's fitting size so rows that hide/show and wrapping text never leave gaps.
    private func resizeToFit() {
        guard isViewLoaded else { return }
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: Self.width, height: view.fittingSize.height)
    }

    private static func linkButton(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .inline
        b.controlSize = .small
        return b
    }

    // MARK: - Updates

    func updateDevices(_ newDevices: [MiracastDevice]) {
        devices = newDevices
        tableView.reloadData()
        if case .idle = status { refreshStatusText() }
        resizeToFit()
    }

    func setStatus(_ s: MiraController.Status) {
        status = s
        switch s {
        case .streaming, .connecting: stopButton.isHidden = false
        default: stopButton.isHidden = true
        }
        if case .connecting = s { stopButton.title = "Cancel" } else { stopButton.title = "Stop Mirroring" }
        refreshStatusText()
        tableView.reloadData()
        resizeToFit()
    }

    func setStats(_ stats: MiraStats) {
        guard let d = stats.device else { return }
        statusLabel.stringValue = "Mirroring to \(d.name) · \(stats.resolution) · \(Int(stats.fps.rounded())) fps · \(String(format: "%.1f", Double(stats.kbps) / 1000)) Mbit/s"
    }

    func setUpdate(_ release: UpdateChecker.Release?) {
        update = release
        updateButton.isHidden = release == nil
        if let release { updateButton.title = "⬆︎ Mira \(release.version) is available" }
        resizeToFit()
    }

    private func refreshStatusText() {
        switch status {
        case .idle:
            if !devices.isEmpty {
                statusLabel.stringValue = "\(devices.count) display\(devices.count == 1 ? "" : "s") found"
            } else if Date().timeIntervalSince(startedAt) < 15 {
                statusLabel.stringValue = "Looking for Miracast displays… A Microsoft 4K Wireless Display Adapter shows up here once it's on your Wi-Fi."
            } else {
                // macOS gives no error when Local Network access is denied — discovery is just empty.
                statusLabel.stringValue = "No displays found yet. Check that Mira is allowed under System Settings → Privacy & Security → Local Network, and that the adapter is on this Wi-Fi. You can also enter its IP address below."
            }
        case .connecting(let d):
            statusLabel.stringValue = "Connecting to \(d.name)…"
        case .streaming(let d, let res):
            statusLabel.stringValue = "Mirroring to \(d.name) · \(res)"
        case .failed(let why):
            statusLabel.stringValue = "⚠️ \(why)"
        }
    }

    private func refreshDisplays() {
        displays = DisplayInfo.all()
        displayPopup.removeAllItems()
        displayPopup.addItems(withTitles: displays.map { "Mirror: \($0.label)" })
        let selected = Settings.displayID.flatMap { id in displays.firstIndex { $0.id == id } } ?? 0
        if !displays.isEmpty { displayPopup.selectItem(at: selected) }
        displayPopup.isHidden = displays.count < 2
    }

    private func refreshLoginCheckbox() {
        guard AppInfo.isAppBundle else { return }
        loginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: - Actions

    @objc private func stopTapped() { onStopRequested?() }

    @objc private func mirrorTapped(_ sender: NSButton) {
        guard devices.indices.contains(sender.tag) else { return }
        onMirrorRequested?(devices[sender.tag])
    }

    @objc private func ipConnectTapped() {
        let ip = ipField.stringValue.trimmingCharacters(in: .whitespaces)
        guard CLI.isIPAddress(ip) else {
            statusLabel.stringValue = "⚠️ “\(ip)” is not an IP address"
            return
        }
        Settings.lastManualIP = ip
        onMirrorRequested?(MiracastDevice(name: ip, ipAddress: ip))
    }

    @objc private func settingsChanged() {
        Settings.resolution = Self.resolutions[max(0, resolutionPopup.indexOfSelectedItem)]
        Settings.bitrateMbps = Self.bitrates[max(0, bitratePopup.indexOfSelectedItem)]
        Settings.audio = audioCheckbox.state == .on
        Settings.testPattern = testPatternCheckbox.state == .on
        let i = displayPopup.indexOfSelectedItem
        Settings.displayID = displays.indices.contains(i) && !displays[i].isMain ? displays[i].id : nil
    }

    @objc private func loginToggled() {
        do {
            if loginCheckbox.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            statusLabel.stringValue = "⚠️ Could not change login item: \(error.localizedDescription). Move Mira to /Applications first."
        }
        refreshLoginCheckbox()
    }

    @objc private func openUpdate() {
        NSWorkspace.shared.open(update?.url ?? AppInfo.releasesURL)
    }

    @objc private func openLog() { NSWorkspace.shared.open(Log.logFileURL) }

    @objc private func openHelp() {
        NSWorkspace.shared.open(URL(string: "https://github.com/\(AppInfo.repository)#readme")!)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - Table

extension DeviceListViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { devices.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let device = devices[row]
        var isActive = false
        switch status {
        case .streaming(let d, _), .connecting(let d): isActive = d.ipAddress == device.ipAddress
        default: break
        }
        let w = tableView.bounds.width > 0 ? tableView.bounds.width : Self.width - 24
        let cell = NSView(frame: NSRect(x: 0, y: 0, width: w, height: 40))

        let nameLabel = NSTextField(labelWithString: device.name)
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.frame = NSRect(x: 4, y: 20, width: w - 90, height: 16)
        nameLabel.autoresizingMask = [.width]

        let ipLabel = NSTextField(labelWithString: device.ipAddress)
        ipLabel.font = .systemFont(ofSize: 10)
        ipLabel.textColor = .secondaryLabelColor
        ipLabel.frame = NSRect(x: 4, y: 4, width: w - 90, height: 14)
        ipLabel.autoresizingMask = [.width]

        let btn = NSButton(frame: NSRect(x: w - 80, y: 8, width: 76, height: 24))
        btn.autoresizingMask = [.minXMargin]
        btn.title = isActive ? "Active" : "Mirror"
        btn.bezelStyle = .rounded
        btn.controlSize = .small
        btn.isEnabled = !isActive
        btn.tag = row
        btn.target = self
        btn.action = #selector(mirrorTapped)

        cell.addSubview(nameLabel)
        cell.addSubview(ipLabel)
        cell.addSubview(btn)
        return cell
    }
}
