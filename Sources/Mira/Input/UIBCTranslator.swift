import Foundation

enum MouseButton: Int { case left = 0, right = 1, center = 2 }

// What should happen on the Mac, independent of how it is injected.
enum InputAction: Equatable {
    case moveTo(x: Double, y: Double)          // normalized position in the streamed picture
    case moveBy(dx: Int, dy: Int)              // relative mouse motion, pixels
    case button(MouseButton, down: Bool)
    case scroll(dy: Int, dx: Int, pixels: Bool)   // positive dy = up, positive dx = left (CGEvent convention)
    case key(UInt16, down: Bool)               // macOS virtual key code
    case modifiers(UInt64)                     // CGEventFlags now in effect
    case text(String)                          // a typed character (GENERIC keys)
}

// UIBC input -> InputActions. Keeps the state needed to turn HID reports (which carry
// "what is pressed now") into press/release transitions.
final class UIBCTranslator {
    let streamWidth: Int
    let streamHeight: Int

    private var descriptors: [UInt16: HIDReportDescriptor] = [:]
    private var pressedKeys: Set<UInt16> = []
    private var modifierFlags: UInt64 = 0
    private var mouseButtons: Set<MouseButton> = []
    private var touchContact: Int32?           // contact being followed (HID touch)
    private var genericTouchDown = false
    private(set) var ignoredInputs = 0

    init(streamWidth: Int, streamHeight: Int) {
        self.streamWidth = max(1, streamWidth)
        self.streamHeight = max(1, streamHeight)
    }

    func translate(_ input: UIBCInput) -> [InputAction] {
        switch input {
        case .touch(let phase, let pointers):
            guard let p = pointers.first else { return [] }
            let pos = InputAction.moveTo(x: Double(p.x) / Double(streamWidth), y: Double(p.y) / Double(streamHeight))
            switch phase {
            case .down:
                genericTouchDown = true
                return [pos, .button(.left, down: true)]
            case .move:
                return [pos]
            case .up:
                guard genericTouchDown else { return [pos] }
                genericTouchDown = false
                return [pos, .button(.left, down: false)]
            }

        case .key(let down, let code1, _):
            return genericKey(code1, down: down)

        case .scroll(let vertical, let unit, let amount):
            // UIBC: positive = down/right. CGEvent: positive = up/left.
            let pixels = unit == .pixels
            return vertical ? [.scroll(dy: -amount, dx: 0, pixels: pixels)] : [.scroll(dy: 0, dx: -amount, pixels: pixels)]

        case .zoom, .rotate:
            ignoredInputs += 1
            return []

        case .hid(let path, let type, let isDescriptor, let value):
            let key = UInt16(path) << 8 | UInt16(type)
            if isDescriptor {
                descriptors[key] = HIDReportDescriptor([UInt8](value))
                return []
            }
            guard let d = descriptors[key] ?? Self.defaultDescriptor(type: type) else {
                ignoredInputs += 1
                return []
            }
            return hidReport(d.decode([UInt8](value)))
        }
    }

    // Boot descriptors may be assumed for keyboards and mice (WFD 4.11.3.2).
    static func defaultDescriptor(type: UInt8) -> HIDReportDescriptor? {
        switch type {
        case 0: return HIDReportDescriptor(HIDReportDescriptor.bootKeyboard)
        case 1: return HIDReportDescriptor(HIDReportDescriptor.bootMouse)
        default: return nil
        }
    }

    // MARK: - GENERIC keys (ASCII)

    private func genericKey(_ code: UInt16, down: Bool) -> [InputAction] {
        let ascii = code & 0xFF
        if let vk = Self.asciiControlKeys[ascii] { return [.key(vk, down: down)] }
        guard down, ascii >= 0x20, ascii < 0x7F, let scalar = Unicode.Scalar(UInt32(ascii)) else { return [] }
        return [.text(String(Character(scalar)))]
    }

    static let asciiControlKeys: [UInt16: UInt16] = [
        0x08: 51,    // backspace -> Delete
        0x09: 48,    // tab
        0x0A: 36, 0x0D: 36,   // return
        0x1B: 53,    // escape
        0x7F: 117,   // delete -> Forward Delete
    ]

    // MARK: - HID reports

    private func hidReport(_ values: [HIDReportDescriptor.Value]) -> [InputAction] {
        if values.contains(where: { $0.usagePage == 0x0D }) { return touchReport(values) }
        if values.contains(where: { $0.usagePage == 0x07 }) { return keyboardReport(values) }
        if values.contains(where: { $0.usagePage == 0x09 || ($0.usagePage == 0x01 && (0x30...0x38).contains($0.usage)) }) {
            return mouseReport(values)
        }
        ignoredInputs += 1
        return []
    }

    private func keyboardReport(_ values: [HIDReportDescriptor.Value]) -> [InputAction] {
        let keys = values.filter { $0.usagePage == 0x07 }
        // 0x01-0x03: phantom state (too many keys) - keep the previous state.
        if keys.contains(where: { (0x01...0x03).contains($0.usage) && $0.value != 0 }) { return [] }
        var flags: UInt64 = 0
        var pressed = Set<UInt16>()
        for v in keys where v.value != 0 {
            if (0xE0...0xE7).contains(v.usage) {
                flags |= Self.modifierFlag[v.usage] ?? 0
            } else if v.usage >= 0x04 {
                pressed.insert(v.usage)
            }
        }
        var out: [InputAction] = []
        if flags != modifierFlags {
            modifierFlags = flags
            out.append(.modifiers(flags))
        }
        for usage in pressedKeys.subtracting(pressed).sorted() {
            if let vk = Self.hidToMac[usage] { out.append(.key(vk, down: false)) }
        }
        for usage in pressed.subtracting(pressedKeys).sorted() {
            if let vk = Self.hidToMac[usage] { out.append(.key(vk, down: true)) }
        }
        pressedKeys = pressed
        return out
    }

    private func mouseReport(_ values: [HIDReportDescriptor.Value]) -> [InputAction] {
        var out: [InputAction] = []
        var x: HIDReportDescriptor.Value?
        var y: HIDReportDescriptor.Value?
        var wheel = 0, pan = 0
        var buttons = Set<MouseButton>()
        for v in values {
            switch (v.usagePage, v.usage) {
            case (0x01, 0x30): x = v
            case (0x01, 0x31): y = v
            case (0x01, 0x38): wheel = Int(v.value)
            case (0x0C, 0x238): pan = Int(v.value)
            case (0x09, 1...3): if v.value != 0, let b = MouseButton(rawValue: Int(v.usage) - 1) { buttons.insert(b) }
            default: break
            }
        }
        if let x, let y {
            if x.isRelative || y.isRelative {
                if x.value != 0 || y.value != 0 { out.append(.moveBy(dx: Int(x.value), dy: Int(y.value))) }
            } else {
                out.append(.moveTo(x: x.normalized, y: y.normalized))
            }
        }
        for b in [MouseButton.left, .right, .center] where buttons.contains(b) != mouseButtons.contains(b) {
            out.append(.button(b, down: buttons.contains(b)))
        }
        mouseButtons = buttons
        // HID wheel: positive = away from the user = scroll up. AC Pan: positive = right.
        if wheel != 0 || pan != 0 { out.append(.scroll(dy: wheel, dx: -pan, pixels: false)) }
        return out
    }

    // Touch screens report each finger in its own logical collection. Only the first
    // finger drives the pointer (tap = click, drag = drag).
    private func touchReport(_ values: [HIDReportDescriptor.Value]) -> [InputAction] {
        struct Contact { var id: Int32 = -1; var tip = false; var x: Double?; var y: Double? }
        var contacts: [Int: Contact] = [:]
        var order: [Int] = []
        for v in values {
            if contacts[v.collection] == nil { contacts[v.collection] = Contact(); order.append(v.collection) }
            switch (v.usagePage, v.usage) {
            case (0x0D, 0x42): contacts[v.collection]!.tip = v.value != 0       // tip switch
            case (0x0D, 0x51): contacts[v.collection]!.id = v.value             // contact identifier
            case (0x01, 0x30): contacts[v.collection]!.x = v.normalized
            case (0x01, 0x31): contacts[v.collection]!.y = v.normalized
            default: break
            }
        }
        let fingers = order.compactMap { contacts[$0] }.filter { $0.x != nil && $0.y != nil }
        if let followed = touchContact {
            // Hybrid-mode reports may not contain our finger at all; then nothing changed.
            guard let c = fingers.first(where: { $0.id == followed }) else { return [] }
            let pos = InputAction.moveTo(x: c.x!, y: c.y!)
            if c.tip { return [pos] }
            touchContact = nil
            return [pos, .button(.left, down: false)]
        }
        guard let c = fingers.first(where: { $0.tip }) else { return [] }
        touchContact = c.id
        return [.moveTo(x: c.x!, y: c.y!), .button(.left, down: true)]
    }

    // Releases everything still held (connection lost or input disabled).
    func releaseAll() -> [InputAction] {
        var out: [InputAction] = []
        for usage in pressedKeys.sorted() { if let vk = Self.hidToMac[usage] { out.append(.key(vk, down: false)) } }
        if modifierFlags != 0 { out.append(.modifiers(0)) }
        for b in [MouseButton.left, .right, .center] where mouseButtons.contains(b) { out.append(.button(b, down: false)) }
        if touchContact != nil || genericTouchDown, !mouseButtons.contains(.left) { out.append(.button(.left, down: false)) }
        pressedKeys = []; modifierFlags = 0; mouseButtons = []; touchContact = nil; genericTouchDown = false
        return out
    }

    // MARK: - Tables

    // CGEventFlags: shift 0x20000, control 0x40000, option 0x80000, command 0x100000.
    static let modifierFlag: [UInt16: UInt64] = [
        0xE0: 0x40000, 0xE1: 0x20000, 0xE2: 0x80000, 0xE3: 0x100000,
        0xE4: 0x40000, 0xE5: 0x20000, 0xE6: 0x80000, 0xE7: 0x100000,
    ]

    // Modifier flag -> the virtual key used for its flagsChanged event.
    static let modifierKeys: [(flag: UInt64, key: UInt16)] = [
        (0x20000, 56), (0x40000, 59), (0x80000, 58), (0x100000, 55),
    ]

    // USB HID keyboard usage (page 7) -> macOS virtual key code (Carbon kVK_*).
    static let hidToMac: [UInt16: UInt16] = [
        0x04: 0, 0x05: 11, 0x06: 8, 0x07: 2, 0x08: 14, 0x09: 3, 0x0A: 5, 0x0B: 4, 0x0C: 34, 0x0D: 38,
        0x0E: 40, 0x0F: 37, 0x10: 46, 0x11: 45, 0x12: 31, 0x13: 35, 0x14: 12, 0x15: 15, 0x16: 1, 0x17: 17,
        0x18: 32, 0x19: 9, 0x1A: 13, 0x1B: 7, 0x1C: 16, 0x1D: 6,
        0x1E: 18, 0x1F: 19, 0x20: 20, 0x21: 21, 0x22: 23, 0x23: 22, 0x24: 26, 0x25: 28, 0x26: 25, 0x27: 29,
        0x28: 36, 0x29: 53, 0x2A: 51, 0x2B: 48, 0x2C: 49, 0x2D: 27, 0x2E: 24, 0x2F: 33, 0x30: 30, 0x31: 42,
        0x32: 42, 0x33: 41, 0x34: 39, 0x35: 50, 0x36: 43, 0x37: 47, 0x38: 44, 0x39: 57,
        0x3A: 122, 0x3B: 120, 0x3C: 99, 0x3D: 118, 0x3E: 96, 0x3F: 97, 0x40: 98, 0x41: 100, 0x42: 101,
        0x43: 109, 0x44: 103, 0x45: 111,
        0x46: 105, 0x47: 107, 0x48: 113, 0x49: 114, 0x4A: 115, 0x4B: 116, 0x4C: 117, 0x4D: 119, 0x4E: 121,
        0x4F: 124, 0x50: 123, 0x51: 125, 0x52: 126,
        0x53: 71, 0x54: 75, 0x55: 67, 0x56: 78, 0x57: 69, 0x58: 76, 0x59: 83, 0x5A: 84, 0x5B: 85, 0x5C: 86,
        0x5D: 87, 0x5E: 88, 0x5F: 89, 0x60: 91, 0x61: 92, 0x62: 82, 0x63: 65, 0x64: 10, 0x67: 81,
        0x68: 105, 0x69: 107, 0x6A: 113, 0x6B: 106, 0x6C: 64, 0x6D: 79, 0x6E: 80, 0x6F: 90,
        0xE0: 59, 0xE1: 56, 0xE2: 58, 0xE3: 55, 0xE4: 62, 0xE5: 60, 0xE6: 61, 0xE7: 54,
    ]
}
