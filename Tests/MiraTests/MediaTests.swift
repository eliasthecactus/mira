import XCTest
@testable import Mira

final class MPEGTSMuxerTests: XCTestCase {

    // Minimal demuxer for assertions: PID → reassembled PES payloads, plus CC check.
    struct Demuxed {
        var pes: [UInt16: [Data]] = [:]
        var pcrs: [UInt64] = []
        var randomAccess = 0
    }

    func demux(_ packets: [Data], file: StaticString = #filePath, line: UInt = #line) -> Demuxed {
        var out = Demuxed()
        var current: [UInt16: Data] = [:]
        var lastCC: [UInt16: UInt8] = [:]
        for p in packets {
            let b = [UInt8](p)
            XCTAssertEqual(b.count, 188, file: file, line: line)
            XCTAssertEqual(b[0], 0x47, file: file, line: line)
            let pusi = b[1] & 0x40 != 0
            let pid = UInt16(b[1] & 0x1F) << 8 | UInt16(b[2])
            let afc = (b[3] >> 4) & 3
            let cc = b[3] & 0x0F
            XCTAssertNotEqual(afc, 0, "reserved adaptation_field_control", file: file, line: line)
            XCTAssertEqual(b[3] & 0xC0, 0, "transport_scrambling_control must be 0", file: file, line: line)
            if afc & 1 != 0 {
                if let prev = lastCC[pid] { XCTAssertEqual(cc, (prev + 1) & 0x0F, "CC on PID \(pid)", file: file, line: line) }
                lastCC[pid] = cc
            }
            var i = 4
            if afc & 2 != 0 {
                let len = Int(b[4])
                if len > 0 {
                    if b[5] & 0x40 != 0 { out.randomAccess += 1 }
                    if b[5] & 0x10 != 0 {
                        let base = UInt64(b[6]) << 25 | UInt64(b[7]) << 17 | UInt64(b[8]) << 9 | UInt64(b[9]) << 1 | UInt64(b[10] >> 7)
                        let ext = UInt64(b[10] & 1) << 8 | UInt64(b[11])
                        out.pcrs.append(base * 300 + ext)
                    }
                }
                i = 5 + len
                guard i <= 188 else { XCTFail("adaptation field overruns packet", file: file, line: line); continue }
            }
            guard afc & 1 != 0, pid != 0, pid != MPEGTSMuxer.pmtPID else { continue }
            if pusi, let done = current[pid] { out.pes[pid, default: []].append(done); current[pid] = nil }
            current[pid, default: Data()].append(contentsOf: b[i...])
        }
        for (pid, d) in current { out.pes[pid, default: []].append(d) }
        return out
    }

    func testCRC32MPEGCheckValue() {
        XCTAssertEqual(MPEGTSMuxer.crc32MPEG(Array("123456789".utf8)), 0x0376_E6E7)
    }

    func testPSIHasValidCRC() {
        let psi = MPEGTSMuxer(audio: .aac).psiPackets()
        XCTAssertEqual(psi.count, 2)
        for p in psi {
            let b = [UInt8](p)
            let sectionStart = 5                                  // header + pointer_field
            let sectionLength = Int(b[sectionStart + 1] & 0x0F) << 8 | Int(b[sectionStart + 2])
            let section = Array(b[sectionStart..<(sectionStart + 3 + sectionLength)])
            XCTAssertEqual(MPEGTSMuxer.crc32MPEG(section), 0, "CRC over section incl. CRC must be 0")
        }
    }

    func testVideoRoundTripAllSizes() {
        // Sizes chosen to hit every stuffing edge case (0, 1, 2 bytes short etc.).
        let mux = MPEGTSMuxer(audio: nil)
        var packets: [Data] = []
        var payloads: [Data] = []
        for size in [1, 100, 157, 158, 159, 160, 161, 170, 182, 183, 184, 185, 340, 341, 342, 5000] {
            let au = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ size) })
            payloads.append(au)
            packets += mux.muxVideo(accessUnit: au, pts90k: UInt64(size) * 3000, pcr27M: UInt64(size) * 900_000, isKeyframe: size == 1)
        }
        let d = demux(packets)
        let video = d.pes[MPEGTSMuxer.videoPID] ?? []
        XCTAssertEqual(video.count, payloads.count)
        for (pes, expected) in zip(video, payloads) {
            let b = [UInt8](pes)
            XCTAssertEqual(Array(b[0..<4]), [0, 0, 1, 0xE0])
            XCTAssertEqual(b[7], 0x80, "PTS only")
            let headerEnd = 9 + Int(b[8])
            XCTAssertEqual(Data(b[headerEnd...]), expected)
        }
        XCTAssertEqual(d.pcrs.count, payloads.count, "PCR on every video PES")
        XCTAssertEqual(d.randomAccess, 1)
    }

    func testContinuityCounterWrapsWithoutCorruptingHeader() {
        // Regression: `x &+ 1 & 0x0F` parsed as `x &+ (1 & 0x0F)` and leaked into AFC bits.
        let mux = MPEGTSMuxer(audio: nil)
        var packets: [Data] = []
        var payloads: [Data] = []
        for i in 0..<40 {
            let au = Data((0..<1000).map { UInt8(truncatingIfNeeded: $0 &+ i) })
            payloads.append(au)
            packets += mux.muxVideo(accessUnit: au, pts90k: UInt64(i) * 3000,
                                    pcr27M: UInt64(i) * 900_000, isKeyframe: false)
        }
        let video = demux(packets).pes[MPEGTSMuxer.videoPID] ?? []
        XCTAssertEqual(video.count, payloads.count)
        for (pes, expected) in zip(video, payloads) {
            let b = [UInt8](pes)
            XCTAssertEqual(Data(b[(9 + Int(b[8]))...]), expected)
        }
    }

    func testTimestampAndPCREncoding() {
        for ts: UInt64 in [0, 1, 90_000, 0x1_FFFF_FFFF, 8_589_934_591 / 3] {
            XCTAssertEqual(MPEGTSMuxer.decodeTimestamp(MPEGTSMuxer.encodeTimestamp(ts, prefix: 2)), ts)
        }
        let pcr: UInt64 = 27_000_000 * 3600 + 299
        let b = MPEGTSMuxer.encodePCR(pcr)
        let base = UInt64(b[0]) << 25 | UInt64(b[1]) << 17 | UInt64(b[2]) << 9 | UInt64(b[3]) << 1 | UInt64(b[4] >> 7)
        let ext = UInt64(b[4] & 1) << 8 | UInt64(b[5])
        XCTAssertEqual(base * 300 + ext, pcr)
        XCTAssertEqual(b[4] & 0x7E, 0x7E, "reserved bits set")
    }

    func testAudioPESIsBounded() {
        let mux = MPEGTSMuxer(audio: .aac)
        let adts = Data(AACEncoder.adtsHeader(payloadLength: 300)) + Data(repeating: 0x11, count: 300)
        let d = demux(mux.muxAudio(adts, pts90k: 1234, pcr27M: 0))
        let pes = [UInt8](d.pes[MPEGTSMuxer.audioPID]![0])
        XCTAssertEqual(Array(pes[0..<4]), [0, 0, 1, 0xC0])
        let length = Int(pes[4]) << 8 | Int(pes[5])
        XCTAssertEqual(length, 3 + 5 + adts.count)
    }
}

extension MPEGTSMuxerTests {
    func testAudioInsertsPCROnlyPacketWhenVideoStalls() {
        let mux = MPEGTSMuxer(audio: .aac)
        let adts = Data(AACEncoder.adtsHeader(payloadLength: 10)) + Data(repeating: 0, count: 10)
        var packets = mux.muxVideo(accessUnit: Data([1, 2, 3]), pts90k: 0, pcr27M: 27_000_000, isKeyframe: true)
        let soon = mux.muxAudio(adts, pts90k: 0, pcr27M: 27_000_000 + 27_000 * 20)    // +20 ms
        let late = mux.muxAudio(adts, pts90k: 0, pcr27M: 27_000_000 + 27_000 * 50)    // +50 ms
        XCTAssertEqual(soon.count, 1, "no PCR packet needed yet")
        XCTAssertEqual(late.count, 2)
        let pcrPacket = [UInt8](late[0])
        XCTAssertEqual(UInt16(pcrPacket[1] & 0x1F) << 8 | UInt16(pcrPacket[2]), MPEGTSMuxer.videoPID)
        XCTAssertEqual(pcrPacket[3] & 0x30, 0x20, "adaptation field only")
        packets += soon + late + mux.muxVideo(accessUnit: Data([4]), pts90k: 0, pcr27M: 27_000_000 * 2, isKeyframe: false)
        let d = demux(packets)   // CC must stay continuous across the payload-less packet
        let expected: [UInt64] = [27_000_000, 27_000_000 + 27_000 * 50, 27_000_000 * 2]
        XCTAssertEqual(d.pcrs, expected)
    }
}

final class RTPMP2TPacketizerTests: XCTestCase {

    func testSevenTSPacketsPerRTPAndFlush() {
        let p = RTPMP2TPacketizer(ssrc: 0xDEADBEEF, initialSequence: 0xFFFF)
        let ts = (0..<10).map { _ in Data(repeating: 0x47, count: 188) }

        let full = p.packetize(tsPackets: ts, rtpTimestamp: 90_000, flush: false)
        XCTAssertEqual(full.count, 1)
        XCTAssertEqual(full[0].count, 12 + 7 * 188)
        let h = [UInt8](full[0])
        XCTAssertEqual(h[0], 0x80)
        XCTAssertEqual(h[1], 33)
        XCTAssertEqual(UInt16(h[2]) << 8 | UInt16(h[3]), 0xFFFF)
        XCTAssertEqual(Array(h[8..<12]), [0xDE, 0xAD, 0xBE, 0xEF])

        let rest = p.packetize(tsPackets: [], rtpTimestamp: 93_000, flush: true)
        XCTAssertEqual(rest.count, 1)
        XCTAssertEqual(rest[0].count, 12 + 3 * 188)
        XCTAssertEqual(UInt16(rest[0][2]) << 8 | UInt16(rest[0][3]), 0, "sequence wraps")
        XCTAssertEqual(p.packetCount, 2)
    }
}

final class BitstreamTests: XCTestCase {

    func testAnnexBAccessUnitHasAUDAndParameterSets() {
        let sps = Data([0x67, 66, 0x00, 0x28, 0xAA])
        let pps = Data([0x68, 0xCE, 0x38, 0x80])
        let idr = Data([0x65, 0x88, 0x84])
        let au = [UInt8](H264Bitstream.annexB(nalus: [idr], parameterSets: [sps, pps]))
        XCTAssertEqual(Array(au[0..<6]), [0, 0, 0, 1, 0x09, 0xF0])
        XCTAssertEqual(Array(au[6..<11]), [0, 0, 0, 1, 0x67])
        XCTAssertEqual(au[12], 0xC0, "constraint_set0/1 flags set on baseline SPS")
    }

    func testConstrainedFlags() {
        XCTAssertEqual(H264Bitstream.markConstrained(Data([0x67, 100, 0x00, 0x33])), Data([0x67, 100, 0x0C, 0x33]),
                       "High → Constrained High (constraint_set4/5)")
        let main = Data([0x67, 77, 0x00, 0x28])
        XCTAssertEqual(H264Bitstream.markConstrained(main), main, "other profiles untouched")
        let pps = Data([0x68, 66, 0x00])
        XCTAssertEqual(H264Bitstream.markConstrained(pps), pps)
    }

    func testSplitAVCC() {
        let avcc: [UInt8] = [0, 0, 0, 2, 0x09, 0xF0, 0, 0, 0, 3, 0x65, 1, 2]
        let nalus = avcc.withUnsafeBytes { H264Bitstream.splitAVCC($0) }
        XCTAssertEqual(nalus, [Data([0x09, 0xF0]), Data([0x65, 1, 2])])
    }

    func testADTSHeader() {
        let h = AACEncoder.adtsHeader(payloadLength: 371)
        XCTAssertEqual(h.count, 7)
        XCTAssertEqual(h[0], 0xFF)
        XCTAssertEqual(h[1], 0xF1)
        XCTAssertEqual((h[2] >> 6) & 3, 1, "AAC LC")
        XCTAssertEqual((h[2] >> 2) & 0xF, 3, "48 kHz")
        let channels = (h[2] & 1) << 2 | h[3] >> 6
        XCTAssertEqual(channels, 2)
        let length = Int(h[3] & 3) << 11 | Int(h[4]) << 3 | Int(h[5] >> 5)
        XCTAssertEqual(length, 378)
    }

    func testAACEncoderProducesTimedADTSFrames() throws {
        let enc = try AACEncoder()
        var frames: [(Data, Double)] = []
        enc.onEncoded = { frames.append(($0, $1)) }
        let block = [Float](repeating: 0.1, count: 480 * 2)
        for i in 0..<200 { enc.encode(interleaved: block, pts: 100 + Double(i) * 0.01) }  // 2 s
        XCTAssertGreaterThan(frames.count, 85)
        for (adts, _) in frames { XCTAssertEqual(adts.prefix(2), Data([0xFF, 0xF1])) }
        // Consecutive frames are 1024 samples apart.
        let deltas = zip(frames.dropFirst(), frames).map { $0.1 - $1.1 }
        for d in deltas { XCTAssertEqual(d, 1024.0 / 48_000, accuracy: 1e-9) }
        XCTAssertEqual(frames[0].1, 100 - 64.0 / 48_000, accuracy: 1e-9, "first emitted frame ≈ timeline start")
    }
}

final class LPCMTests: XCTestCase {

    func testPESLayoutByteOrderAndTiming() {
        let enc = LPCMEncoder()
        var out: [(Data, Double)] = []
        enc.onEncoded = { out.append(($0, $1)) }
        // 25 ms of a ramp: 1200 frames → two full 480-frame PES, 240 frames held back.
        let samples = (0..<1200).flatMap { i -> [Float] in [Float(i) / 2000, -0.5] }
        enc.encode(interleaved: samples, pts: 10)
        XCTAssertEqual(out.count, 2)
        let first = [UInt8](out[0].0)
        XCTAssertEqual(Array(first[0..<4]), [0xA0, 0x06, 0x00, 0x11])
        XCTAssertEqual(first.count, 4 + 480 * 4)
        // Frame 1: L = 1/2000 * 32767 = 16 → 0x0010 big-endian; R = -0.5 → -16383 = 0xC001
        XCTAssertEqual(Array(first[8..<12]), [0x00, 0x10, 0xC0, 0x01])
        XCTAssertEqual(out[0].1, 10, accuracy: 1e-9)
        XCTAssertEqual(out[1].1, 10.01, accuracy: 1e-9)
    }

    func testClipsOutOfRangeSamples() {
        let enc = LPCMEncoder()
        var frame = Data()
        enc.onEncoded = { d, _ in if frame.isEmpty { frame = d } }
        enc.encode(interleaved: [Float](repeating: 3, count: 960), pts: 0)
        XCTAssertEqual(Array(frame[4..<6]), [0x7F, 0xFF])
    }

    func testPMTCarriesLPCMDescriptorWithValidCRC() {
        let pmt = [UInt8](MPEGTSMuxer(audio: .lpcm).psiPackets()[1])
        let len = Int(pmt[6] & 0x0F) << 8 | Int(pmt[7])
        let section = Array(pmt[5..<(8 + len)])
        XCTAssertEqual(MPEGTSMuxer.crc32MPEG(section), 0)
        let bytes = Data(section)
        XCTAssertNotNil(bytes.range(of: Data([0x83, 0xF1, 0x00, 0xF0, 0x04, 0x83, 0x02, 0x46, 0x2F])),
                        "stream_type 0x83 on PID 0x1100 with LPCM descriptor (48 kHz, stereo)")
    }

    func testLPCMUsesPrivateStream1() {
        let mux = MPEGTSMuxer(audio: .lpcm)
        let pkt = [UInt8](mux.muxAudio(Data(LPCMEncoder.header) + Data(count: 1920), pts90k: 0, pcr27M: 0)[0])
        XCTAssertEqual(Array(pkt[4..<8]), [0, 0, 1, 0xBD])
    }
}
