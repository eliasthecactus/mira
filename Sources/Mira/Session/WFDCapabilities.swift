import Foundation

// CEA 861 resolution bitmap bit positions (WFD spec Table 5-9)
enum CEAResolution: UInt32 {
    case r640x480p60   = 0x0001  // bit 0
    case r1280x720p30  = 0x0020  // bit 5
    case r1280x720p60  = 0x0040  // bit 6
    case r1920x1080p30 = 0x0080  // bit 7
    case r1920x1080p60 = 0x0100  // bit 8
}

struct WFDCapabilities {
    // Video formats string for GET_PARAMETER response
    // Profile: 0x01=CBP, 0x02=CHP. Level bitmap: bit0=3.1,bit1=3.2,...,bit4=4.2
    static func videoFormats(resolution: CEAResolution = .r1280x720p30) -> String {
        let profile: UInt8 = 0x01        // CBP
        let level: UInt8  = 0x1F        // 3.1–4.2
        let cea = resolution.rawValue | CEAResolution.r1280x720p30.rawValue | CEAResolution.r1920x1080p30.rawValue
        return String(format:
            "00 00 %02X %02X %08X 00000000 00000000 00 0000 0000 00 none none",
            profile, level, cea)
    }

    // No audio for v1 — simpler, and avoids MPEG-TS mux requirement
    static let audioCodecs = "none"

    // Port the source's RTP sender will use (arbitrary high port)
    static let rtpVideoPort: UInt16 = 30000
    static let rtcpVideoPort: UInt16 = 30001

    static func clientRTPPorts() -> String {
        "RTP/AVP/UDP;unicast \(rtpVideoPort) 0 mode=play"
    }

    // Parse client_port from a Transport header value
    static func parseClientPort(transport: String) -> UInt16 {
        for part in transport.components(separatedBy: ";") {
            let t = part.trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix("client_port=") {
                let portPart = t.dropFirst("client_port=".count)
                let portStr = portPart.split(separator: "-").first.map(String.init) ?? String(portPart)
                return UInt16(portStr) ?? 1990
            }
        }
        return 1990
    }

    // Build GET_PARAMETER response body from the list of params the sink requested
    static func responseBody(for requestedParams: [String]) -> String {
        var body = ""
        for param in requestedParams {
            switch param.trimmingCharacters(in: .whitespaces) {
            case "wfd_video_formats":
                body += "wfd_video_formats: \(videoFormats())\r\n"
            case "wfd_audio_codecs":
                body += "wfd_audio_codecs: \(audioCodecs)\r\n"
            case "wfd_client_rtp_ports":
                body += "wfd_client_rtp_ports: \(clientRTPPorts())\r\n"
            case "wfd_uibc_capability":
                body += "wfd_uibc_capability: none\r\n"
            case "wfd_standby_resume_capability":
                body += "wfd_standby_resume_capability: none\r\n"
            case "wfd_display_edid":
                body += "wfd_display_edid: none\r\n"
            case "wfd_coupled_sink":
                body += "wfd_coupled_sink: none\r\n"
            case "wfd_3d_video_formats":
                body += "wfd_3d_video_formats: none\r\n"
            case "wfd_content_protection":
                body += "wfd_content_protection: none\r\n"
            case "wfd_i2c":
                body += "wfd_i2c: none\r\n"
            default:
                break
            }
        }
        return body
    }
}
