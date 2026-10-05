import Foundation

// Cast Streaming session negotiation (openscreen streaming_session_protocol.md):
// the sender OFFERs streams, the receiver ANSWERs with the ones it picked, its UDP
// port and its RTCP SSRCs, plus constraints the sender must respect.

struct CastStreamOffer: Equatable {
    enum Kind: String { case audio = "audio_source", video = "video_source" }

    var index: Int
    var kind: Kind
    var codecName: String           // "h264", "hevc", "opus", "aac"
    var payloadType: UInt8
    var ssrc: UInt32
    var targetDelayMs: Int
    var aesKey: [UInt8]
    var aesIvMask: [UInt8]
    var timeBase: Int               // 90000 video, 48000 audio
    var channels = 1
    var bitRate = 0                 // audio
    var maxBitRate = 0              // video
    var maxFrameRate = 30
    var resolutions: [(Int, Int)] = []

    static func == (a: CastStreamOffer, b: CastStreamOffer) -> Bool {
        a.index == b.index && a.kind == b.kind && a.codecName == b.codecName && a.ssrc == b.ssrc
    }

    var json: [String: Any] {
        var o: [String: Any] = [
            "index": index,
            "type": kind.rawValue,
            "codecName": codecName,
            "codecParameter": "",
            "rtpProfile": "cast",
            "rtpPayloadType": Int(payloadType),
            "ssrc": Int(ssrc),
            "targetDelay": targetDelayMs,
            "aesKey": aesKey.hexString,
            "aesIvMask": aesIvMask.hexString,
            "timeBase": "1/\(timeBase)",
            "channels": channels,
            "receiverRtcpEventLog": false,
        ]
        if kind == .audio {
            o["bitRate"] = bitRate
        } else {
            o["maxFrameRate"] = "\(maxFrameRate)"
            o["maxBitRate"] = maxBitRate
            o["protection"] = "none"
            o["profile"] = ""
            o["level"] = ""
            o["errorRecoveryMode"] = "castv2"
            o["resolutions"] = resolutions.map { ["width": $0.0, "height": $0.1] }
        }
        return o
    }
}

struct CastOffer {
    // Legacy Chrome behaviour, still the library default: Android TV receivers want
    // video on payload type 96 and audio on 127 regardless of codec.
    static let videoPayloadType: UInt8 = 96
    static let audioPayloadType: UInt8 = 127

    var streams: [CastStreamOffer]

    var json: [String: Any] {
        ["castMode": "mirroring", "supportedStreams": streams.map(\.json)]
    }

    // Video codecs in preference order, audio codecs in preference order.
    static func make(videoCodecs: [VideoCodec], audioCodecs: [StreamFormat.Audio],
                     width: Int, height: Int, fps: Int, maxBitRate: Int, targetDelayMs: Int) -> CastOffer {
        var streams: [CastStreamOffer] = []
        var usedSSRCs = Set<UInt32>()
        func ssrc() -> UInt32 {
            var s: UInt32
            repeat { s = UInt32.random(in: 1...0x7FFF_FFFF) } while !usedSSRCs.insert(s).inserted
            return s
        }
        for codec in audioCodecs where codec != .lpcm {
            streams.append(CastStreamOffer(
                index: streams.count, kind: .audio, codecName: codec == .opus ? "opus" : "aac",
                payloadType: audioPayloadType, ssrc: ssrc(), targetDelayMs: targetDelayMs,
                aesKey: randomBytes(16), aesIvMask: randomBytes(16), timeBase: 48_000,
                channels: 2, bitRate: 128_000))
        }
        for codec in videoCodecs {
            streams.append(CastStreamOffer(
                index: streams.count, kind: .video, codecName: codec == .h265 ? "hevc" : "h264",
                payloadType: videoPayloadType, ssrc: ssrc(), targetDelayMs: targetDelayMs,
                aesKey: randomBytes(16), aesIvMask: randomBytes(16), timeBase: 90_000,
                maxBitRate: maxBitRate, maxFrameRate: fps, resolutions: [(width, height)]))
        }
        return CastOffer(streams: streams)
    }

    static func randomBytes(_ n: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: n)
        if SecRandomCopyBytes(kSecRandomDefault, n, &b) != errSecSuccess {
            for i in 0..<n { b[i] = UInt8.random(in: 0...255) }
        }
        return b
    }
}

struct CastAnswer: Equatable {
    var udpPort: UInt16
    var sendIndexes: [Int]
    var ssrcs: [UInt32]
    var maxWidth: Int?
    var maxHeight: Int?
    var maxFrameRate: Double?
    var maxVideoBitRate: Int?
    var maxPixelsPerSecond: Double?
    var maxDelayMs: Int?
    var displayWidth: Int?
    var displayHeight: Int?
    var receiverScales = false      // "scaling": "receiver"

    // `message` is the whole ANSWER message ({"type":"ANSWER","result":"ok","answer":{...}}).
    static func parse(_ message: [String: Any]) -> Result<CastAnswer, CastSession.SessionError> {
        guard (message["result"] as? String) == "ok", let a = message["answer"] as? [String: Any] else {
            let err = message["error"] as? [String: Any]
            let why = (err?["description"] as? String) ?? (message["result"] as? String) ?? "no answer"
            return .failure(.answerRejected(why))
        }
        guard let port = (a["udpPort"] as? NSNumber)?.intValue, (1...65535).contains(port),
              let indexes = (a["sendIndexes"] as? [NSNumber])?.map(\.intValue),
              let ssrcs = (a["ssrcs"] as? [NSNumber])?.map(\.uint32Value),
              indexes.count == ssrcs.count, !indexes.isEmpty else {
            return .failure(.answerRejected("malformed ANSWER"))
        }
        var answer = CastAnswer(udpPort: UInt16(port), sendIndexes: indexes, ssrcs: ssrcs)
        if let video = (a["constraints"] as? [String: Any])?["video"] as? [String: Any] {
            if let dims = video["maxDimensions"] as? [String: Any] {
                answer.maxWidth = (dims["width"] as? NSNumber)?.intValue
                answer.maxHeight = (dims["height"] as? NSNumber)?.intValue
                answer.maxFrameRate = Self.rate(dims["frameRate"])
            }
            answer.maxVideoBitRate = (video["maxBitRate"] as? NSNumber)?.intValue
            answer.maxPixelsPerSecond = (video["maxPixelsPerSecond"] as? NSNumber)?.doubleValue
            answer.maxDelayMs = (video["maxDelay"] as? NSNumber)?.intValue
        }
        if let display = a["display"] as? [String: Any] {
            if let dims = display["dimensions"] as? [String: Any] {
                answer.displayWidth = (dims["width"] as? NSNumber)?.intValue
                answer.displayHeight = (dims["height"] as? NSNumber)?.intValue
            }
            answer.receiverScales = (display["scaling"] as? String) == "receiver"
        }
        return .success(answer)
    }

    // "30", "30000/1001" or a number.
    static func rate(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        guard let s = v as? String else { return nil }
        let parts = s.split(separator: "/").compactMap { Double($0) }
        if parts.count == 2, parts[1] > 0 { return parts[0] / parts[1] }
        return parts.first
    }

    // The largest size <= wanted that fits the receiver's constraints (16:9 steps).
    func fit(width: Int, height: Int, fps: Int) -> (width: Int, height: Int, fps: Int) {
        var fps = fps
        if let maxFPS = maxFrameRate, Double(fps) > maxFPS { fps = max(1, Int(maxFPS)) }
        let ladder = [(3840, 2160), (2560, 1440), (1920, 1080), (1600, 900), (1280, 720), (960, 540), (640, 360)]
        for (w, h) in ladder where w <= width && h <= height {
            if let mw = maxWidth, w > mw { continue }
            if let mh = maxHeight, h > mh { continue }
            if let pps = maxPixelsPerSecond, Double(w * h * fps) > pps * 1.01 { continue }
            return (w, h, fps)
        }
        return (640, 360, fps)
    }
}

extension Array where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
