import AppKit
import CoreGraphics

// The Mac's connected displays, for choosing which one to mirror.
struct DisplayInfo: Equatable {
    let id: CGDirectDisplayID
    let name: String
    let width: Int
    let height: Int
    let isMain: Bool

    var label: String { "\(name) (\(width)×\(height))\(isMain ? " — main" : "")" }

    static func all() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        let names: [CGDirectDisplayID: String] = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { s in
            (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { ($0.uint32Value, s.localizedName) }
        })
        let main = CGMainDisplayID()
        return ids.prefix(Int(count)).map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            return DisplayInfo(id: id,
                               name: names[id] ?? "Display \(id)",
                               width: mode?.width ?? Int(CGDisplayPixelsWide(id)),
                               height: mode?.height ?? Int(CGDisplayPixelsHigh(id)),
                               isMain: id == main)
        }.sorted { ($0.isMain ? 0 : 1, $0.id) < ($1.isMain ? 0 : 1, $1.id) }
    }
}
