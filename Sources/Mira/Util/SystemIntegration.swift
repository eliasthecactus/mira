import Foundation
import AppKit
import CoreAudio
import Carbon.HIToolbox
import CVirtualDisplay

// MARK: - Keep the Mac awake while mirroring

// Without this the display (and with it screen capture) sleeps after the idle timeout
// in the middle of a presentation.
final class SleepGuard {
    private var activity: NSObjectProtocol?

    func begin(reason: String) {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
            reason: reason)
        Log.info("Mira", "Display sleep disabled while mirroring")
    }

    func end() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}

// MARK: - Sound only on the TV

// ScreenCaptureKit captures system audio before the output device's mute, so muting
// the Mac's speakers while mirroring leaves the TV as the only place sound plays —
// otherwise you hear everything twice, ~200 ms apart. The previous state is restored
// afterwards, and on the next launch if Mira quit unexpectedly.
final class MacAudioMuter {
    private static let pendingKey = "MiraMutedOutputDeviceUID"
    private var device: AudioObjectID?
    private var element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain

    func mute() {
        guard device == nil, let dev = Self.defaultOutputDevice() else { return }
        for el in [kAudioObjectPropertyElementMain, 1, 2] where Self.isMuteSettable(dev, el) {
            guard Self.getMute(dev, el) == false else {
                Log.info("Audio", "Mac output already muted")
                return
            }
            if Self.setMute(dev, el, true) {
                device = dev
                element = el
                UserDefaults.standard.set(Self.uid(dev), forKey: Self.pendingKey)
                Log.info("Audio", "Muted the Mac's speakers while mirroring (sound plays on the TV)")
            }
            return
        }
        Log.warn("Audio", "This output device can't be muted; sound will also play on the Mac")
    }

    func restore() {
        guard let dev = device else { return }
        _ = Self.setMute(dev, element, false)
        device = nil
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        Log.info("Audio", "Restored the Mac's speakers")
    }

    // Undo a mute left behind by a crash.
    static func restoreAfterCrash() {
        guard let uid = UserDefaults.standard.string(forKey: pendingKey) else { return }
        UserDefaults.standard.removeObject(forKey: pendingKey)
        guard let dev = defaultOutputDevice(), Self.uid(dev) == uid else { return }
        for el in [kAudioObjectPropertyElementMain, 1, 2] where isMuteSettable(dev, el) {
            _ = setMute(dev, el, false)
        }
        Log.info("Audio", "Restored Mac speakers muted by a previous session")
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != 0 else { return nil }
        return dev
    }

    private static func muteAddress(_ el: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: el)
    }

    private static func isMuteSettable(_ dev: AudioObjectID, _ el: AudioObjectPropertyElement) -> Bool {
        var addr = muteAddress(el)
        guard AudioObjectHasProperty(dev, &addr) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr && settable.boolValue
    }

    private static func getMute(_ dev: AudioObjectID, _ el: AudioObjectPropertyElement) -> Bool? {
        var addr = muteAddress(el)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func setMute(_ dev: AudioObjectID, _ el: AudioObjectPropertyElement, _ on: Bool) -> Bool {
        var addr = muteAddress(el)
        var value: UInt32 = on ? 1 : 0
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private static func uid(_ dev: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid) == noErr, let uid else { return "\(dev)" }
        return uid.takeRetainedValue() as String
    }
}

// MARK: - TV as a second screen

// Creates a virtual monitor the size of the stream; Mira then captures that monitor
// instead of mirroring an existing one. Relies on a private CoreGraphics API, so it
// verifies the display really comes online and reports a clear error otherwise.
final class ExtendedDisplay: @unchecked Sendable {   // immutable; the virtual display object is only touched on the main queue

    enum ExtendError: LocalizedError {
        case unsupported
        case notOnline

        var errorDescription: String? {
            switch self {
            case .unsupported:
                return "This version of macOS doesn't offer virtual displays, so the TV can't be used as a second screen."
            case .notOnline:
                return "macOS created the virtual display but never switched it on, so the TV can't be used as a second screen on this Mac."
            }
        }
    }

    let displayID: CGDirectDisplayID
    private let display: MiraVirtualDisplay

    private init(display: MiraVirtualDisplay) {
        self.display = display
        self.displayID = display.displayID
    }

    static var isSupported: Bool { MiraVirtualDisplay.isSupported() }

    @MainActor
    static func create(name: String, width: Int, height: Int, fps: Int, timeout: TimeInterval = 4) async throws -> ExtendedDisplay {
        guard isSupported else { throw ExtendError.unsupported }
        guard let vd = MiraVirtualDisplay(name: name, width: UInt32(width), height: UInt32(height),
                                          refreshRate: Double(fps)) else { throw ExtendError.unsupported }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if CGDisplayIsOnline(vd.displayID) != 0, CGDisplayIsActive(vd.displayID) != 0 {
                Log.info("Mira", "Virtual display \(vd.displayID) (\(width)×\(height)) is online — the TV is now a second screen")
                return ExtendedDisplay(display: vd)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ExtendError.notOnline
    }

    // Quick check for `Mira doctor`: create and immediately drop a small virtual display.
    @MainActor
    static func probe() async -> Bool {
        (try? await create(name: "Mira probe", width: 1280, height: 720, fps: 30, timeout: 3)) != nil
    }
}

// MARK: - Global keyboard shortcuts

// ⌃⌥⌘M start/stop, ⌃⌥⌘P privacy pause. Carbon hot keys need no Accessibility permission.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let id: UInt32
    private let action: () -> Void

    static let toggleMirroring = (keyCode: kVK_ANSI_M, display: "⌃⌥⌘M")
    static let togglePrivacy = (keyCode: kVK_ANSI_P, display: "⌃⌥⌘P")
    static let displayString = toggleMirroring.display

    init?(id: UInt32, keyCode: Int, modifiers: Int = controlKey | optionKey | cmdKey, action: @escaping () -> Void) {
        self.id = id
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, ctx in
            guard let ctx, let event else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<GlobalHotKey>.fromOpaque(ctx).takeUnretainedValue()
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            // Every handler sees every hot key; only react to our own.
            guard hk.id == me.id else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { me.action() }
            return noErr
        }, 1, &spec, ctx, &handlerRef)
        guard status == noErr else { return nil }
        let hkID = EventHotKeyID(signature: OSType(0x4D495241), id: id)   // 'MIRA'
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else {
            Log.warn("Mira", "A keyboard shortcut (id \(id)) is taken by another app")
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
