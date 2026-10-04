import Foundation
import CoreGraphics

// Menu bar app preferences (UserDefaults).
enum Settings {
    private static let d = UserDefaults.standard

    static var resolution: StreamPreferences.ResolutionChoice {
        get { d.string(forKey: "resolution").flatMap(StreamPreferences.ResolutionChoice.init) ?? .auto }
        set { d.set(newValue.rawValue, forKey: "resolution") }
    }
    static var audio: Bool {
        get { d.object(forKey: "audio") as? Bool ?? true }
        set { d.set(newValue, forKey: "audio") }
    }
    static var bitrateMbps: Int {
        get { d.object(forKey: "bitrateMbps") as? Int ?? 6 }
        set { d.set(newValue, forKey: "bitrateMbps") }
    }
    static var displayID: CGDirectDisplayID? {
        get { (d.object(forKey: "displayID") as? NSNumber).map { $0.uint32Value } }
        set { if let v = newValue { d.set(NSNumber(value: v), forKey: "displayID") } else { d.removeObject(forKey: "displayID") } }
    }
    static var testPattern: Bool {
        get { d.bool(forKey: "testPattern") }
        set { d.set(newValue, forKey: "testPattern") }
    }
    static var lastManualIP: String {
        get { d.string(forKey: "lastManualIP") ?? "" }
        set { d.set(newValue, forKey: "lastManualIP") }
    }

    static func options() -> MiraController.Options {
        var o = MiraController.Options()
        o.prefs.resolution = resolution
        o.prefs.audio = audio
        o.prefs.bitrate = bitrateMbps * 1_000_000
        o.testPattern = testPattern
        // A remembered display that is no longer connected falls back to the main one.
        if let id = displayID, DisplayInfo.all().contains(where: { $0.id == id }) { o.displayID = id }
        return o
    }
}
