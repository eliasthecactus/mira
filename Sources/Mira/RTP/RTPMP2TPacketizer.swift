import Foundation

// RFC 2250: MPEG-2 Transport Stream over RTP (payload type 33, 90 kHz clock).
// Wi-Fi Display requires this encapsulation. Up to 7 TS packets (1316 bytes) go in
// one RTP packet so the datagram stays under a 1500-byte Ethernet/Wi-Fi MTU.
final class RTPMP2TPacketizer {

    static let payloadType: UInt8 = 33
    static let tsPacketsPerRTP = 7

    let ssrc: UInt32
    private(set) var sequenceNumber: UInt16
    private(set) var packetCount: UInt32 = 0
    private(set) var octetCount: UInt32 = 0
    private var pending: [Data] = []

    init(ssrc: UInt32 = .random(in: 1...UInt32.max), initialSequence: UInt16 = .random(in: 0...UInt16.max)) {
        self.ssrc = ssrc
        self.sequenceNumber = initialSequence
    }

    // Queues TS packets and returns every full RTP packet. With `flush`, a final
    // partial RTP packet is emitted too (done at the end of each access unit so a
    // frame never waits for the next one).
    func packetize(tsPackets: [Data], rtpTimestamp: UInt32, flush: Bool) -> [Data] {
        pending.append(contentsOf: tsPackets)
        var out: [Data] = []
        while pending.count >= Self.tsPacketsPerRTP || (flush && !pending.isEmpty) {
            let n = min(Self.tsPacketsPerRTP, pending.count)
            var packet = header(timestamp: rtpTimestamp)
            for ts in pending.prefix(n) { packet.append(ts) }
            pending.removeFirst(n)
            packetCount &+= 1
            octetCount &+= UInt32(packet.count - 12)
            out.append(packet)
        }
        return out
    }

    private func header(timestamp: UInt32) -> Data {
        let seq = sequenceNumber
        sequenceNumber &+= 1
        var h = Data(capacity: 12 + 188 * Self.tsPacketsPerRTP)
        h.append(0x80)                          // V=2
        h.append(Self.payloadType)              // M=0
        h.appendBE(seq)
        h.appendBE(timestamp)
        h.appendBE(ssrc)
        return h
    }
}
