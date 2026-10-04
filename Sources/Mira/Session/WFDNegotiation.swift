import Foundation

// Wi-Fi Display parameter handling: parse the sink's capabilities (M3 response),
// choose a stream format, and render the M4 SET_PARAMETER body.

// MARK: - text/parameters bodies

enum WFDParameters {
    // "name: value" lines → dictionary (names lowercased; WFD names are case-insensitive in practice).
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

struct WFDResolution: Equatable, CustomStringConvertible {
    enum Table: Int { case cea = 0, vesa = 1, hh = 2 }
    let width: Int
    let height: Int
    let fps: Int
    let table: Table
    let bit: Int            // bit index in the table's support bitmap

    var description: String { "\(width)x\(height)p\(fps)" }

    // Lowest H.264 level (as WFD level bit) that can carry this resolution/frame rate.
    // WFD level bits: 0x01=3.1, 0x02=3.2, 0x04=4, 0x08=4.1, 0x10=4.2
    var requiredLevelBit: UInt8 {
        let macroblocksPerSecond = ((width + 15) / 16) * ((height + 15) / 16) * fps
        switch macroblocksPerSecond {
        case ...108_000: return 0x01   // 3.1
        case ...216_000: return 0x02   // 3.2
        case ...245_760: return 0x04   // 4 / 4.1
        default:         return 0x10   // 4.2 (522,240 MB/s)
        }
    }

    // CEA-861 table (WFD spec table 5-10) — only progressive entries we can produce.
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

    // Mandatory for every WFD sink.
    static let mandatory = cea[0]

    static func cea(width: Int, height: Int, fps: Int) -> WFDResolution? {
        cea.first { $0.width == width && $0.height == height && $0.fps == fps }
    }
}

struct WFDH264Codec: Equatable {
    // Profile bits: 0x01 = Constrained Baseline, 0x02 = Constrained High
    var profile: UInt8
    var level: UInt8
    var ceaSupport: UInt32
    var vesaSupport: UInt32
    var hhSupport: UInt32
    var latency: UInt8
    var minSliceSize: UInt16
    var sliceEncParams: UInt16
    var frameRateControl: UInt8

    // Highest level bit the sink advertises (the field is a bitmap on some sinks).
    var maxLevelBit: UInt8 {
        var bit: UInt8 = 0x10
        while bit > 0 { if level & bit != 0 { return bit }; bit >>= 1 }
        return 0x01
    }

    func supports(_ r: WFDResolution) -> Bool {
        let map: UInt32
        switch r.table {
        case .cea: map = ceaSupport
        case .vesa: map = vesaSupport
        case .hh: map = hhSupport
        }
        return map & (UInt32(1) << UInt32(r.bit)) != 0
    }

    // "profile level cea vesa hh latency min-slice slice-enc frame-rate-ctl max-h max-v"
    static func parse(_ descriptor: String) -> WFDH264Codec? {
        let t = descriptor.split(separator: " ").map(String.init)
        guard t.count >= 9,
              let profile = UInt8(t[0], radix: 16), let level = UInt8(t[1], radix: 16),
              let cea = UInt32(t[2], radix: 16), let vesa = UInt32(t[3], radix: 16),
              let hh = UInt32(t[4], radix: 16), let latency = UInt8(t[5], radix: 16),
              let minSlice = UInt16(t[6], radix: 16), let sliceEnc = UInt16(t[7], radix: 16),
              let frc = UInt8(t[8], radix: 16) else { return nil }
        return WFDH264Codec(profile: profile, level: level, ceaSupport: cea, vesaSupport: vesa,
                            hhSupport: hh, latency: latency, minSliceSize: minSlice,
                            sliceEncParams: sliceEnc, frameRateControl: frc)
    }
}

struct WFDVideoFormats: Equatable {
    var native: UInt8
    var preferredDisplayMode: UInt8
    var codecs: [WFDH264Codec]

    // "native preferred-display-mode codec[, codec...]"
    static func parse(_ value: String) -> WFDVideoFormats? {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard v.lowercased() != "none" else { return nil }
        let parts = v.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3,
              let native = UInt8(parts[0], radix: 16),
              let pdm = UInt8(parts[1], radix: 16) else { return nil }
        let codecs = parts[2].split(separator: ",").compactMap {
            WFDH264Codec.parse($0.trimmingCharacters(in: .whitespaces))
        }
        guard !codecs.isEmpty else { return nil }
        return WFDVideoFormats(native: native, preferredDisplayMode: pdm, codecs: codecs)
    }

    // Sink's native resolution, when it is one we know (CEA table only).
    var nativeResolution: WFDResolution? {
        guard native & 0x07 == 0 else { return nil }
        let bit = Int(native >> 3)
        return WFDResolution.cea.first { $0.bit == bit }
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
    var videoFormats: WFDVideoFormats?
    var audioCodecs: [WFDAudioCodec] = []
    var rtpPort0: UInt16 = 0
    var rtpPort1: UInt16 = 0
    var rtpProfile = "RTP/AVP/UDP;unicast"
    var contentProtection: String?
    var raw: [String: String] = [:]

    static func parse(_ body: String) -> WFDSinkCapabilities {
        let p = WFDParameters.parse(body)
        var caps = WFDSinkCapabilities(raw: p)
        if let v = p["wfd_video_formats"] { caps.videoFormats = WFDVideoFormats.parse(v) }
        if let a = p["wfd_audio_codecs"] { caps.audioCodecs = WFDAudioCodec.parseList(a) }
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
    enum ResolutionChoice: String, CaseIterable {
        case auto, p1080 = "1080p", p720 = "720p"
    }
    enum AudioCodecChoice: String, CaseIterable {
        case auto, aac, lpcm
    }
    var resolution: ResolutionChoice = .auto
    var fps: Int = 30
    var audio: Bool = true
    var audioCodec: AudioCodecChoice = .auto
    var bitrate: Int = 6_000_000
}

struct WFDNegotiatedFormat: Equatable {
    var resolution: WFDResolution
    var profileBit: UInt8       // 0x01 CBP
    var levelBit: UInt8
    var audio: WFDAudioCodec?   // AAC 48 kHz stereo when enabled
    var rtpPort0: UInt16
    var rtpPort1: UInt16
    var rtpProfile: String

    // Pick the best format both sides support. Constrained Baseline is mandatory
    // for sinks, so we always use it; resolution preference is 1080p30 → 720p30 →
    // the mandatory 640x480p60.
    static func choose(sink: WFDSinkCapabilities, prefs: StreamPreferences) -> WFDNegotiatedFormat {
        let codecs = sink.videoFormats?.codecs ?? []
        let codec: WFDH264Codec? = codecs.first(where: { $0.profile & 0x01 != 0 }) ?? codecs.first
        let fps = prefs.fps

        var candidates: [WFDResolution] = []
        switch prefs.resolution {
        case .auto, .p1080:
            candidates = [WFDResolution.cea(width: 1920, height: 1080, fps: fps),
                          WFDResolution.cea(width: 1280, height: 720, fps: fps)].compactMap { $0 }
        case .p720:
            candidates = [WFDResolution.cea(width: 1280, height: 720, fps: fps)].compactMap { $0 }
        }
        if fps != 30 {
            candidates += [WFDResolution.cea(width: 1920, height: 1080, fps: 30),
                           WFDResolution.cea(width: 1280, height: 720, fps: 30)].compactMap { $0 }
        }

        var chosen = WFDResolution.mandatory
        if let codec {
            for r in candidates where codec.supports(r) && r.requiredLevelBit <= codec.maxLevelBit {
                chosen = r
                break
            }
        }

        // AAC mode bit 0 = 48 kHz stereo (mandatory for AAC-capable sinks);
        // LPCM mode bit 1 = 48 kHz 16-bit stereo (mandatory for every WFD sink with audio).
        let aac = sink.audioCodecs.contains { $0.format == "AAC" && $0.modes & 0x1 != 0 }
            ? WFDAudioCodec(format: "AAC", modes: 0x1, latency: 0) : nil
        let lpcm = sink.audioCodecs.contains { $0.format == "LPCM" && $0.modes & 0x2 != 0 }
            ? WFDAudioCodec(format: "LPCM", modes: 0x2, latency: 0) : nil
        var audio: WFDAudioCodec? = nil
        if prefs.audio {
            switch prefs.audioCodec {
            case .auto: audio = aac ?? lpcm
            case .aac:  audio = aac
            case .lpcm: audio = lpcm
            }
        }

        return WFDNegotiatedFormat(resolution: chosen, profileBit: 0x01,
                                   levelBit: chosen.requiredLevelBit, audio: audio,
                                   rtpPort0: sink.rtpPort0, rtpPort1: sink.rtpPort1,
                                   rtpProfile: sink.rtpProfile)
    }

    var videoFormatsDescriptor: String {
        var cea: UInt32 = 0, vesa: UInt32 = 0, hh: UInt32 = 0
        let mask = UInt32(1) << UInt32(resolution.bit)
        switch resolution.table {
        case .cea: cea = mask
        case .vesa: vesa = mask
        case .hh: hh = mask
        }
        return String(format: "00 00 %02X %02X %08X %08X %08X 00 0000 0000 00 none none",
                      profileBit, levelBit, cea, vesa, hh)
    }

    // M4 SET_PARAMETER body.
    func m4Body(presentationURL: String) -> String {
        var body = "wfd_video_formats: \(videoFormatsDescriptor)\r\n"
        if let audio { body += "wfd_audio_codecs: \(audio.descriptor)\r\n" }
        body += "wfd_presentation_URL: \(presentationURL) none\r\n"
        body += "wfd_client_rtp_ports: \(rtpProfile) \(rtpPort0) \(rtpPort1) mode=play\r\n"
        return body
    }
}

// MARK: - Transport header

enum RTSPTransport {
    // client_port=19000 or client_port=19000-19001 → (rtp, rtcp?)
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
