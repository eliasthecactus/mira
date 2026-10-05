import Foundation
import CoreGraphics
import AppKit

// Posts InputActions as macOS events. Needs the Accessibility permission
// (System Settings -> Privacy & Security -> Accessibility); without it macOS drops them.
final class InputInjector {

    // Where the streamed picture comes from, in global display coordinates (points,
    // origin top-left of the main display), and the stream size it is letterboxed into.
    struct Region: Equatable {
        var content: CGRect
        var streamWidth: Int
        var streamHeight: Int
    }

    var region: () -> Region?
    private let source = CGEventSource(stateID: .hidSystemState)
    private var location: CGPoint
    private var held: Set<MouseButton> = []
    private var flags: CGEventFlags = []
    private var lastDown: (time: TimeInterval, point: CGPoint, button: MouseButton, count: Int64)?
    private(set) var eventsPosted = 0

    init(region: @escaping () -> Region?) {
        self.region = region
        location = CGEvent(source: nil)?.location ?? .zero
    }

    static var hasPermission: Bool { CGPreflightPostEventAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestPostEventAccess() }

    // Normalized point in the stream -> global point, inverting the capture's
    // aspect-preserving letterbox. Points in the bars are clamped to the content.
    static func map(x: Double, y: Double, region r: Region) -> CGPoint {
        let W = Double(r.streamWidth), H = Double(r.streamHeight)
        let w = Double(r.content.width), h = Double(r.content.height)
        guard w > 0, h > 0, W > 0, H > 0 else { return r.content.origin }
        let scale = min(W / w, H / h)
        let offX = (W - w * scale) / 2, offY = (H - h * scale) / 2
        let cx = min(max((x * W - offX) / scale, 0), w - 1)
        let cy = min(max((y * H - offY) / scale, 0), h - 1)
        return CGPoint(x: Double(r.content.minX) + cx, y: Double(r.content.minY) + cy)
    }

    func perform(_ action: InputAction) {
        switch action {
        case .moveTo(let x, let y):
            guard let r = region() else { return }
            location = Self.map(x: x, y: y, region: r)
            postMove()
        case .moveBy(let dx, let dy):
            location = CGEvent(source: nil)?.location ?? location
            location.x += CGFloat(dx)
            location.y += CGFloat(dy)
            if let r = region()?.content {
                location.x = min(max(location.x, r.minX), r.maxX - 1)
                location.y = min(max(location.y, r.minY), r.maxY - 1)
            }
            postMove(dx: dx, dy: dy)
        case .button(let b, let down):
            postButton(b, down: down)
        case .scroll(let dy, let dx, let pixels):
            if let e = CGEvent(scrollWheelEvent2Source: source, units: pixels ? .pixel : .line,
                               wheelCount: 2, wheel1: Int32(clamping: dy), wheel2: Int32(clamping: dx), wheel3: 0) {
                post(e)
            }
        case .key(let code, let down):
            if let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) {
                e.flags = flags
                post(e)
            }
        case .modifiers(let raw):
            let new = CGEventFlags(rawValue: raw)
            for (flag, key) in UIBCTranslator.modifierKeys where (flags.rawValue ^ raw) & flag != 0 {
                if let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: raw & flag != 0) {
                    e.type = .flagsChanged
                    e.flags = new
                    post(e)
                }
            }
            flags = new
        case .text(let s):
            let utf16 = Array(s.utf16)
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                e.flags = flags
                post(e)
            }
        }
    }

    private func postMove(dx: Int = 0, dy: Int = 0) {
        let type: CGEventType
        let button: CGMouseButton
        if held.contains(.left) { type = .leftMouseDragged; button = .left }
        else if held.contains(.right) { type = .rightMouseDragged; button = .right }
        else if held.contains(.center) { type = .otherMouseDragged; button = .center }
        else { type = .mouseMoved; button = .left }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        e.flags = flags
        post(e)
    }

    private func postButton(_ b: MouseButton, down: Bool) {
        if down { held.insert(b) } else { held.remove(b) }
        let type: CGEventType
        let button: CGMouseButton
        switch b {
        case .left: type = down ? .leftMouseDown : .leftMouseUp; button = .left
        case .right: type = down ? .rightMouseDown : .rightMouseUp; button = .right
        case .center: type = down ? .otherMouseDown : .otherMouseUp; button = .center
        }
        // Double/triple clicks: a press close in time and space to the previous one.
        let now = ProcessInfo.processInfo.systemUptime
        var count: Int64 = 1
        if down {
            if let last = lastDown, last.button == b, now - last.time < NSEvent.doubleClickInterval,
               abs(last.point.x - location.x) < 6, abs(last.point.y - location.y) < 6 {
                count = last.count + 1
            }
            lastDown = (now, location, b, count)
        } else if let last = lastDown, last.button == b {
            count = last.count
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: count)
        e.flags = flags
        post(e)
    }

    private func post(_ e: CGEvent) {
        e.post(tap: .cghidEventTap)
        eventsPosted += 1
    }
}
