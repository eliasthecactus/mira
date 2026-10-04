import Foundation
import CoreGraphics

// Menu bar app preferences (UserDefaults).
enum Settings {
    private static let d = UserDefaults.standard

    static let autoBitrateMax = 12      // Mbit/s ceiling for adaptive mode

    static var resolution: StreamPreferences.ResolutionChoice {
        get { d.string(forKey: "resolution").flatMap(StreamPreferences.ResolutionChoice.init) ?? .auto }
        set { d.set(newValue.rawValue, forKey: "resolution") }
    }
    static var audio: Bool {
        get { d.object(forKey: "audio") as? Bool ?? true }
        set { d.set(newValue, forKey: "audio") }
    }
    // 0 = automatic (adapts to the Wi-Fi, up to autoBitrateMax)
    static var bitrateMbps: Int {
        get { d.object(forKey: "bitrateMbps2") as? Int ?? 0 }
        set { d.set(newValue, forKey: "bitrateMbps2") }
    }
    static var displayID: CGDirectDisplayID? {
        get { (d.object(forKey: "displayID") as? NSNumber).map { $0.uint32Value } }
        set { if let v = newValue { d.set(NSNumber(value: v), forKey: "displayID") } else { d.removeObject(forKey: "displayID") } }
    }
    static var extendDisplay: Bool {
        get { d.bool(forKey: "extendDisplay") }
        set { d.set(newValue, forKey: "extendDisplay") }
    }
    static var security: MiraController.SecurityChoice {
        get { d.string(forKey: "security").flatMap(MiraController.SecurityChoice.init) ?? .auto }
        set { d.set(newValue.rawValue, forKey: "security") }
    }
    static var muteMac: Bool {
        get { d.object(forKey: "muteMac") as? Bool ?? true }
        set { d.set(newValue, forKey: "muteMac") }
    }
    static var testPattern: Bool {
        get { d.bool(forKey: "testPattern") }
        set { d.set(newValue, forKey: "testPattern") }
    }
    static var reconnectOnLaunch: Bool {
        get { d.bool(forKey: "reconnectOnLaunch") }
        set { d.set(newValue, forKey: "reconnectOnLaunch") }
    }
    static var lastManualIP: String {
        get { d.string(forKey: "lastManualIP") ?? "" }
        set { d.set(newValue, forKey: "lastManualIP") }
    }

    // The display last mirrored to, for "reconnect on launch" and the keyboard shortcut.
    static var lastDevice: MiracastDevice? {
        get {
            guard let name = d.string(forKey: "lastDeviceName"), let ip = d.string(forKey: "lastDeviceIP") else { return nil }
            let port = d.object(forKey: "lastDevicePort") as? Int ?? Int(MiracastDevice.defaultMICEPort)
            return MiracastDevice(name: name, ipAddress: ip, port: UInt16(port))
        }
        set {
            d.set(newValue?.name, forKey: "lastDeviceName")
            d.set(newValue?.ipAddress, forKey: "lastDeviceIP")
            d.set(newValue.map { Int($0.port) }, forKey: "lastDevicePort")
        }
    }

    static func options() -> MiraController.Options {
        var o = MiraController.Options()
        o.prefs.resolution = resolution
        o.prefs.audio = audio
        if bitrateMbps == 0 {
            o.prefs.bitrate = autoBitrateMax * 1_000_000
            o.adaptiveBitrate = true
        } else {
            o.prefs.bitrate = bitrateMbps * 1_000_000
            o.adaptiveBitrate = false
        }
        o.testPattern = testPattern
        o.extendDisplay = extendDisplay
        o.security = security
        o.muteMac = muteMac
        // A remembered display that is no longer connected falls back to the main one.
        if let id = displayID, DisplayInfo.all().contains(where: { $0.id == id }) { o.displayID = id }
        return o
    }
}
