import Foundation

// MPEG-2 Transport Stream muxer (ISO/IEC 13818-1) for Wi-Fi Display.
//
// WFD carries media as a single-program TS inside RTP (payload type 33). PIDs follow
// the WFD spec: PMT 0x0100, video 0x1011, audio 0x1100. The PCR rides on the video
// PID (as GStreamer's mpegtsmux does for WFD), so the video stream must never stall -
// the frame pump re-sends the last frame when the screen is idle.
final class MPEGTSMuxer {

    static let packetSize = 188
    static let patPID: UInt16   = 0x0000
    static let pmtPID: UInt16   = 0x0100
    static let videoPID: UInt16 = 0x1011
    static let audioPID: UInt16 = 0x1100
    static let programNumber: UInt16 = 1

    static let streamTypeH264: UInt8 = 0x1B
    static let streamTypeHEVC: UInt8 = 0x24   // Miracast R2 Table 105
    static let streamTypeAAC: UInt8  = 0x0F   // ADTS
    static let streamTypeLPCM: UInt8 = 0x83   // WFD LPCM in private_stream_1

    enum AudioFormat { case aac, lpcm }

    let audio: AudioFormat?
    let videoStreamType: UInt8
    var hasAudio: Bool { audio != nil }
    private var continuity: [UInt16: UInt8] = [:]
    private var lastPSI: UInt64 = 0          // 90 kHz time PSI was last written
    private let psiInterval: UInt64 = 9000   // 100 ms
    private var lastPCR: UInt64?             // 27 MHz
    static let maxPCRGap: UInt64 = 27_000_000 / 25   // 40 ms (spec limit is 100 ms)

    init(audio: AudioFormat?, hevc: Bool = false) {
        self.audio = audio
        self.videoStreamType = hevc ? Self.streamTypeHEVC : Self.streamTypeH264
    }

    // MARK: - Public API

    // One access unit (Annex B with AUD/SPS/PPS as needed) -> TS packets.
    // pts90k: presentation time; pcr27M: current system clock (27 MHz units).
    func muxVideo(accessUnit: Data, pts90k: UInt64, pcr27M: UInt64, isKeyframe: Bool) -> [Data] {
        var out: [Data] = []
        let now90k = pcr27M / 300
        if isKeyframe || lastPSI == 0 || now90k &- lastPSI >= psiInterval {
            out.append(contentsOf: psiPackets())
            lastPSI = max(now90k, 1)
        }
        let pes = Self.pesPacket(streamID: 0xE0, pts90k: pts90k, payload: accessUnit, bounded: false)
        out.append(contentsOf: packetize(pid: Self.videoPID, pes: pes, pcr27M: pcr27M, randomAccess: isKeyframe))
        lastPCR = pcr27M
        return out
    }

    // One audio access unit (ADTS frame, or LPCM block incl. its 4-byte header) ->
    // TS packets. If video has stalled long enough that the PCR would go stale, a
    // PCR-only packet on the PCR PID goes first.
    func muxAudio(_ frame: Data, pts90k: UInt64, pcr27M: UInt64) -> [Data] {
        guard let audio else { return [] }
        var out: [Data] = []
        if let last = lastPCR, pcr27M &- last >= Self.maxPCRGap {
            out.append(pcrOnlyPacket(pcr27M))
            lastPCR = pcr27M
        }
        let streamID: UInt8 = audio == .aac ? 0xC0 : 0xBD
        let pes = Self.pesPacket(streamID: streamID, pts90k: pts90k, payload: frame, bounded: true)
        out.append(contentsOf: packetize(pid: Self.audioPID, pes: pes, pcr27M: nil, randomAccess: false))
        return out
    }

    // Adaptation-field-only packet carrying a PCR. No payload, so the continuity
    // counter repeats the last value rather than incrementing (13818-1 sec. 2.4.3.3).
    func pcrOnlyPacket(_ pcr27M: UInt64) -> Data {
        let pid = Self.videoPID
        var p = Data(capacity: Self.packetSize)
        p.append(0x47)
        p.append(UInt8((pid >> 8) & 0x1F))
        p.append(UInt8(pid & 0xFF))
        p.append(0x20 | (continuity[pid] ?? 0))
        p.append(183)                               // adaptation_field_length
        p.append(0x10)                              // PCR_flag
        p.append(contentsOf: Self.encodePCR(pcr27M))
        p.append(Data(repeating: 0xFF, count: Self.packetSize - p.count))
        return p
    }

    func psiPackets() -> [Data] {
        [psiPacket(pid: Self.patPID, section: patSection()),
         psiPacket(pid: Self.pmtPID, section: pmtSection())]
    }

    // MARK: - PES

    static func pesPacket(streamID: UInt8, pts90k: UInt64, payload: Data, bounded: Bool) -> Data {
        var pes = Data([0x00, 0x00, 0x01, streamID])
        let headerLen = 3 + 5                   // flags(2) + header_data_length(1) + PTS(5)
        let length = bounded && headerLen + payload.count <= 0xFFFF ? headerLen + payload.count : 0
        pes.appendBE(UInt16(length))
        pes.append(0x84)                        // '10' marker, data_alignment_indicator
        pes.append(0x80)                        // PTS only
        pes.append(0x05)
        pes.append(contentsOf: encodeTimestamp(pts90k, prefix: 0x2))
        pes.append(payload)
        return pes
    }

    static func encodeTimestamp(_ ts: UInt64, prefix: UInt8) -> [UInt8] {
        let t = ts & 0x1_FFFF_FFFF
        return [
            (prefix << 4) | UInt8((t >> 29) & 0x0E) | 0x01,
            UInt8((t >> 22) & 0xFF),
            UInt8((t >> 14) & 0xFE) | 0x01,
            UInt8((t >> 7) & 0xFF),
            UInt8((t << 1) & 0xFE) | 0x01,
        ]
    }

    static func decodeTimestamp(_ b: [UInt8]) -> UInt64 {
        (UInt64(b[0] & 0x0E) << 29) | (UInt64(b[1]) << 22) | (UInt64(b[2] & 0xFE) << 14)
            | (UInt64(b[3]) << 7) | (UInt64(b[4]) >> 1)
    }

    // 33-bit base (90 kHz) + 6 reserved bits + 9-bit extension (27 MHz remainder)
    static func encodePCR(_ pcr27M: UInt64) -> [UInt8] {
        let base = (pcr27M / 300) & 0x1_FFFF_FFFF
        let ext = pcr27M % 300
        return [
            UInt8((base >> 25) & 0xFF),
            UInt8((base >> 17) & 0xFF),
            UInt8((base >> 9) & 0xFF),
            UInt8((base >> 1) & 0xFF),
            UInt8((base & 0x01) << 7) | 0x7E | UInt8((ext >> 8) & 0x01),
            UInt8(ext & 0xFF),
        ]
    }

    // MARK: - TS packetization

    private func nextCC(_ pid: UInt16) -> UInt8 {
        let cc = (continuity[pid, default: 0x0F] &+ 1) & 0x0F
        continuity[pid] = cc
        return cc
    }

    private func packetize(pid: UInt16, pes: Data, pcr27M: UInt64?, randomAccess: Bool) -> [Data] {
        let bytes = [UInt8](pes)
        var packets: [Data] = []
        var offset = 0
        var first = true

        while offset < bytes.count {
            // Adaptation field contents after its length byte (nil = no adaptation field).
            var af: [UInt8]? = nil
            if first && (pcr27M != nil || randomAccess) {
                var flags: UInt8 = 0
                if randomAccess { flags |= 0x40 }
                if pcr27M != nil { flags |= 0x10 }
                af = [flags] + (pcr27M.map(Self.encodePCR) ?? [])
            }

            var room = 184 - (af.map { 1 + $0.count } ?? 0)
            let remaining = bytes.count - offset
            if remaining < room {
                let stuffing = room - remaining
                if var existing = af {
                    existing += [UInt8](repeating: 0xFF, count: stuffing)
                    af = existing
                } else if stuffing == 1 {
                    af = []                          // just the length byte (=0)
                } else {
                    af = [0x00] + [UInt8](repeating: 0xFF, count: stuffing - 2)
                }
                room = remaining
            }

            var p = Data(capacity: Self.packetSize)
            p.append(0x47)
            p.append((first ? 0x40 : 0x00) | UInt8((pid >> 8) & 0x1F))
            p.append(UInt8(pid & 0xFF))
            p.append((af != nil ? 0x30 : 0x10) | nextCC(pid))
            if let af {
                p.append(UInt8(af.count))
                p.append(contentsOf: af)
            }
            p.append(contentsOf: bytes[offset..<(offset + room)])
            assert(p.count == Self.packetSize)
            packets.append(p)

            offset += room
            first = false
        }
        return packets
    }

    private func psiPacket(pid: UInt16, section: [UInt8]) -> Data {
        var p = Data(capacity: Self.packetSize)
        p.append(0x47)
        p.append(0x40 | UInt8((pid >> 8) & 0x1F))
        p.append(UInt8(pid & 0xFF))
        p.append(0x10 | nextCC(pid))
        p.append(0x00)                           // pointer_field
        p.append(contentsOf: section)
        p.append(Data(repeating: 0xFF, count: Self.packetSize - p.count))
        return p
    }

    // MARK: - PSI sections

    private func patSection() -> [UInt8] {
        var s: [UInt8] = [0x00]                                   // table_id
        let body: [UInt8] = [
            0x00, 0x01,                                           // transport_stream_id
            0xC1,                                                 // version 0, current_next
            0x00, 0x00,                                           // section / last section
            UInt8(Self.programNumber >> 8), UInt8(Self.programNumber & 0xFF),
            0xE0 | UInt8(Self.pmtPID >> 8), UInt8(Self.pmtPID & 0xFF),
        ]
        let len = body.count + 4
        s += [0xB0 | UInt8(len >> 8), UInt8(len & 0xFF)]
        s += body
        return s + Self.crcBytes(s)
    }

    private func pmtSection() -> [UInt8] {
        var streams: [UInt8] = [
            videoStreamType, 0xE0 | UInt8(Self.videoPID >> 8), UInt8(Self.videoPID & 0xFF), 0xF0, 0x00,
        ]
        switch audio {
        case .aac:
            streams += [Self.streamTypeAAC, 0xE0 | UInt8(Self.audioPID >> 8), UInt8(Self.audioPID & 0xFF), 0xF0, 0x00]
        case .lpcm:
            // LPCM audio stream descriptor (tag 0x83): 48 kHz, stereo - as Android's WFD source sends it.
            streams += [Self.streamTypeLPCM, 0xE0 | UInt8(Self.audioPID >> 8), UInt8(Self.audioPID & 0xFF), 0xF0, 0x04,
                        0x83, 0x02, (2 << 5) | (3 << 1), (1 << 5) | 0x0F]
        case nil:
            break
        }
        let body: [UInt8] = [
            UInt8(Self.programNumber >> 8), UInt8(Self.programNumber & 0xFF),
            0xC1,
            0x00, 0x00,
            0xE0 | UInt8(Self.videoPID >> 8), UInt8(Self.videoPID & 0xFF),   // PCR_PID
            0xF0, 0x00,                                                       // program_info_length
        ] + streams
        let len = body.count + 4
        var s: [UInt8] = [0x02, 0xB0 | UInt8(len >> 8), UInt8(len & 0xFF)]
        s += body
        return s + Self.crcBytes(s)
    }

    private static func crcBytes(_ s: [UInt8]) -> [UInt8] {
        let c = crc32MPEG(s)
        return [UInt8(c >> 24), UInt8((c >> 16) & 0xFF), UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF)]
    }

    // CRC-32/MPEG-2: poly 0x04C11DB7, init 0xFFFFFFFF, no reflection, no final xor.
    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i) << 24
        for _ in 0..<8 { c = c & 0x8000_0000 != 0 ? (c << 1) ^ 0x04C1_1DB7 : c << 1 }
        return c
    }

    static func crc32MPEG<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes { crc = (crc << 8) ^ crcTable[Int(((crc >> 24) ^ UInt32(b)) & 0xFF)] }
        return crc
    }
}
