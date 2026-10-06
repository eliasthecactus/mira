import AppKit
import AVFoundation
import Vision

// Reads a QR code (e.g. the pairing code on a hotel TV) with the Mac's camera or an
// iPhone used as a Continuity Camera. Calls `onResult` once with the decoded text, or
// with nil if the user closes the window.
final class QRScannerWindowController: NSWindowController, NSWindowDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {

    var onResult: ((String?) -> Void)?

    private let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "mira.qr")
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let cameraPopup = NSPopUpButton()
    private let hint = NSTextField(labelWithString: "Point the camera at the QR code on the TV")
    private let settingsButton = NSButton(title: "Open Camera Settings", target: nil, action: nil)
    private var cameras: [AVCaptureDevice] = []
    private var delivered = false
    private var lastScan = Date.distantPast

    init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Scan the TV's QR code"
        super.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    static func availableCameras() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types += [.external, .continuityCamera]
        } else {
            types += [.externalUnknown]
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let preview = NSView()
        preview.wantsLayer = true
        preview.layer = CALayer()
        preview.layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspect
        previewLayer.frame = preview.bounds
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        preview.layer?.addSublayer(previewLayer)

        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        cameraPopup.target = self
        cameraPopup.action = #selector(cameraChosen)
        cameraPopup.controlSize = .small
        let note = NSTextField(wrappingLabelWithString: "Tip: an iPhone near the Mac works as a camera (Continuity Camera) and reads codes across a room much better.")
        note.font = .systemFont(ofSize: 10)
        note.textColor = .tertiaryLabelColor

        settingsButton.target = self
        settingsButton.action = #selector(openCameraSettings)
        settingsButton.controlSize = .small
        settingsButton.bezelStyle = .rounded
        settingsButton.isHidden = true
        let bar = NSStackView(views: [hint, NSView(), settingsButton, cameraPopup])
        let stack = NSStackView(views: [preview, bar, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            bar.widthAnchor.constraint(equalTo: preview.widthAnchor),
            note.widthAnchor.constraint(equalTo: preview.widthAnchor),
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
    }

    func start() {
        showWindow(nil)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setUpCameras()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { granted ? self.setUpCameras() : self.permissionDenied() }
            }
        default:
            permissionDenied()
        }
    }

    private func permissionDenied() {
        hint.stringValue = "Camera access is off for Mira. Turn it on, then try again (or type the code instead)."
        hint.textColor = .systemOrange
        settingsButton.isHidden = false
        cameraPopup.isHidden = true
        Log.warn("Cast", "Camera access denied (status \(AVCaptureDevice.authorizationStatus(for: .video).rawValue))")
    }

    @objc private func openCameraSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }

    private func setUpCameras() {
        cameras = Self.availableCameras()
        cameraPopup.removeAllItems()
        guard !cameras.isEmpty else {
            hint.stringValue = "No camera found. Type the code from the TV instead."
            return
        }
        cameraPopup.addItems(withTitles: cameras.map(\.localizedName))
        // Prefer an iPhone (Continuity Camera): better optics for a code across the room.
        let preferred = cameras.firstIndex(where: Self.isContinuityCamera) ?? 0
        cameraPopup.selectItem(at: preferred)
        use(cameras[preferred])
    }

    private static func isContinuityCamera(_ cam: AVCaptureDevice) -> Bool {
        if #available(macOS 14.0, *) {
            return cam.deviceType == AVCaptureDevice.DeviceType.continuityCamera
        }
        return false
    }

    @objc private func cameraChosen() {
        let i = cameraPopup.indexOfSelectedItem
        if cameras.indices.contains(i) { use(cameras[i]) }
    }

    private func use(_ camera: AVCaptureDevice) {
        videoQueue.async { [self] in
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            if let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) {
                session.addInput(input)
            }
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // A few scans a second are plenty.
        guard !delivered, Date().timeIntervalSince(lastScan) > 0.2,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastScan = Date()
        guard let text = Self.detectQR(VNImageRequestHandler(cvPixelBuffer: pixels, options: [:])) else { return }
        delivered = true
        Log.info("Cast", "QR code read")
        DispatchQueue.main.async { self.finish(text) }
    }

    // The text of the first QR code in the image, if any.
    static func detectQR(_ handler: VNImageRequestHandler) -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? handler.perform([request])
        return request.results?.compactMap(\.payloadStringValue).first { !$0.isEmpty }
    }

    private func finish(_ text: String?) {
        videoQueue.async { self.session.stopRunning() }
        let callback = onResult
        onResult = nil
        window?.close()
        callback?(text)
    }

    func windowWillClose(_ notification: Notification) {
        if onResult != nil { finish(nil) }
    }
}
