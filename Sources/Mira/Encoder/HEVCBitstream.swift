import Foundation
import CoreMedia

// HEVC counterpart of H264Bitstream: VideoToolbox hvcC output -> Annex B access unit
//   [AUD] [VPS SPS PPS - keyframes only] [slice NALs...]
// HEVC NAL header is two bytes; the type is bits 6..1 of the first byte.
enum HEVCBitstream {

    // NAL type 35 (AUD), layer 0, temporal id 1; pic_type = 2 (I, P or B) + stop bit.
    static let accessUnitDelimiter: [UInt8] = [0x46, 0x01, 0x50]

    static func nalType(_ nal: Data) -> UInt8 { ((nal.first ?? 0) >> 1) & 0x3F }

    static func accessUnit(from sampleBuffer: CMSampleBuffer, isKeyframe: Bool) -> Data? {
        let nalus = H264Bitstream.extractNALUs(from: sampleBuffer).filter { nalType($0) != 35 }
        guard !nalus.isEmpty else { return nil }
        var parameterSets: [Data] = []
        if isKeyframe, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            parameterSets = extractParameterSets(from: fmt)
        }
        return annexB(nalus: nalus, parameterSets: parameterSets)
    }

    static func annexB(nalus: [Data], parameterSets: [Data]) -> Data {
        var out = Data(H264Bitstream.startCode + accessUnitDelimiter)
        // If VideoToolbox also put VPS/SPS/PPS in-band, send only ours (once, in order).
        let slices = parameterSets.isEmpty ? nalus : nalus.filter { !(32...34).contains(nalType($0)) }
        for nal in parameterSets + slices {
            out.append(contentsOf: H264Bitstream.startCode)
            out.append(nal)
        }
        return out
    }

    static func extractParameterSets(from formatDescription: CMFormatDescription) -> [Data] {
        var count = 0
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        var sets: [Data] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription, parameterSetIndex: i,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if status == noErr, let ptr, size > 0 { sets.append(Data(bytes: ptr, count: size)) }
        }
        return sets
    }
}
