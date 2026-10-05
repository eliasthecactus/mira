import Foundation
import CoreMedia

// Turns VideoToolbox AVCC output into an Annex B access unit for MPEG-TS:
//   [AUD] [SPS PPS - keyframes only] [slice NALs...], each prefixed by 00 00 00 01.
// The access unit delimiter is required by the H.264-in-TS spec (ITU-T H.222.0
// sec. 2.14) and hardware decoders in sinks tend to rely on it.
enum H264Bitstream {

    static let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
    static let accessUnitDelimiter: [UInt8] = [0x09, 0xF0]   // NAL type 9, primary_pic_type = any

    static func accessUnit(from sampleBuffer: CMSampleBuffer, isKeyframe: Bool) -> Data? {
        let nalus = extractNALUs(from: sampleBuffer).filter { ($0.first ?? 0) & 0x1F != 9 }
        guard !nalus.isEmpty else { return nil }
        var parameterSets: [Data] = []
        if isKeyframe, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            parameterSets = extractParameterSets(from: fmt)
        }
        return annexB(nalus: nalus, parameterSets: parameterSets)
    }

    static func annexB(nalus: [Data], parameterSets: [Data]) -> Data {
        var out = Data(startCode + accessUnitDelimiter)
        for ps in parameterSets {
            out.append(contentsOf: startCode)
            out.append(markConstrained(ps))
        }
        for n in nalus {
            out.append(contentsOf: startCode)
            out.append(n)
        }
        return out
    }

    // WFD signals Constrained Baseline / Constrained High. VideoToolbox's output already
    // meets those constraints (no FMO/ASO/redundant slices; progressive; no B-frames
    // because frame reordering is off) but its SPS doesn't always say so:
    //   Baseline (66): set constraint_set0/1   -> Constrained Baseline
    //   High (100):    set constraint_set4/5   -> Constrained High
    static func markConstrained(_ nal: Data) -> Data {
        var b = [UInt8](nal)
        guard b.count >= 4, b[0] & 0x1F == 7 else { return nal }
        switch b[1] {
        case 66:  b[2] |= 0xC0
        case 100: b[2] |= 0x0C
        default:  return nal
        }
        return Data(b)
    }

    // AVCC: [4-byte big-endian length][NAL] ...
    static func extractNALUs(from sampleBuffer: CMSampleBuffer) -> [Data] {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return [] }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        var contiguous = block
        if !CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: 0) {
            var copy: CMBlockBuffer?
            guard CMBlockBufferCreateContiguous(allocator: nil, sourceBuffer: block, blockAllocator: nil,
                                                customBlockSource: nil, offsetToData: 0, dataLength: 0,
                                                flags: 0, blockBufferOut: &copy) == kCMBlockBufferNoErr,
                  let copy else { return [] }
            contiguous = copy
        }
        guard CMBlockBufferGetDataPointer(contiguous, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
              let ptr = dataPointer else { return [] }
        return splitAVCC(UnsafeRawBufferPointer(start: ptr, count: totalLength))
    }

    static func splitAVCC(_ bytes: UnsafeRawBufferPointer) -> [Data] {
        var nalus: [Data] = []
        var offset = 0
        while offset + 4 <= bytes.count {
            let len = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                    | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard len > 0, offset + len <= bytes.count else { break }
            nalus.append(Data(bytes[offset..<(offset + len)]))
            offset += len
        }
        return nalus
    }

    static func extractParameterSets(from formatDescription: CMFormatDescription) -> [Data] {
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)

        var sets: [Data] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription, parameterSetIndex: i,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if status == noErr, let ptr, size > 0 {
                sets.append(Data(bytes: ptr, count: size))
            }
        }
        return sets
    }
}
