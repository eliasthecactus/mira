import Foundation

// RFC 6184: RTP Payload Format for H.264 Video
// Supports single NAL unit packets and FU-A fragmentation.
final class RTPPacketizer {

    // Dynamic payload type 97 for H.264
    static let payloadTypeH264: UInt8 = 97
    static let mtu = 1400   // safe max RTP payload size (UDP MTU 1500 - 40 headers)

    private var ssrc: UInt32
    private var sequenceNumber: UInt16 = 0
    private var timestampOffset: UInt32

    init(ssrc: UInt32 = .random(in: 0...UInt32.max)) {
        self.ssrc = ssrc
        self.timestampOffset = .random(in: 0...UInt32.max)
    }

    // Packetize a list of NAL units belonging to one video frame.
    // pts90k: presentation timestamp in 90 kHz units.
    // isLastFrame: set M bit on the final packet of each frame.
    func packetize(nalus: [Data], pts90k: UInt32, isKeyframe: Bool) -> [Data] {
        let timestamp = timestampOffset &+ pts90k
        var packets: [Data] = []

        for (idx, nalu) in nalus.enumerated() {
            let isLast = (idx == nalus.count - 1)
            if nalu.count <= RTPPacketizer.mtu {
                // Single NAL unit packet
                packets.append(makeSinglePacket(nalu: nalu, timestamp: timestamp, marker: isLast))
            } else {
                // FU-A fragmentation
                let fragments = makeFUA(nalu: nalu, timestamp: timestamp, isLast: isLast)
                packets.append(contentsOf: fragments)
            }
        }
        return packets
    }

    // MARK: - RTP header

    private func rtpHeader(marker: Bool, timestamp: UInt32) -> Data {
        let seq = nextSeq()
        var h = Data(count: 12)
        h[0]  = 0x80                                      // V=2, P=0, X=0, CC=0
        h[1]  = (marker ? 0x80 : 0x00) | RTPPacketizer.payloadTypeH264
        h[2]  = UInt8(seq >> 8)
        h[3]  = UInt8(seq & 0xFF)
        h[4]  = UInt8((timestamp >> 24) & 0xFF)
        h[5]  = UInt8((timestamp >> 16) & 0xFF)
        h[6]  = UInt8((timestamp >>  8) & 0xFF)
        h[7]  = UInt8( timestamp        & 0xFF)
        h[8]  = UInt8((ssrc >> 24) & 0xFF)
        h[9]  = UInt8((ssrc >> 16) & 0xFF)
        h[10] = UInt8((ssrc >>  8) & 0xFF)
        h[11] = UInt8( ssrc        & 0xFF)
        return h
    }

    private func nextSeq() -> UInt16 {
        let s = sequenceNumber
        sequenceNumber = sequenceNumber &+ 1
        return s
    }

    // MARK: - Single NAL unit packet (Section 5.6)

    private func makeSinglePacket(nalu: Data, timestamp: UInt32, marker: Bool) -> Data {
        rtpHeader(marker: marker, timestamp: timestamp) + nalu
    }

    // MARK: - FU-A (Section 5.8)

    private func makeFUA(nalu: Data, timestamp: UInt32, isLast: Bool) -> [Data] {
        guard nalu.count > 1 else { return [] }

        let naluHeader = nalu[0]
        let nalType    = naluHeader & 0x1F
        let nri        = naluHeader & 0x60      // NRI bits from original header
        let fuIndicator: UInt8 = nri | 28       // FU-A NAL type = 28

        let payload = nalu.dropFirst()          // skip original NAL header
        let maxChunk = RTPPacketizer.mtu - 2    // 1 FU indicator + 1 FU header

        var chunks: [Data] = []
        var offset = payload.startIndex

        while offset < payload.endIndex {
            let end = min(payload.index(offset, offsetBy: maxChunk), payload.endIndex)
            let chunk = payload[offset..<end]
            let isFirst = (offset == payload.startIndex)
            let isLastChunk = (end == payload.endIndex) && isLast

            var fuHeader: UInt8 = nalType
            if isFirst { fuHeader |= 0x80 }     // S bit
            if end == payload.endIndex { fuHeader |= 0x40 }  // E bit (last fragment of this NAL)

            var packet = rtpHeader(marker: isLastChunk, timestamp: timestamp)
            packet.append(fuIndicator)
            packet.append(fuHeader)
            packet.append(contentsOf: chunk)
            chunks.append(packet)

            offset = end
        }
        return chunks
    }
}
