import Foundation

// Google Cast v2 control message (cast_channel.proto), hand-encoded: on the wire each
// message is a 4-byte big-endian length followed by this protobuf:
//
//   message CastMessage {
//     required ProtocolVersion protocol_version = 1;  // CASTV2_1_0 = 0
//     required string source_id = 2;
//     required string destination_id = 3;
//     required string namespace = 4;
//     required PayloadType payload_type = 5;           // STRING = 0, BINARY = 1
//     optional string payload_utf8 = 6;
//     optional bytes payload_binary = 7;
//   }
struct CastMessage: Equatable {
    var sourceID: String
    var destinationID: String
    var namespace: String
    var payloadUTF8: String? = nil
    var payloadBinary: Data? = nil

    static let maxSize = 64 * 1024      // receivers reject anything bigger

    // Namespaces
    static let connection = "urn:x-cast:com.google.cast.tp.connection"
    static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    static let receiver = "urn:x-cast:com.google.cast.receiver"
    static let webrtc = "urn:x-cast:com.google.cast.webrtc"
    static let remoting = "urn:x-cast:com.google.cast.remoting"
    static let deviceAuth = "urn:x-cast:com.google.cast.tp.deviceauth"

    static let platformSender = "sender-0"
    static let platformReceiver = "receiver-0"

    // The JSON payload as a dictionary (nil if not JSON).
    var json: [String: Any]? {
        guard let s = payloadUTF8, let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    var type: String? { (json?["type"] as? String) ?? (json?["responseType"] as? String) }

    static func json(_ object: [String: Any], namespace: String, from: String, to: String) -> CastMessage {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return CastMessage(sourceID: from, destinationID: to, namespace: namespace,
                           payloadUTF8: String(decoding: data, as: UTF8.self))
    }

    // MARK: - Protobuf

    func encode() -> Data {
        var out = Data()
        Self.appendVarintField(1, 0, to: &out)
        Self.appendBytesField(2, Data(sourceID.utf8), to: &out)
        Self.appendBytesField(3, Data(destinationID.utf8), to: &out)
        Self.appendBytesField(4, Data(namespace.utf8), to: &out)
        if let payloadBinary {
            Self.appendVarintField(5, 1, to: &out)
            Self.appendBytesField(7, payloadBinary, to: &out)
        } else {
            Self.appendVarintField(5, 0, to: &out)
            Self.appendBytesField(6, Data((payloadUTF8 ?? "").utf8), to: &out)
        }
        return out
    }

    // Length-prefixed, ready for the socket.
    func framed() -> Data {
        let body = encode()
        var out = Data([UInt8(body.count >> 24 & 0xFF), UInt8(body.count >> 16 & 0xFF),
                        UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)])
        out.append(body)
        return out
    }

    static func decode(_ data: Data) -> CastMessage? {
        let b = [UInt8](data)
        var i = 0
        var msg = CastMessage(sourceID: "", destinationID: "", namespace: "")
        var payloadType: UInt64 = 0
        func varint() -> UInt64? {
            var value: UInt64 = 0, shift: UInt64 = 0
            while i < b.count {
                let byte = b[i]; i += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        while i < b.count {
            guard let key = varint() else { return nil }
            let field = key >> 3, wire = key & 7
            switch wire {
            case 0:
                guard let v = varint() else { return nil }
                if field == 5 { payloadType = v }
            case 2:
                guard let len = varint(), i + Int(len) <= b.count else { return nil }
                let bytes = Data(b[i..<(i + Int(len))])
                i += Int(len)
                switch field {
                case 2: msg.sourceID = String(decoding: bytes, as: UTF8.self)
                case 3: msg.destinationID = String(decoding: bytes, as: UTF8.self)
                case 4: msg.namespace = String(decoding: bytes, as: UTF8.self)
                case 6: msg.payloadUTF8 = String(decoding: bytes, as: UTF8.self)
                case 7: msg.payloadBinary = bytes
                default: break
                }
            case 1: i += 8
            case 5: i += 4
            default: return nil
            }
        }
        if payloadType == 1, msg.payloadBinary == nil { msg.payloadBinary = Data() }
        return msg
    }

    // Pulls complete messages out of a TCP stream buffer.
    static func extract(from buffer: inout Data) -> [CastMessage]? {
        var out: [CastMessage] = []
        while buffer.count >= 4 {
            let h = [UInt8](buffer.prefix(4))
            let len = Int(h[0]) << 24 | Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3])
            guard len <= maxSize else { return nil }
            guard buffer.count >= 4 + len else { break }
            let body = buffer.subdata(in: (buffer.startIndex + 4)..<(buffer.startIndex + 4 + len))
            buffer = Data(buffer.dropFirst(4 + len))
            guard let m = decode(body) else { return nil }
            out.append(m)
        }
        return out
    }

    private static func appendVarint(_ v: UInt64, to out: inout Data) {
        var v = v
        while v >= 0x80 { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        out.append(UInt8(v))
    }

    private static func appendVarintField(_ field: UInt64, _ value: UInt64, to out: inout Data) {
        appendVarint(field << 3, to: &out)
        appendVarint(value, to: &out)
    }

    private static func appendBytesField(_ field: UInt64, _ bytes: Data, to out: inout Data) {
        appendVarint(field << 3 | 2, to: &out)
        appendVarint(UInt64(bytes.count), to: &out)
        out.append(bytes)
    }
}
