import Foundation

// Wi-Fi Display parameter handling: parse the sink's capabilities (M3 response),
// choose a stream format, and render the M4 SET_PARAMETER body.

// MARK: - text/parameters bodies

enum WFDParameters {
    // "name: value" lines -> dictionary (names lowercased; WFD names are case-insensitive in practice).
    static func parse(_ body: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                out[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            } else {
                out[line.lowercased()] = ""
            }
        }
        return out
    }

    static func names(in body: String) -> [String] {
        body.components(separatedBy: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            return line.split(separator: ":", maxSplits: 1).first.map { String($0).trimmingCharacters(in: .whitespaces) }
        }
    }
}

// MARK: - Video

// Which capability parameter a format came from. The resolution numbering above
// index 16 differs between them, so entries remember their origin.
enum WFDFormatFlavor: String {
    case r1 = "wfd_video_formats"       // Wi-Fi Display R1 (H.264 only, 32-bit bitmaps)
    case r2 = "wfd2_video_formats"      // Miracast R2 (H.264 + H.265, 48-bit bitmaps)
    case wfdx = "wfdx_video_formats"    // [MS-WFDPE] (Windows 10 v1511 only, 40-bit bitmaps)
}

enum VideoCodec: String {
    case h264 = "H.264"
    case h265 = "H.265"
}

// H.264 profile actually produced. R1 "Constrained High" forbids CABAC; R2 "RHP2"
// is the same profile with CABAC allowed.
enum H264Profile: String {
    case constrainedBaseline = "Constrained Baseline"
    case constrainedHigh = "Constrained High"
    case restrictedHigh2 = "Restricted High 2 (CABAC)"
}

struct WFDResolution: Equatable, CustomStringConvertible {
    enum Table: Int { case cea = 0, vesa = 1, hh = 2 }
    let width: Int
    let height: Int
    let fps: Int
    let table: Table
    let bit: Int            // bit index in the table's support bitmap

    var description: String { "\(width)x\(height)p\(fps)" }
    var is4K: Bool { width >= 3840 }

    // Lowest H.264 level (as WFD level bit) that can carry this resolution/frame rate.
    // Bits: 0x01=3.1, 0x02=3.2, 0x04=4, 0x08=4.1, 0x10=4.2, 0x20=5, 0x40=5.1, 0x80=5.2.
    var requiredLevelBit: UInt8 {
        let macroblocksPerSecond = ((width + 15) / 16) * ((height + 15) / 16) * fps
        switch macroblocksPerSecond {
        case ...108_000: return 0x01
        case ...216_000: return 0x02
        case ...245_760: return 0x04
        case ...522_240: return 0x10
        case ...589_824: return 0x20
        case ...983_040: return 0x40
        default:         return 0x80
        }
    }

    // Lowest H.265 level, as the Miracast R2 bit (Table 78):
    // 0x01=3.1, 0x02=4, 0x04=4.1, 0x08=5, 0x10=5.1 (H.265 Annex A luma sample rates).
    var requiredH265LevelBit: UInt16 {
        let picture = width * height
        let rate = picture * fps
        if picture <= 983_040 && rate <= 33_177_600 { return 0x01 }
        if picture <= 2_228_224 && rate <= 66_846_720 { return 0x02 }
        if picture <= 2_228_224 && rate <= 133_693_440 { return 0x04 }
        if rate <= 267_386_880 { return 0x08 }
        return 0x10
    }

    // R1 CEA table (Miracast Table 34): bits 0-16; bits above are reserved in R1.
    static let cea: [WFDResolution] = [
        .init(width: 640,  height: 480,  fps: 60, table: .cea, bit: 0),
        .init(width: 720,  height: 480,  fps: 60, table: .cea, bit: 1),
        .init(width: 720,  height: 576,  fps: 50, table: .cea, bit: 3),
        .init(width: 1280, height: 720,  fps: 30, table: .cea, bit: 5),
        .init(width: 1280, height: 720,  fps: 60, table: .cea, bit: 6),
        .init(width: 1920, height: 1080, fps: 30, table: .cea, bit: 7),
        .init(width: 1920, height: 1080, fps: 60, table: .cea, bit: 8),
        .init(width: 1280, height: 720,  fps: 25, table: .cea, bit: 10),
        .init(width: 1280, height: 720,  fps: 50, table: .cea, bit: 11),
        .init(width: 1920, height: 1080, fps: 25, table: .cea, bit: 12),
        .init(width: 1920, height: 1080, fps: 50, table: .cea, bit: 13),
        .init(width: 1280, height: 720,  fps: 24, table: .cea, bit: 15),
        .init(width: 1920, height: 1080, fps: 24, table: .cea, bit: 16),
    ]

    // 4K extension, Miracast R2 numbering (Table 71).
    static let ceaR2Extension: [WFDResolution] = [
        .init(width: 3840, height: 2160, fps: 24, table: .cea, bit: 17),
        .init(width: 3840, height: 2160, fps: 25, table: .cea, bit: 18),
        .init(width: 3840, height: 2160, fps: 30, table: .cea, bit: 19),
        .init(width: 3840, height: 2160, fps: 50, table: .cea, bit: 20),
        .init(width: 3840, height: 2160, fps: 60, table: .cea, bit: 21),
    ]

    // 4K extension, [MS-WFDPE] 2.7.1.1.1 numbering (different order!).
    static let ceaWfdxExtension: [WFDResolution] = [
        .init(width: 3840, height: 2160, fps: 30, table: .cea, bit: 17),
        .init(width: 3840, height: 2160, fps: 60, table: .cea, bit: 18),
        .init(width: 3840, height: 2160, fps: 25, table: .cea, bit: 21),
        .init(width: 3840, height: 2160, fps: 50, table: .cea, bit: 22),
        .init(width: 3840, height: 2160, fps: 24, table: .cea, bit: 25),
    ]

    static func table(for flavor: WFDFormatFlavor) -> [WFDResolution] {
        switch flavor {
        case .r1: return cea
        case .r2: return cea + ceaR2Extension
        case .wfdx: return cea + ceaWfdxExtension
        }
    }

    // Mandatory for every WFD sink.
    static let mandatory = cea[0]

    static func find(width: Int, height: Int, fps: Int, flavor: WFDFormatFlavor = .r2) -> WFDResolution? {
        table(for: flavor).first { $0.width == width && $0.height == height && $0.fps == fps }
    }

    static func cea(width: Int, height: Int, fps: Int) -> WFDResolution? {
        find(width: width, height: height, fps: fps, flavor: .r2)
    }
}

// One codec entry from the sink's capabilities, normalised across the three flavors.
struct WFDVideoCodecEntry: Equatable {
    var codec: VideoCodec
    var flavor: WFDFormatFlavor
    var profile: UInt16           // bitmap in the flavor's numbering
    var level: UInt16             // bitmap in the flavor's numbering
    var ceaSupport: UInt64
    var vesaSupport: UInt64
    var hhSupport: UInt64
    var latency: UInt8 = 0
    var minSliceSize: UInt16 = 0
    var sliceEncParams: UInt16 = 0
    var frameRateControl: UInt8 = 0

    func supports(_ r: WFDResolution) -> Bool {
        guard WFDResolution.table(for: flavor).contains(r) else { return false }
        let map: UInt64
        switch r.table {
        case .cea: map = ceaSupport
        case .vesa: map = vesaSupport
        case .hh: map = hhSupport
        }
        return map & (UInt64(1) << UInt64(r.bit)) != 0
    }

    // Highest level bit set (sinks report the maximum level).
    var maxLevelBit: UInt16 {
        var bit: UInt16 = 0x8000
        while bit > 0 { if level & bit != 0 { return bit }; bit >>= 1 }
        return 0x01
    }

    // The level this entry needs for `r`, in this entry's numbering.
    func requiredLevel(for r: WFDResolution) -> UInt16 {
        switch (codec, flavor) {
        case (.h265, .r2):
            return r.requiredH265LevelBit
        case (.h265, .wfdx):
            // wfdx shares the H.264 level bitmap: map 3.1/4/4.1/5/5.1 onto it.
            return [0x01: 0x01, 0x02: 0x04, 0x04: 0x08, 0x08: 0x20, 0x10: 0x40][r.requiredH265LevelBit] ?? 0x40
        default:
            return UInt16(r.requiredLevelBit)
        }
    }

    func canCarry(_ r: WFDResolution) -> Bool { supports(r) && requiredLevel(for: r) <= maxLevelBit }

    // H.264 profiles we can produce from this entry, best first.
    var h264Profiles: [H264Profile] {
        guard codec == .h264 else { return [] }
        var out: [H264Profile] = []
        if profile & 0x01 != 0 { out.append(.constrainedBaseline) }
        if profile & 0x02 != 0 { out.append(.constrainedHigh) }
        if flavor == .r2, profile & 0x04 != 0 { out.append(.restrictedHigh2) }
        return out
    }

    var supportsHEVCMain: Bool {
        switch flavor {
        case .r2: return codec == .h265 && profile & 0x01 != 0
        case .wfdx: return codec == .h265
        case .r1: return false
        }
    }

    // "profile level cea vesa hh latency min-slice slice-enc frame-rate-ctl max-h max-v" (R1)
    static func parseR1(_ descriptor: String) -> WFDVideoCodecEntry? {
        let t = descriptor.split(separator: " ").map(String.init)
        guard t.count >= 9,
              let profile = UInt8(t[0], radix: 16), let level = UInt8(t[1], radix: 16),
              let cea = UInt64(t[2], radix: 16), let vesa = UInt64(t[3], radix: 16),
              let hh = UInt64(t[4], radix: 16), let latency = UInt8(t[5], radix: 16),
              let minSlice = UInt16(t[6], radix: 16), let sliceEnc = UInt16(t[7], radix: 16),
              let frc = UInt8(t[8], radix: 16) else { return nil }
        // Bits above 16 are reserved in R1's CEA bitmap; ignore them.
        return WFDVideoCodecEntry(codec: .h264, flavor: .r1, profile: UInt16(profile), level: UInt16(level),
                                  ceaSupport: cea & 0x1FFFF, vesaSupport: vesa, hhSupport: hh, latency: latency,
                                  minSliceSize: minSlice, sliceEncParams: sliceEnc, frameRateControl: frc)
    }

    // "codec profile level cea vesa hh latency min-slice slice-enc frame-rate-ctl" (R2)
    static func parseR2(_ descriptor: String) -> WFDVideoCodecEntry? {
        let t = descriptor.split(separator: " ").map(String.init)
        guard t.count >= 10,
              let codecBits = UInt8(t[0], radix: 16), let profile = UInt16(t[1], radix: 16),
              let level = UInt16(t[2], radix: 16), let cea = UInt64(t[3], radix: 16),
              let vesa = UInt64(t[4], radix: 16), let hh = UInt64(t[5], radix: 16),
              let latency = UInt8(t[6], radix: 16), let minSlice = UInt16(t[7], radix: 16),
              let sliceEnc = UInt16(t[8], radix: 16), let frc = UInt8(t[9], radix: 16) else { return nil }
        let codec: VideoCodec
        switch codecBits {
        case 0x01: codec = .h264
        case 0x02: codec = .h265
        default: return nil
        }
        return WFDVideoCodecEntry(codec: codec, flavor: .r2, profile: profile, level: level,
                                  ceaSupport: cea, vesaSupport: vesa, hhSupport: hh, latency: latency,
                                  minSliceSize: minSlice, sliceEncParams: sliceEnc, frameRateControl: frc)
    }

    // "profile level cea vesa hh latency min-slice slice-enc frame-rate-ctl max-h max-v" (wfdx);
    // one wfdx entry can stand for both H.264 (profile bits 0/1) and H.265 (bit 2).
    static func parseWfdx(_ descriptor: String) -> [WFDVideoCodecEntry] {
        let t = descriptor.split(separator: " ").map(String.init)
        guard t.count >= 9,
              let profile = UInt16(t[0], radix: 16), let level = UInt16(t[1], radix: 16),
              let cea = UInt64(t[2], radix: 16), let vesa = UInt64(t[3], radix: 16),
              let hh = UInt64(t[4], radix: 16), let latency = UInt8(t[5], radix: 16),
              let minSlice = UInt16(t[6], radix: 16), let sliceEnc = UInt16(t[7], radix: 16),
              let frc = UInt8(t[8], radix: 16) else { return [] }
        var out: [WFDVideoCodecEntry] = []
        let base = WFDVideoCodecEntry(codec: .h264, flavor: .wfdx, profile: profile & 0x03, level: level,
                                      ceaSupport: cea, vesaSupport: vesa, hhSupport: hh, latency: latency,
                                      minSliceSize: minSlice, sliceEncParams: sliceEnc, frameRateControl: frc)
        if profile & 0x03 != 0 { out.append(base) }
        if profile & 0x04 != 0 {
            var hevc = base
            hevc.codec = .h265
            hevc.profile = 0x04
            out.append(hevc)
        }
        return out
    }
}

struct WFDVideoFormats: Equatable {
    var flavor: WFDFormatFlavor
    var native: UInt16
    var codecs: [WFDVideoCodecEntry]

    // R1: "native preferred-display-mode codec[, codec...]"
    static func parse(_ value: String) -> WFDVideoFormats? { parseR1(value) }

    static func parseR1(_ value: String) -> WFDVideoFormats? {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard v.lowercased() != "none" else { return nil }
        let parts = v.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, let native = UInt16(parts[0], radix: 16) else { return nil }
        let codecs = parts[2].split(separator: ",").compactMap {
            WFDVideoCodecEntry.parseR1($0.trimmingCharacters(in: .whitespaces))
        }
        return codecs.isEmpty ? nil : WFDVideoFormats(flavor: .r1, native: native, codecs: codecs)
    }

    // R2: "native codec-entry[, codec-entry...] non-transcoding" (Miracast v2.3 6.1.22)
    static func parseR2(_ value: String) -> WFDVideoFormats? {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard v.lowercased() != "none" else { return nil }
        let parts = v.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let native = UInt16(parts[0], radix: 16) else { return nil }
        var list = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        // The last entry carries the trailing non-transcoding-support field; drop it.
        if var last = list.popLast() {
            var t = last.split(separator: " ")
            if t.count == 11 { t.removeLast(); last = t.joined(separator: " ") }
            list.append(last)
        }
        let codecs = list.compactMap(WFDVideoCodecEntry.parseR2)
        return codecs.isEmpty ? nil : WFDVideoFormats(flavor: .r2, native: native, codecs: codecs)
    }

    // wfdx: "native(4) preferred-display-mode codec[, codec...]"
    static func parseWfdx(_ value: String) -> WFDVideoFormats? {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard v.lowercased() != "none" else { return nil }
        let parts = v.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, let native = UInt16(parts[0], radix: 16) else { return nil }
        let codecs = parts[2].split(separator: ",").flatMap {
            WFDVideoCodecEntry.parseWfdx($0.trimmingCharacters(in: .whitespaces))
        }
        return codecs.isEmpty ? nil : WFDVideoFormats(flavor: .wfdx, native: native, codecs: codecs)
    }

    // Sink's native resolution, when it is one we know.
    var nativeResolution: WFDResolution? {
        let (tableBits, index): (UInt16, Int) = flavor == .r2
            ? (native & 0x03, Int(native >> 2))
            : (native & 0x07, Int(native >> 3))
        guard tableBits == 0 else { return nil }
        return WFDResolution.table(for: flavor).first { $0.bit == index }
    }
}

// MARK: - Audio

struct WFDAudioCodec: Equatable {
    var format: String      // LPCM, AAC, AC3
    var modes: UInt32
    var latency: UInt8

    static func parseList(_ value: String) -> [WFDAudioCodec] {
        guard value.trimmingCharacters(in: .whitespaces).lowercased() != "none" else { return [] }
        return value.split(separator: ",").compactMap { entry in
            let t = entry.split(separator: " ").map(String.init)
            guard t.count >= 2, let modes = UInt32(t[1], radix: 16) else { return nil }
            return WFDAudioCodec(format: t[0].uppercased(), modes: modes,
                                 latency: t.count > 2 ? UInt8(t[2], radix: 16) ?? 0 : 0)
        }
    }

    var descriptor: String { String(format: "%@ %08X %02X", format, modes, latency) }
}

// MARK: - Sink capabilities (M3 response)

struct WFDSinkCapabilities {
    // The format list to use: R2 if the sink answered it, else wfdx, else R1
    // (Miracast 6.1.22 / MS-WFDPE 2.7.1.1: the newer parameter supersedes the older).
    var videoFormats: WFDVideoFormats?
    var r1VideoFormats: WFDVideoFormats?
    var audioCodecs: [WFDAudioCodec] = []
    var audioParameter = "wfd_audio_codecs"   // which name to use in M4
    var uibc: UIBCCapability?
    var rtpPort0: UInt16 = 0
    var rtpPort1: UInt16 = 0
    var rtpProfile = "RTP/AVP/UDP;unicast"
    var contentProtection: String?
    var raw: [String: String] = [:]

    static func parse(_ body: String) -> WFDSinkCapabilities {
        let p = WFDParameters.parse(body)
        var caps = WFDSinkCapabilities(raw: p)
        caps.r1VideoFormats = p["wfd_video_formats"].flatMap(WFDVideoFormats.parseR1)
        caps.videoFormats = p["wfd2_video_formats"].flatMap(WFDVideoFormats.parseR2)
            ?? p["wfdx_video_formats"].flatMap(WFDVideoFormats.parseWfdx)
            ?? caps.r1VideoFormats
        if let a = p["wfd2_audio_codecs"], caps.videoFormats?.flavor == .r2 {
            caps.audioCodecs = WFDAudioCodec.parseList(a)
            caps.audioParameter = "wfd2_audio_codecs"
        } else if let a = p["wfd_audio_codecs"] {
            caps.audioCodecs = WFDAudioCodec.parseList(a)
        }
        caps.uibc = p["wfd_uibc_capability"].flatMap(UIBCCapability.parse)
        if let ports = p["wfd_client_rtp_ports"] {
            // "RTP/AVP/UDP;unicast 19000 0 mode=play"
            let t = ports.split(separator: " ").map(String.init)
            if t.count >= 3 {
                caps.rtpProfile = t[0]
                caps.rtpPort0 = UInt16(t[1]) ?? 0
                caps.rtpPort1 = UInt16(t[2]) ?? 0
            }
        }
        caps.contentProtection = p["wfd_content_protection"]
        return caps
    }
}

// MARK: - Negotiated format

struct StreamPreferences {
    // auto = best up to 1080p (4K needs ~30 Mbit/s of Wi-Fi, so it's opt-in).
    enum ResolutionChoice: String, CaseIterable {
        case auto, p2160 = "4k", p1080 = "1080p", p720 = "720p"
    }
    enum AudioCodecChoice: String, CaseIterable {
        case auto, aac, lpcm
    }
    var resolution: ResolutionChoice = .auto
    var fps: Int = 30
    var audio: Bool = true
    var audioCodec: AudioCodecChoice = .auto
    var bitrate: Int = 6_000_000
    var lowLatency = false          // prefers LPCM (no encoder lookahead)
    var codec: WFDNegotiatedFormat.CodecChoice = .auto
    var legacyFormats = false       // only R1 wfd_video_formats (H.264), for picky sinks
    var allowHEVC = true            // false on Macs that can't encode HEVC
    var uibcPort: UInt16 = 0        // > 0: offer input from the TV on this TCP port
    // Extra M3 parameters to ask the sink about (diagnostics, e.g. WFD R2 capabilities).
    var extraM3Parameters: [String] = []

    // Parameters for M3: the R1 basics, plus R2/Microsoft video formats and UIBC as configured.
    var m3Parameters: [String] {
        var names = ["wfd_video_formats", "wfd_audio_codecs", "wfd_client_rtp_ports", "wfd_content_protection"]
        if !legacyFormats { names += ["wfd2_video_formats", "wfd2_audio_codecs", "wfdx_video_formats"] }
        if uibcPort > 0 { names.append("wfd_uibc_capability") }
        for n in extraM3Parameters where !names.contains(n) { names.append(n) }
        return names
    }

    static let basicM3Parameters = ["wfd_video_formats", "wfd_audio_codecs", "wfd_client_rtp_ports", "wfd_content_protection"]

    static let wfd2ProbeParameters = ["wfd2_video_formats", "wfd2_audio_codecs", "wfdx_video_formats",
                                      "microsoft_video_formats", "wfd_display_edid", "wfd_uibc_capability",
                                      "wfd_idr_request_capability", "microsoft_cursor",
                                      "microsoft_latency_management_capability", "microsoft_rtcp_capability"]
}

struct WFDNegotiatedFormat: Equatable {
    var resolution: WFDResolution
    var codec: VideoCodec = .h264
    var h264Profile: H264Profile = .constrainedBaseline
    var flavor: WFDFormatFlavor = .r1
    var levelBit: UInt16                // in the flavor's numbering for this codec
    var audio: WFDAudioCodec?
    var audioParameter = "wfd_audio_codecs"
    var rtpPort0: UInt16
    var rtpPort1: UInt16
    var rtpProfile: String
    var uibc: UIBCCapability? = nil     // what we enable, with our port filled in

    var isHighProfile: Bool { codec == .h264 && h264Profile != .constrainedBaseline }

    // HEVC Main tier bitrate limit for the negotiated level (H.265 Table A.8);
    // nil for H.264, whose levels allow far more than Wi-Fi can carry.
    var maxBitrate: Int? {
        guard isHEVC else { return nil }
        let r2Level = flavor == .r2 ? levelBit : ([0x01: 0x01, 0x02: 0x01, 0x04: 0x02, 0x08: 0x04, 0x10: 0x04, 0x20: 0x08][levelBit] ?? 0x10)
        switch r2Level {
        case 0x01: return 10_000_000      // 3.1
        case 0x02: return 12_000_000      // 4
        case 0x04: return 20_000_000      // 4.1
        case 0x08: return 25_000_000      // 5
        default:   return 40_000_000      // 5.1
        }
    }
    var isHEVC: Bool { codec == .h265 }

    // H.264 level as the classic WFD bit (for the encoder), whatever the flavor.
    var h264LevelBit: UInt8 { UInt8(truncatingIfNeeded: levelBit) }

    var summary: String {
        let profile = isHEVC ? "Main" : h264Profile.rawValue
        return "\(resolution) \(codec.rawValue) \(profile), level bit 0x\(String(levelBit, radix: 16)) via \(flavor.rawValue)"
    }

    enum CodecChoice: String, CaseIterable { case auto, h264, hevc }

    // Pick the best format both sides support.
    //  - resolution: preference order (1080p30 -> 720p30, or 4K first if asked), then the
    //    mandatory 640x480p60
    //  - codec: auto = H.264 up to 1080p (lowest latency, universal) and HEVC for 4K;
    //    "h264"/"hevc" prefer that codec but fall back to the other if needed
    //  - H.264 profile: Constrained Baseline, else Constrained High, else RHP2
    static func choose(sink: WFDSinkCapabilities, prefs: StreamPreferences) -> WFDNegotiatedFormat {
        let formats = prefs.legacyFormats ? sink.r1VideoFormats : sink.videoFormats
        let flavor = formats?.flavor ?? .r1
        let entries = formats?.codecs ?? []
        let fps = prefs.fps
        func res(_ w: Int, _ h: Int, _ f: Int) -> WFDResolution? { WFDResolution.find(width: w, height: h, fps: f, flavor: flavor) }

        var sizes: [(Int, Int)]
        switch prefs.resolution {
        case .p2160: sizes = [(3840, 2160), (1920, 1080), (1280, 720)]
        case .auto, .p1080: sizes = [(1920, 1080), (1280, 720)]
        case .p720: sizes = [(1280, 720)]
        }
        var candidates: [WFDResolution] = sizes.compactMap { res($0.0, $0.1, fps) }
        if fps != 30 { candidates += sizes.compactMap { res($0.0, $0.1, 30) } }

        var result = WFDNegotiatedFormat(resolution: .mandatory, codec: .h264, h264Profile: .constrainedBaseline,
                                         flavor: flavor, levelBit: 0x01, audio: nil,
                                         audioParameter: flavor == .r2 ? sink.audioParameter : "wfd_audio_codecs",
                                         rtpPort0: sink.rtpPort0,
                                         rtpPort1: sink.rtpPort1, rtpProfile: sink.rtpProfile)
        search: for r in candidates {
            let h264 = entries.filter { !$0.h264Profiles.isEmpty && $0.canCarry(r) }
                .sorted { a, b in
                    (H264Profile.order(a.h264Profiles.first!)) < (H264Profile.order(b.h264Profiles.first!))
                }
            let hevc = prefs.allowHEVC ? entries.filter { $0.supportsHEVCMain && $0.canCarry(r) } : []
            let preferHEVC: Bool
            switch prefs.codec {
            case .hevc: preferHEVC = true
            case .h264: preferHEVC = false
            case .auto: preferHEVC = r.is4K
            }
            let order: [VideoCodec] = preferHEVC ? [.h265, .h264] : [.h264, .h265]
            for codec in order {
                if codec == .h265, let e = hevc.first {
                    result.resolution = r
                    result.codec = .h265
                    // VideoToolbox picks the HEVC level itself (from size, rate and bitrate),
                    // so announce the highest level the sink decodes; maxBitrate keeps us in it.
                    result.levelBit = min(e.maxLevelBit, e.flavor == .r2 ? 0x10 : 0x40)
                    break search
                }
                if codec == .h264, let e = h264.first {
                    result.resolution = r
                    result.codec = .h264
                    result.h264Profile = e.h264Profiles.first!
                    result.levelBit = e.requiredLevel(for: r)
                    break search
                }
            }
        }
        if result.resolution == .mandatory, result.codec == .h264 {
            result.levelBit = 0x01
        }

        if prefs.uibcPort > 0 { result.uibc = sink.uibc?.accepted(port: prefs.uibcPort) }

        // AAC mode bit 0 = 48 kHz stereo (mandatory for AAC-capable sinks);
        // LPCM mode bit 1 = 48 kHz 16-bit stereo (mandatory for every WFD sink with audio).
        let aac = sink.audioCodecs.contains { $0.format == "AAC" && $0.modes & 0x1 != 0 }
            ? WFDAudioCodec(format: "AAC", modes: 0x1, latency: 0) : nil
        let lpcm = sink.audioCodecs.contains { $0.format == "LPCM" && $0.modes & 0x2 != 0 }
            ? WFDAudioCodec(format: "LPCM", modes: 0x2, latency: 0) : nil
        if prefs.audio {
            switch prefs.audioCodec {
            case .auto: result.audio = prefs.lowLatency ? (lpcm ?? aac) : (aac ?? lpcm)
            case .aac:  result.audio = aac
            case .lpcm: result.audio = lpcm
            }
        }
        return result
    }

    // What to try if the sink rejects M4: the same without UIBC, then plain R1 H.264.
    static func fallbacks(after n: WFDNegotiatedFormat, sink: WFDSinkCapabilities, prefs: StreamPreferences) -> [WFDNegotiatedFormat] {
        var out: [WFDNegotiatedFormat] = []
        if n.uibc != nil {
            var plain = n
            plain.uibc = nil
            out.append(plain)
        }
        if n.flavor != .r1, sink.r1VideoFormats != nil {
            var legacy = prefs
            legacy.legacyFormats = true
            legacy.uibcPort = 0
            out.append(choose(sink: sink, prefs: legacy))
        }
        return out
    }

    // The video parameter value for M4, in the sink's flavor.
    var videoFormatsDescriptor: String {
        var cea: UInt64 = 0, vesa: UInt64 = 0, hh: UInt64 = 0
        let mask = UInt64(1) << UInt64(resolution.bit)
        switch resolution.table {
        case .cea: cea = mask
        case .vesa: vesa = mask
        case .hh: hh = mask
        }
        switch flavor {
        case .r1:
            let profile: UInt8 = h264Profile == .constrainedBaseline ? 0x01 : 0x02
            return String(format: "00 00 %02X %02X %08llX %08llX %08llX 00 0000 0000 00 none none",
                          profile, UInt8(truncatingIfNeeded: levelBit), cea, vesa, hh)
        case .r2:
            let codecBits: UInt8 = isHEVC ? 0x02 : 0x01
            let profile: UInt8
            switch (codec, h264Profile) {
            case (.h265, _): profile = 0x01                    // Main
            case (_, .constrainedBaseline): profile = 0x01
            case (_, .constrainedHigh): profile = 0x02
            case (_, .restrictedHigh2): profile = 0x04
            }
            return String(format: "00 %02X %02X %04X %012llX %012llX %012llX 00 0000 0000 00 00",
                          codecBits, profile, levelBit, cea, vesa, hh)
        case .wfdx:
            let profile: UInt16 = isHEVC ? 0x0004 : (h264Profile == .constrainedBaseline ? 0x0001 : 0x0002)
            return String(format: "0000 00 %04X %04X %010llX %010llX %08llX 00 0000 0000 00 none none",
                          profile, levelBit, cea, vesa, hh)
        }
    }

    // M4 SET_PARAMETER body.
    func m4Body(presentationURL: String) -> String {
        var body = "\(flavor.rawValue): \(videoFormatsDescriptor)\r\n"
        if let audio { body += "\(audioParameter): \(audio.descriptor)\r\n" }
        body += "wfd_presentation_URL: \(presentationURL) none\r\n"
        body += "wfd_client_rtp_ports: \(rtpProfile) \(rtpPort0) \(rtpPort1) mode=play\r\n"
        if let uibc {
            body += "wfd_uibc_capability: \(uibc.descriptor)\r\n"
            body += "wfd_uibc_setting: enable\r\n"
        }
        return body
    }
}

extension H264Profile {
    static func order(_ p: H264Profile) -> Int {
        switch p {
        case .constrainedBaseline: return 0
        case .constrainedHigh: return 1
        case .restrictedHigh2: return 2
        }
    }
}

// MARK: - Transport header

enum RTSPTransport {
    // client_port=19000 or client_port=19000-19001 -> (rtp, rtcp?)
    static func clientPorts(_ transport: String) -> (rtp: UInt16, rtcp: UInt16?)? {
        for part in transport.split(separator: ";") {
            let t = part.trimmingCharacters(in: .whitespaces)
            guard t.lowercased().hasPrefix("client_port=") else { continue }
            let ports = t.dropFirst("client_port=".count).split(separator: "-")
            guard let first = ports.first, let rtp = UInt16(first) else { return nil }
            let rtcp = ports.count > 1 ? UInt16(ports[1]) : nil
            return (rtp, rtcp)
        }
        return nil
    }
}
