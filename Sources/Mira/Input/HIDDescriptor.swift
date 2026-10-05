import Foundation

// Minimal USB HID report descriptor parser (HID 1.11 section 6.2.2) and report decoder,
// enough for keyboards, mice and touch screens sent over UIBC HIDC.
struct HIDReportDescriptor {

    struct Field {
        var reportID: UInt8
        var bitOffset: Int            // within the report, after the report ID byte
        var size: Int                 // bits per value
        var count: Int
        var usagePage: UInt16
        var usages: [UInt16]          // per value (variable) or the usage range (array)
        var isArray: Bool             // array: values are usage indices (keyboard keys)
        var isRelative: Bool
        var isConstant: Bool
        var logicalMin: Int32
        var logicalMax: Int32
        var collection: Int           // index of the enclosing logical collection (touch fingers)
    }

    private(set) var fields: [Field] = []
    private(set) var usesReportIDs = false

    init(_ bytes: [UInt8]) {
        struct Globals {
            var usagePage: UInt16 = 0
            var logicalMin: Int32 = 0
            var logicalMax: Int32 = 0
            var reportSize = 0
            var reportCount = 0
            var reportID: UInt8 = 0
        }
        var g = Globals()
        var stack: [Globals] = []
        var usages: [UInt32] = []
        var usageMin: UInt32?
        var usageMax: UInt32?
        var offsets: [UInt8: Int] = [:]
        var collectionCounter = 0
        var collectionStack: [Int] = [0]

        var i = 0
        while i < bytes.count {
            let prefix = bytes[i]
            if prefix == 0xFE {                       // long item: skip
                guard i + 2 < bytes.count else { break }
                i += 3 + Int(bytes[i + 1])
                continue
            }
            let size = [0, 1, 2, 4][Int(prefix & 0x03)]
            let type = (prefix >> 2) & 0x03
            let tag = prefix >> 4
            guard i + 1 + size <= bytes.count else { break }
            var unsigned: UInt32 = 0
            for k in 0..<size { unsigned |= UInt32(bytes[i + 1 + k]) << (8 * UInt32(k)) }
            let signed: Int32
            switch size {
            case 1: signed = Int32(Int8(bitPattern: UInt8(unsigned)))
            case 2: signed = Int32(Int16(bitPattern: UInt16(unsigned)))
            case 4: signed = Int32(bitPattern: unsigned)
            default: signed = 0
            }
            i += 1 + size

            switch (type, tag) {
            // Main items
            case (0, 0x8):                                     // Input
                let isConstant = unsigned & 0x01 != 0
                let isVariable = unsigned & 0x02 != 0
                let isRelative = unsigned & 0x04 != 0
                var fieldUsages: [UInt16]
                var page = g.usagePage
                if !usages.isEmpty {
                    // Extended usages (32-bit) carry their own page.
                    if usages[0] > 0xFFFF { page = UInt16(usages[0] >> 16) }
                    fieldUsages = usages.map { UInt16($0 & 0xFFFF) }
                } else if let lo = usageMin, let hi = usageMax, hi >= lo, hi - lo < 1024 {
                    if lo > 0xFFFF { page = UInt16(lo >> 16) }
                    fieldUsages = (lo...hi).map { UInt16($0 & 0xFFFF) }
                } else {
                    fieldUsages = []
                }
                if isVariable, !fieldUsages.isEmpty, fieldUsages.count < g.reportCount {
                    fieldUsages += Array(repeating: fieldUsages.last!, count: g.reportCount - fieldUsages.count)
                }
                let offset = offsets[g.reportID, default: 0]
                fields.append(Field(reportID: g.reportID, bitOffset: offset, size: g.reportSize, count: g.reportCount,
                                    usagePage: page, usages: fieldUsages, isArray: !isVariable,
                                    isRelative: isRelative, isConstant: isConstant,
                                    logicalMin: g.logicalMin, logicalMax: g.logicalMax,
                                    collection: collectionStack.last ?? 0))
                offsets[g.reportID] = offset + g.reportSize * g.reportCount
                usages = []; usageMin = nil; usageMax = nil
            case (0, 0x9), (0, 0xB):                           // Output, Feature: not in input reports
                usages = []; usageMin = nil; usageMax = nil
            case (0, 0xA):                                     // Collection
                collectionCounter += 1
                collectionStack.append(collectionCounter)
                usages = []; usageMin = nil; usageMax = nil
            case (0, 0xC):                                     // End Collection
                if collectionStack.count > 1 { collectionStack.removeLast() }
            // Global items
            case (1, 0x0): g.usagePage = UInt16(truncatingIfNeeded: unsigned)
            case (1, 0x1): g.logicalMin = signed
            case (1, 0x2):
                // Logical Maximum is unsigned when Logical Minimum is non-negative.
                g.logicalMax = g.logicalMin >= 0 ? Int32(truncatingIfNeeded: unsigned) : signed
            case (1, 0x7): g.reportSize = Int(unsigned)
            case (1, 0x8):
                g.reportID = UInt8(truncatingIfNeeded: unsigned)
                usesReportIDs = true
            case (1, 0x9): g.reportCount = Int(unsigned)
            case (1, 0xA): stack.append(g)
            case (1, 0xB): if let top = stack.popLast() { g = top }
            // Local items
            case (2, 0x0): usages.append(size == 4 ? unsigned : unsigned & 0xFFFF)
            case (2, 0x1): usageMin = size == 4 ? unsigned : unsigned & 0xFFFF
            case (2, 0x2): usageMax = size == 4 ? unsigned : unsigned & 0xFFFF
            default: break
            }
        }
    }

    // One decoded value.
    struct Value: Equatable {
        var usagePage: UInt16
        var usage: UInt16
        var value: Int32
        var isRelative: Bool
        var logicalMin: Int32
        var logicalMax: Int32
        var collection: Int

        // 0...1 for absolute values.
        var normalized: Double {
            guard logicalMax > logicalMin else { return 0 }
            return min(1, max(0, Double(value - logicalMin) / Double(logicalMax - logicalMin)))
        }
    }

    // Decodes one input report. Array fields yield one value per pressed usage (value 1).
    func decode(_ report: [UInt8]) -> [Value] {
        var data = report
        var id: UInt8 = 0
        if usesReportIDs {
            guard let first = data.first else { return [] }
            id = first
            data.removeFirst()
        }
        var out: [Value] = []
        for f in fields where f.reportID == id && !f.isConstant {
            for k in 0..<f.count {
                let bit = f.bitOffset + k * f.size
                guard bit + f.size <= data.count * 8, f.size > 0, f.size <= 32 else { continue }
                var raw: UInt32 = 0
                for b in 0..<f.size {
                    let pos = bit + b
                    if data[pos / 8] & (1 << UInt8(pos % 8)) != 0 { raw |= 1 << UInt32(b) }
                }
                var value = Int32(bitPattern: raw)
                if f.logicalMin < 0, f.size < 32, raw & (1 << UInt32(f.size - 1)) != 0 {
                    value = Int32(bitPattern: raw | ~((1 << UInt32(f.size)) - 1))   // sign-extend
                }
                if f.isArray {
                    // Value is an index into the usage range; 0/out of range = no key.
                    let index = Int(value - f.logicalMin)
                    guard value != 0 || f.logicalMin != 0, index >= 0, index < f.usages.count else { continue }
                    let usage = f.usages[index]
                    guard usage != 0 else { continue }
                    out.append(Value(usagePage: f.usagePage, usage: usage, value: 1, isRelative: false,
                                     logicalMin: 0, logicalMax: 1, collection: f.collection))
                } else {
                    guard k < f.usages.count else { continue }
                    out.append(Value(usagePage: f.usagePage, usage: f.usages[k], value: value,
                                     isRelative: f.isRelative, logicalMin: f.logicalMin,
                                     logicalMax: f.logicalMax, collection: f.collection))
                }
            }
        }
        return out
    }

    // HID 1.11 Appendix E.6: boot keyboard (no report ID; modifiers, reserved, 6 keys).
    static let bootKeyboard: [UInt8] = [
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x01, 0x95, 0x05, 0x75, 0x01,
        0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x01, 0x95, 0x06,
        0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00, 0xC0,
    ]

    // HID 1.11 Appendix E.10: boot mouse (3 buttons, relative X/Y), plus a wheel byte.
    static let bootMouse: [UInt8] = [
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01, 0xA1, 0x00, 0x05, 0x09, 0x19, 0x01, 0x29, 0x03,
        0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01, 0x81, 0x02, 0x95, 0x01, 0x75, 0x05, 0x81, 0x01,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03,
        0x81, 0x06, 0xC0, 0xC0,
    ]
}
