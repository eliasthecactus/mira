import Foundation
import CoreMedia
import VideoToolbox

// Converts VideoToolbox AVCC output to raw NAL units suitable for RTP.
// AVCC format: [4-byte big-endian length][NAL data][4-byte length][NAL data]...
// We extract each NAL unit as a separate Data blob (no start codes needed for RFC 6184 RTP).
enum AnnexBConverter {
    static func extractNALUs(from sampleBuffer: CMSampleBuffer) -> [Data] {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return [] }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(block, atOffset: 0,
                                                  lengthAtOffsetOut: nil,
                                                  totalLengthOut: &totalLength,
                                                  dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let ptr = dataPointer else { return [] }

        var nalus: [Data] = []
        var offset = 0
        let bytes = UnsafeRawPointer(ptr)

        while offset + 4 <= totalLength {
            let lengthBytes = bytes.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            let naluLength = (Int(lengthBytes[0]) << 24)
                           | (Int(lengthBytes[1]) << 16)
                           | (Int(lengthBytes[2]) << 8)
                           |  Int(lengthBytes[3])
            offset += 4
            guard offset + naluLength <= totalLength, naluLength > 0 else { break }
            let nalu = Data(bytes: bytes.advanced(by: offset), count: naluLength)
            nalus.append(nalu)
            offset += naluLength
        }
        return nalus
    }

    // Extract SPS and PPS from the format description (needed before the first IDR frame)
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

    // Build Annex B byte stream (for debugging / non-RTP use)
    static func annexB(from nalus: [Data]) -> Data {
        let startCode = Data([0x00, 0x00, 0x00, 0x01])
        return nalus.reduce(Data()) { $0 + startCode + $1 }
    }
}
