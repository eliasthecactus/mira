import Foundation

// [MS-MICE] Miracast over Infrastructure Connection Establishment messages.
//
// Sent by the source over TCP to the sink's port 7250. All multi-byte fields are
// big-endian:
//   Size (2, whole message) | Version (1) = 0x01 | Command (1) | TLV...
//   TLV = Type (1) | Length (2, value only) | Value
//
// Only SOURCE_READY and STOP_PROJECTION are needed for an unencrypted, PIN-less
// session; they are the two messages every MICE sink must implement.
struct MICEMessage: Equatable {

    enum Command: UInt8 {
        case sourceReady       = 0x01
        case stopProjection    = 0x02
        case securityHandshake = 0x03
        case sessionRequest    = 0x04
        case pinChallenge      = 0x05
        case pinResponse       = 0x06
    }

    enum TLVType: UInt8 {
        case friendlyName      = 0x00
        case rtspPort          = 0x02
        case sourceID          = 0x03
        case securityToken     = 0x04
        case securityOptions   = 0x05
        case pinChallenge      = 0x06
        case pinResponseReason = 0x07
    }

    struct TLV: Equatable {
        var type: UInt8
        var value: Data
    }

    static let protocolVersion: UInt8 = 0x01
    static let headerSize = 4
    static let maxFriendlyNameBytes = 520

    var version: UInt8 = MICEMessage.protocolVersion
    var command: UInt8
    var tlvs: [TLV]

    // MARK: - Factories

    static func sourceReady(friendlyName: String, rtspPort: UInt16, sourceID: Data) -> MICEMessage {
        MICEMessage(command: Command.sourceReady.rawValue, tlvs: [
            TLV(type: TLVType.friendlyName.rawValue, value: encodeFriendlyName(friendlyName)),
            TLV(type: TLVType.rtspPort.rawValue, value: Data([UInt8(rtspPort >> 8), UInt8(rtspPort & 0xFF)])),
            TLV(type: TLVType.sourceID.rawValue, value: normalizedSourceID(sourceID)),
        ])
    }

    static func stopProjection(friendlyName: String, sourceID: Data) -> MICEMessage {
        MICEMessage(command: Command.stopProjection.rawValue, tlvs: [
            TLV(type: TLVType.friendlyName.rawValue, value: encodeFriendlyName(friendlyName)),
            TLV(type: TLVType.sourceID.rawValue, value: normalizedSourceID(sourceID)),
        ])
    }

    // Source ID is exactly 16 implementation-defined bytes.
    static func normalizedSourceID(_ id: Data) -> Data {
        var d = Data(id.prefix(16))
        if d.count < 16 { d.append(Data(count: 16 - d.count)) }
        return d
    }

    // The spec says "UTF-16" without a byte order. Windows (and GNOME Network
    // Displays, which is known to work against real sinks) send UTF-16LE with a
    // BOM, so we do the same. Truncated on a character boundary to 520 bytes.
    static func encodeFriendlyName(_ name: String) -> Data {
        var out = Data([0xFF, 0xFE])
        for ch in name {
            var chunk = Data()
            for unit in String(ch).utf16 {
                chunk.append(UInt8(unit & 0xFF))
                chunk.append(UInt8(unit >> 8))
            }
            if out.count + chunk.count > maxFriendlyNameBytes { break }
            out.append(chunk)
        }
        return out
    }

    static func decodeFriendlyName(_ data: Data) -> String? {
        var bytes = [UInt8](data)
        var littleEndian = true
        if bytes.count >= 2 {
            if bytes[0] == 0xFF && bytes[1] == 0xFE { bytes.removeFirst(2) }
            else if bytes[0] == 0xFE && bytes[1] == 0xFF { bytes.removeFirst(2); littleEndian = false }
        }
        guard bytes.count % 2 == 0 else { return nil }
        var units: [UInt16] = []
        for i in stride(from: 0, to: bytes.count, by: 2) {
            units.append(littleEndian
                ? UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
                : UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
        }
        return String(decoding: units, as: UTF16.self)
    }

    // MARK: - Accessors

    func value(_ type: TLVType) -> Data? { tlvs.first { $0.type == type.rawValue }?.value }

    var friendlyName: String? { value(.friendlyName).flatMap(Self.decodeFriendlyName) }

    var rtspPort: UInt16? {
        guard let v = value(.rtspPort), v.count == 2 else { return nil }
        let b = [UInt8](v)
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }

    var commandName: String {
        switch Command(rawValue: command) {
        case .sourceReady: return "SOURCE_READY"
        case .stopProjection: return "STOP_PROJECTION"
        case .securityHandshake: return "SECURITY_HANDSHAKE"
        case .sessionRequest: return "SESSION_REQUEST"
        case .pinChallenge: return "PIN_CHALLENGE"
        case .pinResponse: return "PIN_RESPONSE"
        case nil: return String(format: "UNKNOWN(0x%02X)", command)
        }
    }

    // MARK: - Wire format

    func serialize() -> Data {
        var body = Data()
        for tlv in tlvs {
            body.append(tlv.type)
            body.appendBE(UInt16(tlv.value.count))
            body.append(tlv.value)
        }
        var out = Data()
        out.appendBE(UInt16(Self.headerSize + body.count))
        out.append(version)
        out.append(command)
        out.append(body)
        return out
    }

    enum ParseError: Error { case badSize(Int), truncatedTLV }

    // Removes one complete message from the front of `buffer`.
    // Returns nil when more bytes are needed.
    static func extract(from buffer: inout Data) throws -> MICEMessage? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= headerSize else { return nil }
        let size = Int(bytes[0]) << 8 | Int(bytes[1])
        guard size >= headerSize else { throw ParseError.badSize(size) }
        guard bytes.count >= size else { return nil }

        var tlvs: [TLV] = []
        var i = headerSize
        while i < size {
            guard i + 3 <= size else { throw ParseError.truncatedTLV }
            let len = Int(bytes[i + 1]) << 8 | Int(bytes[i + 2])
            guard i + 3 + len <= size else { throw ParseError.truncatedTLV }
            tlvs.append(TLV(type: bytes[i], value: Data(bytes[(i + 3)..<(i + 3 + len)])))
            i += 3 + len
        }
        buffer = Data(bytes[size...])
        return MICEMessage(version: bytes[2], command: bytes[3], tlvs: tlvs)
    }
}
