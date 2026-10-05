import AppKit
import Foundation
import ServiceManagement

final class DeviceListViewController: NSViewController {

    var onMirrorRequested: ((MiracastDevice) -> Void)?
    var onStopRequested: (() -> Void)?
    var onPrivacyToggle: (() -> Void)?
    var onTargetChange: ((CaptureTarget) -> Void)?

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
    private let privacyButton = NSButton(title: "Pause Screen", target: nil, action: nil)
    private let lowLatencyCheckbox = NSButton(checkboxWithTitle: "Low latency", target: nil, action: nil)
    private let fpsCheckbox = NSButton(checkboxWithTitle: "60 fps", target: nil, action: nil)
    private let remoteInputCheckbox = NSButton(checkboxWithTitle: "Allow TV input", target: nil, action: nil)
    private let codecPopup = NSPopUpButton()
    private let ipField = NSTextField()
    private let ipButton = NSButton(title: "Connect", target: nil, action: nil)
    private let displayPopup = NSPopUpButton()
    private let targetPopup = NSPopUpButton()
    private var currentTarget: CaptureTarget = Settings.shareTarget
    private let resolutionPopup = NSPopUpButton()
    private let bitratePopup = NSPopUpButton()
    private let audioCheckbox = NSButton(checkboxWithTitle: "Audio", target: nil, action: nil)
    private let testPatternCheckbox = NSButton(checkboxWithTitle: "Test pattern", target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: "Open at login", target: nil, action: nil)
    private let modePopup = NSPopUpButton()
    private let securityPopup = NSPopUpButton()
    private let muteCheckbox = NSButton(checkboxWithTitle: "Sound only on TV", target: nil, action: nil)
    private let reconnectCheckbox = NSButton(checkboxWithTitle: "Reconnect on launch", target: nil, action: nil)
    private let updateButton = NSButton(title: "", target: nil, action: nil)
    private let controlRow = NSStackView()

    private static let width: CGFloat = 340
    private static let bitrates = [0, 3, 4, 6, 8, 12, 16]       // 0 = Auto
    private static let securities: [MiraController.SecurityChoice] = [.auto, .off, .encrypted, .pin]
    private static let resolutions: [StreamPreferences.ResolutionChoice] = [.auto, .p2160, .p1080, .p720]
    private static let codecs: [WFDNegotiatedFormat.CodecChoice] = [.auto, .h264, .hevc]

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
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        privacyButton.bezelStyle = .rounded
        privacyButton.target = self
        privacyButton.action = #selector(privacyTapped)
        privacyButton.toolTip = "Freeze what the TV shows and mute it, e.g. while typing a password (\(GlobalHotKey.togglePrivacy.display))"
        controlRow.addArrangedSubview(stopButton)
        controlRow.addArrangedSubview(privacyButton)
        controlRow.spacing = 8
        controlRow.isHidden = true

        // Manual IP entry - for networks where mDNS discovery is filtered.
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
        for popup in [displayPopup, resolutionPopup, bitratePopup, modePopup, securityPopup, codecPopup] {
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: 11)
            popup.target = self
            popup.action = #selector(settingsChanged)
        }
        displayPopup.toolTip = "Display to mirror"
        targetPopup.controlSize = .small
        targetPopup.font = .systemFont(ofSize: 11)
        targetPopup.target = self
        targetPopup.action = #selector(targetChosen)
        targetPopup.toolTip = "Share the whole screen, one app (other windows stay black) or one window - switches live"
        targetPopup.addItem(withTitle: "Share: Entire screen")
        resolutionPopup.addItems(withTitles: ["Best", "4K", "1080p", "720p"])
        resolutionPopup.selectItem(at: Self.resolutions.firstIndex(of: Settings.resolution) ?? 0)
        resolutionPopup.toolTip = "Best = up to 1080p. 4K needs a display that supports it and fast Wi-Fi (~30 Mbit/s); falls back to 1080p"
        bitratePopup.addItems(withTitles: Self.bitrates.map { $0 == 0 ? "Auto quality" : "\($0) Mbit/s" })
        bitratePopup.selectItem(at: Self.bitrates.firstIndex(of: Settings.bitrateMbps) ?? 0)
        bitratePopup.toolTip = "Auto adapts the bitrate to your Wi-Fi (up to \(Settings.autoBitrateMax) Mbit/s); a number keeps it fixed"
        modePopup.addItems(withTitles: ["Mirror", "Extend"])
        modePopup.selectItem(at: Settings.extendDisplay ? 1 : 0)
        modePopup.toolTip = "Mirror shows your screen on the TV; Extend makes the TV a second screen"
        securityPopup.addItems(withTitles: ["Security: Auto", "Security: Off", "Security: Encrypted", "Security: PIN"])
        securityPopup.selectItem(at: Self.securities.firstIndex(of: Settings.security) ?? 0)
        securityPopup.toolTip = "Auto connects normally and asks for a PIN only if the display insists"
        lowLatencyCheckbox.state = Settings.lowLatency ? .on : .off
        lowLatencyCheckbox.action = #selector(settingsChanged)
        lowLatencyCheckbox.toolTip = "Halves the delay (about 100 ms instead of 200 ms) - prefers LPCM audio and a smaller buffer; may stutter on weak Wi-Fi"
        codecPopup.addItems(withTitles: ["Codec: Auto", "Codec: H.264", "Codec: HEVC"])
        codecPopup.selectItem(at: Self.codecs.firstIndex(of: Settings.codec) ?? 0)
        codecPopup.toolTip = "Auto uses H.264 up to 1080p and HEVC (H.265) for 4K when the display supports it. Falls back to H.264 if the display has no HEVC"
        remoteInputCheckbox.state = Settings.remoteInput ? .on : .off
        remoteInputCheckbox.action = #selector(settingsChanged)
        remoteInputCheckbox.toolTip = "Let a keyboard, mouse or touch screen at the TV control this Mac (UIBC, if the display supports it). Needs the Accessibility permission. Anyone at the TV can then use your Mac"
        fpsCheckbox.state = Settings.fps == 60 ? .on : .off
        fpsCheckbox.action = #selector(settingsChanged)
        fpsCheckbox.toolTip = "Smoother motion if the display supports 60 fps (uses more bandwidth)"
        for box in [audioCheckbox, testPatternCheckbox, loginCheckbox, muteCheckbox, reconnectCheckbox, lowLatencyCheckbox, fpsCheckbox, remoteInputCheckbox] {
            box.controlSize = .small
            box.font = .systemFont(ofSize: 11)
            box.target = self
        }
        audioCheckbox.state = Settings.audio ? .on : .off
        audioCheckbox.action = #selector(settingsChanged)
        testPatternCheckbox.state = Settings.testPattern ? .on : .off
        testPatternCheckbox.action = #selector(settingsChanged)
        testPatternCheckbox.toolTip = "Send colour bars and a beep instead of the screen - for testing a new display"
        muteCheckbox.state = Settings.muteMac ? .on : .off
        muteCheckbox.action = #selector(settingsChanged)
        muteCheckbox.toolTip = "Mute the Mac's speakers while mirroring so you don't hear everything twice"
        reconnectCheckbox.state = Settings.reconnectOnLaunch ? .on : .off
        reconnectCheckbox.action = #selector(settingsChanged)
        reconnectCheckbox.toolTip = "Connect to the last display automatically when Mira starts"
        loginCheckbox.action = #selector(loginToggled)
        loginCheckbox.isHidden = !AppInfo.isAppBundle
        refreshLoginCheckbox()

        let settingsTitle = NSTextField(labelWithString: "Settings - apply to the next connection")
        settingsTitle.font = .systemFont(ofSize: 10)
        settingsTitle.textColor = .tertiaryLabelColor
        let row2 = NSStackView(views: [modePopup, resolutionPopup, bitratePopup])
        row2.spacing = 6
        let row3 = NSStackView(views: [audioCheckbox, muteCheckbox, securityPopup])
        row3.spacing = 8
        let row4 = NSStackView(views: [lowLatencyCheckbox, fpsCheckbox, testPatternCheckbox])
        row4.spacing = 10
        let row5 = NSStackView(views: [reconnectCheckbox, loginCheckbox])
        row5.spacing = 10
        let row6 = NSStackView(views: [codecPopup, remoteInputCheckbox])
        row6.spacing = 10

        updateButton.bezelStyle = .inline
        updateButton.controlSize = .small
        updateButton.isHidden = true
        updateButton.target = self
        updateButton.action = #selector(openUpdate)

        let logButton = Self.linkButton("Log", self, #selector(openLog))
        let diagButton = Self.linkButton("Diagnostics", self, #selector(exportDiagnostics))
        diagButton.toolTip = "Save a zip with the log and system/network info for a bug report"
        let helpButton = Self.linkButton("Help", self, #selector(openHelp))
        let quitButton = Self.linkButton("Quit", self, #selector(quit))
        let shortcut = NSTextField(labelWithString: "\(GlobalHotKey.toggleMirroring.display) start/stop - \(GlobalHotKey.togglePrivacy.display) pause")
        shortcut.font = .systemFont(ofSize: 10)
        shortcut.textColor = .tertiaryLabelColor
        let footer = NSStackView(views: [logButton, diagButton, helpButton, NSView(), quitButton])
        let shortcutRow = NSStackView(views: [shortcut])

        let stack = NSStackView(views: [titleRow, statusLabel, scrollView, controlRow, ipRow,
                                        settingsTitle, targetPopup, displayPopup, row2, row3, row4, row6, row5, updateButton, shortcutRow, footer])
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
            targetPopup.widthAnchor.constraint(equalToConstant: inner),
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
        refreshTargets()
        resizeToFit()
    }

    // Rebuilds the Share menu from the apps and windows on screen right now.
    private func refreshTargets() {
        Task { @MainActor in
            // Listing windows needs Screen Recording permission; apps don't.
            let items = try? await ShareableItems.load()
            let apps = items?.apps ?? ShareableItems.runningApps()
            Log.debug("UI", "Share menu: \(apps.count) apps, " + (items.map { "\($0.windows.count) windows" } ?? "windows need Screen Recording permission"))
            let menu = NSMenu()
            @MainActor func add(_ title: String, _ target: CaptureTarget?, indent: Bool = false) {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.representedObject = target.map { TargetBox($0) }
                item.isEnabled = target != nil
                item.indentationLevel = indent ? 1 : 0
                menu.addItem(item)
                if let target, target == currentTarget { targetPopup.select(item) }
            }
            add("Share: Entire screen", .screen)
            menu.addItem(.separator())
            add("Only one app (others stay black)", nil)
            for a in apps { add(a.name, .app(bundleID: a.bundleID, name: a.name), indent: true) }
            menu.addItem(.separator())
            add("Only one window", nil)
            if let items {
                for w in items.windows.prefix(30) {
                    let title = w.title.count > 40 ? String(w.title.prefix(40)) + "..." : w.title
                    add("\(w.appName) - \(title)", .window(id: w.id, title: w.title), indent: true)
                }
            } else {
                let ask = NSMenuItem(title: "Allow Screen Recording to list windows...",
                                     action: #selector(requestScreenRecording), keyEquivalent: "")
                ask.target = self
                ask.indentationLevel = 1
                menu.addItem(ask)
            }
            targetPopup.menu = menu
            if targetPopup.selectedItem?.representedObject == nil { targetPopup.selectItem(at: 0) }
            for item in menu.items where item.representedObject == nil && !item.isSeparatorItem && item.action == nil {
                item.isEnabled = false
            }
            targetPopup.autoenablesItems = false
        }
    }

    @objc private func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        statusLabel.stringValue = "Enable Mira under Screen & System Audio Recording, then quit and reopen Mira."
        resizeToFit()
        refreshTargets()
    }

    @objc private func targetChosen() {
        guard let box = targetPopup.selectedItem?.representedObject as? TargetBox else { return }
        currentTarget = box.target
        Settings.shareTarget = box.target
        onTargetChange?(box.target)
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
        case .streaming, .connecting: controlRow.isHidden = false
        default: controlRow.isHidden = true
        }
        if case .streaming = s { privacyButton.isHidden = false } else { privacyButton.isHidden = true; setPrivacy(false) }
        if case .connecting = s { stopButton.title = "Cancel" } else { stopButton.title = "Stop Mirroring" }
        refreshStatusText()
        tableView.reloadData()
        resizeToFit()
    }

    func setStats(_ stats: MiraStats) {
        guard let d = stats.device else { return }
        var extras: [String] = []
        if stats.extended { extras.append("second screen") }
        if stats.extendFailure != nil { extras.append("(second screen not available on this Mac)") }
        if stats.encrypted { extras.append("encrypted") }
        statusLabel.stringValue = "\(stats.extended ? "Extending" : "Mirroring") to \(d.name) - \(stats.resolution) - \(Int(stats.fps.rounded())) fps - \(String(format: "%.1f", Double(stats.kbps) / 1000)) of \(String(format: "%.1f", Double(stats.targetKbps) / 1000)) Mbit/s" + (extras.isEmpty ? "" : " - " + extras.joined(separator: " "))
    }

    func setUpdate(_ release: UpdateChecker.Release?) {
        update = release
        updateButton.isHidden = release == nil
        if let release { updateButton.title = "Update available: Mira \(release.version)" }
        resizeToFit()
    }

    private func refreshStatusText() {
        switch status {
        case .idle:
            if !devices.isEmpty {
                statusLabel.stringValue = "\(devices.count) display\(devices.count == 1 ? "" : "s") found"
            } else if Date().timeIntervalSince(startedAt) < 15 {
                statusLabel.stringValue = "Looking for Miracast displays... A Microsoft 4K Wireless Display Adapter shows up here once it's on your Wi-Fi."
            } else {
                // macOS gives no error when Local Network access is denied - discovery is just empty.
                statusLabel.stringValue = "No displays found yet. Check that Mira is allowed under System Settings -> Privacy & Security -> Local Network, and that the adapter is on this Wi-Fi. You can also enter its IP address below."
            }
        case .connecting(let d):
            statusLabel.stringValue = "Connecting to \(d.name)..."
        case .streaming(let d, let res):
            statusLabel.stringValue = "Mirroring to \(d.name) - \(res)"
        case .failed(let why):
            statusLabel.stringValue = "Warning: \(why)"
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

    @objc private func privacyTapped() { onPrivacyToggle?() }

    func setPrivacy(_ on: Bool) {
        privacyButton.title = on ? "Resume Screen" : "Pause Screen"
        privacyButton.contentTintColor = on ? .systemOrange : nil
    }

    @objc private func mirrorTapped(_ sender: NSButton) {
        guard devices.indices.contains(sender.tag) else { return }
        onMirrorRequested?(devices[sender.tag])
    }

    @objc private func ipConnectTapped() {
        let ip = ipField.stringValue.trimmingCharacters(in: .whitespaces)
        guard CLI.isIPAddress(ip) else {
            statusLabel.stringValue = "Warning: '\(ip)' is not an IP address"
            return
        }
        Settings.lastManualIP = ip
        statusLabel.stringValue = "Checking \(ip)..."
        DeviceProbe.kind(of: ip) { [weak self] kind in
            DispatchQueue.main.async {
                self?.onMirrorRequested?(MiracastDevice(name: ip, ipAddress: ip, kind: kind ?? .dlna))
            }
        }
    }

    @objc private func settingsChanged() {
        Settings.resolution = Self.resolutions[max(0, resolutionPopup.indexOfSelectedItem)]
        Settings.bitrateMbps = Self.bitrates[max(0, bitratePopup.indexOfSelectedItem)]
        Settings.extendDisplay = modePopup.indexOfSelectedItem == 1
        Settings.security = Self.securities[max(0, securityPopup.indexOfSelectedItem)]
        Settings.muteMac = muteCheckbox.state == .on
        Settings.reconnectOnLaunch = reconnectCheckbox.state == .on
        Settings.lowLatency = lowLatencyCheckbox.state == .on
        Settings.fps = fpsCheckbox.state == .on ? 60 : 30
        Settings.codec = Self.codecs[max(0, codecPopup.indexOfSelectedItem)]
        if remoteInputCheckbox.state == .on, !Settings.remoteInput, !InputInjector.hasPermission {
            InputInjector.requestPermission()    // shows the Accessibility prompt
        }
        Settings.remoteInput = remoteInputCheckbox.state == .on
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
            statusLabel.stringValue = "Warning: Could not change login item: \(error.localizedDescription). Move Mira to /Applications first."
        }
        refreshLoginCheckbox()
    }

    @objc private func openUpdate() {
        guard let update else { NSWorkspace.shared.open(AppInfo.releasesURL); return }
        guard Updater.currentApp != nil else { NSWorkspace.shared.open(update.url); return }
        let alert = NSAlert()
        alert.messageText = "Update to Mira \(update.version)?"
        alert.informativeText = "Mira downloads the release from GitHub, checks its checksum and signature, replaces itself and restarts. Mirroring stops for a moment."
        alert.addButton(withTitle: "Install and Restart")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: installUpdate()
        case .alertSecondButtonReturn: NSWorkspace.shared.open(update.url)
        default: break
        }
    }

    private func installUpdate() {
        updateButton.isEnabled = false
        Task { @MainActor in
            do {
                guard let release = try await Updater.latest() else { statusLabel.stringValue = "Already up to date"; return }
                let label = statusLabel
                let app = try await Updater.install(release) { msg in
                    DispatchQueue.main.async { label.stringValue = msg }
                }
                Updater.relaunch(app)
                NSApp.terminate(nil)
            } catch {
                statusLabel.stringValue = "Warning: \(error.localizedDescription)"
                updateButton.isEnabled = true
            }
            resizeToFit()
        }
    }

    @objc private func openLog() { NSWorkspace.shared.open(Log.logFileURL) }

    @objc private func exportDiagnostics() {
        statusLabel.stringValue = "Collecting diagnostics (takes a few seconds)..."
        Task { @MainActor in
            do {
                let url = try await Diagnostics.export()
                statusLabel.stringValue = "Saved \(url.lastPathComponent) to your Desktop"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                statusLabel.stringValue = "Warning: \(error.localizedDescription)"
            }
            resizeToFit()
        }
    }

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
        case .streaming(let d, _), .connecting(let d): isActive = d.ipAddress == device.ipAddress && d.kind == device.kind
        default: break
        }
        let w = tableView.bounds.width > 0 ? tableView.bounds.width : Self.width - 24
        let cell = NSView(frame: NSRect(x: 0, y: 0, width: w, height: 40))

        let nameLabel = NSTextField(labelWithString: device.name)
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.frame = NSRect(x: 4, y: 20, width: w - 90, height: 16)
        nameLabel.autoresizingMask = [.width]

        let detail = [device.kind.label, device.model, device.ipAddress].compactMap { $0 }.joined(separator: " - ")
        let ipLabel = NSTextField(labelWithString: detail)
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

// NSMenuItem.representedObject needs a class.
private final class TargetBox {
    let target: CaptureTarget
    init(_ target: CaptureTarget) { self.target = target }
}
