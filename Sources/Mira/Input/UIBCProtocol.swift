import Foundation

// User Input Back Channel (Wi-Fi Display spec 4.11): the sink sends keyboard, mouse and
// touch input back to the source over a TCP connection it opens to the port the source
// names in M4. This file is the pure protocol part: capability strings and frame parsing.

// MARK: - Capability (wfd_uibc_capability)

struct UIBCCapability: Equatable {
    var categories: [String] = []     // "GENERIC", "HIDC"
    var generic: [String] = []        // "Keyboard", "Mouse", "SingleTouch", "MultiTouch", ...
    var hidc: [String] = []           // "Keyboard/USB", "Mouse/BT", ...
    var port: UInt16?

    // What Mira can turn into Mac input.
    static let supportedTypes: Set<String> = ["keyboard", "mouse", "singletouch", "multitouch"]

    // Lenient: whitespace varies between senders and Windows omits generic_cap_list.
    static func parse(_ value: String) -> UIBCCapability? {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, v.lowercased() != "none" else { return nil }
        var cap = UIBCCapability()
        for part in v.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            let list = kv[1].lowercased() == "none" ? [] :
                kv[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            switch kv[0].lowercased() {
            case "input_category_list": cap.categories = list.map { $0.uppercased() }
            case "generic_cap_list": cap.generic = list
            case "hidc_cap_list": cap.hidc = list
            case "port": cap.port = UInt16(kv[1])
            default: break
            }
        }
        // Infer categories when the list is missing but capabilities are present.
        if cap.categories.isEmpty {
            if !cap.generic.isEmpty { cap.categories.append("GENERIC") }
            if !cap.hidc.isEmpty { cap.categories.append("HIDC") }
        }
        return cap.categories.isEmpty ? nil : cap
    }

    // The part of the sink's capability Mira accepts, with our port; nil if nothing is left.
    func accepted(port: UInt16) -> UIBCCapability? {
        let supported = Self.supportedTypes
        var out = UIBCCapability(port: port)
        if categories.contains("GENERIC") {
            out.generic = generic.filter { supported.contains($0.lowercased()) }
        }
        if categories.contains("HIDC") {
            out.hidc = hidc.filter { entry in
                supported.contains(entry.split(separator: "/").first.map { $0.lowercased() } ?? "")
            }
        }
        if !out.generic.isEmpty { out.categories.append("GENERIC") }
        if !out.hidc.isEmpty { out.categories.append("HIDC") }
        return out.categories.isEmpty ? nil : out
    }

    var descriptor: String {
        func list(_ l: [String]) -> String { l.isEmpty ? "none" : l.joined(separator: ", ") }
        return "input_category_list=\(list(categories));generic_cap_list=\(list(generic));"
            + "hidc_cap_list=\(list(hidc));port=\(port.map(String.init) ?? "none")"
    }
}

// MARK: - Messages

struct UIBCPointer: Equatable {
    var id: UInt8
    var x: UInt16
    var y: UInt16
}

enum UIBCInput: Equatable {
    enum TouchPhase: UInt8 { case down = 0, up = 1, move = 2 }
    enum ScrollUnit: Equatable { case pixels, notches }

    case touch(TouchPhase, [UIBCPointer])          // GENERIC 0/1/2, stream pixel coordinates
    case key(down: Bool, code1: UInt16, code2: UInt16)   // GENERIC 3/4, ASCII codes
    case zoom(x: UInt16, y: UInt16, scale: Double)  // GENERIC 5
    case scroll(vertical: Bool, unit: ScrollUnit, amount: Int)  // GENERIC 6/7; amount > 0 = down/right
    case rotate(radians: Double)                    // GENERIC 8
    case hid(path: UInt8, type: UInt8, isDescriptor: Bool, value: Data)   // HIDC
}

// Length-prefixed framing over TCP; tolerant of split and coalesced reads.
struct UIBCParser {
    private var buffer = Data()
    private(set) var framesParsed = 0
    private(set) var framesDropped = 0

    mutating func feed(_ data: Data) -> [UIBCInput] {
        buffer.append(data)
        var out: [UIBCInput] = []
        while buffer.count >= 4 {
            let b = [UInt8](buffer.prefix(4))
            let length = Int(b[2]) << 8 | Int(b[3])   // whole frame, header included
            let version = b[0] >> 5
            guard length >= 4, version == 0 else {
                // Lost sync; nothing sensible to resynchronise on, so start over.
                framesDropped += 1
                buffer.removeAll()
                break
            }
            guard buffer.count >= length else { break }
            let frame = [UInt8](buffer.prefix(length))
            buffer.removeFirst(length)
            buffer = Data(buffer)   // re-base indices
            framesParsed += 1
            let hasTimestamp = frame[0] & 0x10 != 0
            let category = frame[1] & 0x0F
            let start = hasTimestamp ? 6 : 4
            guard start <= frame.count else { framesDropped += 1; continue }
            let body = Array(frame[start...])
            switch category {
            case 0: out += Self.parseGeneric(body)
            case 1: out += Self.parseHIDC(body)
            default: framesDropped += 1
            }
        }
        return out
    }

    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }

    static func parseGeneric(_ body: [UInt8]) -> [UIBCInput] {
        var out: [UIBCInput] = []
        var i = 0
        while i + 3 <= body.count {
            let type = body[i]
            let len = Int(u16(body, i + 1))
            let p = i + 3
            guard p + len <= body.count else { break }
            let d = Array(body[p..<(p + len)])
            i = p + len
            switch type {
            case 0, 1, 2:
                guard let n = d.first.map(Int.init), d.count >= 1 + 5 * n, n > 0 else { continue }
                let pointers = (0..<n).map { k -> UIBCPointer in
                    let o = 1 + 5 * k
                    return UIBCPointer(id: d[o], x: u16(d, o + 1), y: u16(d, o + 3))
                }
                out.append(.touch(UIBCInput.TouchPhase(rawValue: type)!, pointers))
            case 3, 4:
                guard d.count >= 5 else { continue }
                out.append(.key(down: type == 3, code1: u16(d, 1), code2: u16(d, 3)))
            case 5:
                guard d.count >= 6 else { continue }
                out.append(.zoom(x: u16(d, 0), y: u16(d, 2), scale: Double(d[4]) + Double(d[5]) / 256))
            case 6, 7:
                guard d.count >= 2 else { continue }
                let v = u16(d, 0)
                let unit: UIBCInput.ScrollUnit = (v >> 14) == 1 ? .notches : .pixels
                let magnitude = Int(v & 0x1FFF)
                // Bit 13: vertical 1 = up, horizontal 1 = left.
                let amount = v & 0x2000 != 0 ? -magnitude : magnitude
                out.append(.scroll(vertical: type == 6, unit: unit, amount: amount))
            case 8:
                guard d.count >= 2 else { continue }
                out.append(.rotate(radians: Double(Int8(bitPattern: d[0])) + Double(d[1]) / 256))
            default:
                continue
            }
        }
        return out
    }

    static func parseHIDC(_ body: [UInt8]) -> [UIBCInput] {
        var out: [UIBCInput] = []
        var i = 0
        while i + 5 <= body.count {
            let len = Int(u16(body, i + 3))
            guard i + 5 + len <= body.count else { break }
            out.append(.hid(path: body[i], type: body[i + 1], isDescriptor: body[i + 2] == 1,
                            value: Data(body[(i + 5)..<(i + 5 + len)])))
            i += 5 + len
        }
        return out
    }

    // Builders, used by tests and handy for debugging.
    static func frame(category: UInt8, body: [UInt8], timestamp: UInt16? = nil) -> Data {
        var b = body
        let header = timestamp == nil ? 4 : 6
        if (header + b.count) % 2 == 1 { b.append(0) }   // pad to 16 bits
        let total = header + b.count
        var out: [UInt8] = [timestamp == nil ? 0x00 : 0x10, category & 0x0F, UInt8(total >> 8), UInt8(total & 0xFF)]
        if let t = timestamp { out += [UInt8(t >> 8), UInt8(t & 0xFF)] }
        return Data(out + b)
    }

    static func genericTouch(_ phase: UIBCInput.TouchPhase, _ pointers: [UIBCPointer]) -> Data {
        var d: [UInt8] = [UInt8(pointers.count)]
        for p in pointers { d += [p.id, UInt8(p.x >> 8), UInt8(p.x & 0xFF), UInt8(p.y >> 8), UInt8(p.y & 0xFF)] }
        return frame(category: 0, body: [phase.rawValue, UInt8(d.count >> 8), UInt8(d.count & 0xFF)] + d)
    }

    static func hidc(path: UInt8 = 1, type: UInt8, descriptor: Bool = false, value: [UInt8]) -> Data {
        frame(category: 1, body: [path, type, descriptor ? 1 : 0, UInt8(value.count >> 8), UInt8(value.count & 0xFF)] + value)
    }
}
