import XCTest
@testable import Mira

final class MICEMessageTests: XCTestCase {

    func testSourceReadyWireFormat() {
        let id = Data((0..<16).map { UInt8($0) })
        let bytes = [UInt8](MICEMessage.sourceReady(friendlyName: "Mac", rtspPort: 7236, sourceID: id).serialize())

        // Name: BOM + "Mac" in UTF-16LE = 8 bytes
        let name: [UInt8] = [0xFF, 0xFE, 0x4D, 0x00, 0x61, 0x00, 0x63, 0x00]
        var expected: [UInt8] = [0x00, 0x00, 0x01, 0x01]
        expected += [0x00, 0x00, UInt8(name.count)] + name
        expected += [0x02, 0x00, 0x02, 0x1C, 0x44]
        expected += [0x03, 0x00, 0x10] + (0..<16).map { UInt8($0) }
        expected[1] = UInt8(expected.count)
        XCTAssertEqual(bytes, expected)
    }

    func testRoundTripAndPartialReads() throws {
        let msg = MICEMessage.sourceReady(friendlyName: "Wohnzimmer – Mac 💻", rtspPort: 7300, sourceID: Data([1, 2, 3]))
        let wire = msg.serialize() + MICEMessage.stopProjection(friendlyName: "x", sourceID: Data()).serialize()

        var buffer = Data(wire.prefix(5))
        XCTAssertNil(try MICEMessage.extract(from: &buffer))
        buffer = wire
        let first = try XCTUnwrap(try MICEMessage.extract(from: &buffer))
        XCTAssertEqual(first.friendlyName, "Wohnzimmer – Mac 💻")
        XCTAssertEqual(first.rtspPort, 7300)
        XCTAssertEqual(first.value(.sourceID)?.count, 16)
        let second = try XCTUnwrap(try MICEMessage.extract(from: &buffer))
        XCTAssertEqual(second.command, MICEMessage.Command.stopProjection.rawValue)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testFriendlyNameTruncatedTo520Bytes() {
        let encoded = MICEMessage.encodeFriendlyName(String(repeating: "é", count: 400))
        XCTAssertLessThanOrEqual(encoded.count, MICEMessage.maxFriendlyNameBytes)
        XCTAssertEqual(encoded.count % 2, 0)
    }

    func testMalformedSizeThrows() {
        var buffer = Data([0x00, 0x02, 0x01, 0x01])
        XCTAssertThrowsError(try MICEMessage.extract(from: &buffer))
    }
}

final class RTSPMessageTests: XCTestCase {

    func testFramingAcrossChunksWithBody() throws {
        let body = "wfd_video_formats: 00 00 01 01 00000001 00000000 00000000 00 0000 0000 00 none none\r\n"
        let wire = "RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Type: text/parameters\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            + "OPTIONS * RTSP/1.0\r\nCSeq: 1\r\nRequire: org.wfa.wfd1.0\r\n\r\n"
        let bytes = Data(wire.utf8)

        var buffer = Data()
        var messages: [RTSPMessage] = []
        for chunk in stride(from: 0, to: bytes.count, by: 17) {
            buffer.append(bytes[chunk..<min(chunk + 17, bytes.count)])
            while let m = RTSPMessage.extract(from: &buffer) { messages.append(m) }
        }
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].statusCode, 200)
        XCTAssertEqual(messages[0].cseq, 2)
        XCTAssertEqual(messages[0].body, body)
        XCTAssertEqual(messages[1].method, "OPTIONS")
        XCTAssertEqual(messages[1].header("require"), "org.wfa.wfd1.0")
        XCTAssertTrue(buffer.isEmpty)
    }

    func testSerializeAddsContentLength() {
        let m = RTSPMessage.request(method: "SET_PARAMETER", uri: "rtsp://localhost/wfd1.0", cseq: 5,
                                    body: "wfd_trigger_method: SETUP\r\n")
        let text = String(decoding: m.serialize(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("SET_PARAMETER rtsp://localhost/wfd1.0 RTSP/1.0\r\nCSeq: 5\r\n"))
        XCTAssertTrue(text.contains("Content-Type: text/parameters\r\n"))
        XCTAssertTrue(text.hasSuffix("Content-Length: 27\r\n\r\nwfd_trigger_method: SETUP\r\n"))
    }

    func testSessionIDStripsTimeout() {
        let m = RTSPMessage.parse(from: Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\nSession: 1234;timeout=30\r\n\r\n".utf8))
        XCTAssertEqual(m?.sessionID, "1234")
    }
}

final class WFDNegotiationTests: XCTestCase {

    // Representative M3 reply from a Windows/MICE-class sink.
    let m3Reply = """
    wfd_video_formats: 00 00 03 10 0001ffff 1fffffff 00001fff 00 0000 0000 00 none none\r
    wfd_audio_codecs: LPCM 00000003 00, AAC 0000000f 00, AC3 00000007 00\r
    wfd_client_rtp_ports: RTP/AVP/UDP;unicast 1028 0 mode=play\r
    wfd_content_protection: none\r

    """

    func testParsesSinkCapabilities() throws {
        let caps = WFDSinkCapabilities.parse(m3Reply)
        let video = try XCTUnwrap(caps.videoFormats)
        XCTAssertEqual(video.codecs.count, 1)
        XCTAssertEqual(video.codecs[0].profile, 0x03)
        XCTAssertEqual(video.codecs[0].maxLevelBit, 0x10)
        XCTAssertEqual(caps.audioCodecs.map(\.format), ["LPCM", "AAC", "AC3"])
        XCTAssertEqual(caps.rtpPort0, 1028)
        XCTAssertEqual(caps.rtpPort1, 0)
    }

    func testChooses1080p30WithAAC() {
        let n = WFDNegotiatedFormat.choose(sink: WFDSinkCapabilities.parse(m3Reply), prefs: StreamPreferences())
        XCTAssertEqual(n.resolution.description, "1920x1080p30")
        XCTAssertEqual(n.levelBit, 0x04)
        XCTAssertEqual(n.audio?.descriptor, "AAC 00000001 00")
        XCTAssertEqual(n.videoFormatsDescriptor, "00 00 01 04 00000080 00000000 00000000 00 0000 0000 00 none none")
    }

    func testM4Body() {
        let n = WFDNegotiatedFormat.choose(sink: WFDSinkCapabilities.parse(m3Reply), prefs: StreamPreferences())
        let body = n.m4Body(presentationURL: "rtsp://192.168.1.2/wfd1.0/streamid=0")
        XCTAssertEqual(body, """
        wfd_video_formats: 00 00 01 04 00000080 00000000 00000000 00 0000 0000 00 none none\r
        wfd_audio_codecs: AAC 00000001 00\r
        wfd_presentation_URL: rtsp://192.168.1.2/wfd1.0/streamid=0 none\r
        wfd_client_rtp_ports: RTP/AVP/UDP;unicast 1028 0 mode=play\r

        """)
    }

    func testFallsBackTo720pWhenLevelTooLow() {
        // Level 3.2 (0x02) only, 720p30 + 1080p30 bits set → 1080p30 needs level 4.
        let caps = WFDSinkCapabilities.parse("wfd_video_formats: 00 00 01 02 000000a1 00000000 00000000 00 0000 0000 00 none none\r\nwfd_client_rtp_ports: RTP/AVP/UDP;unicast 19000 0 mode=play\r\n")
        let n = WFDNegotiatedFormat.choose(sink: caps, prefs: StreamPreferences())
        XCTAssertEqual(n.resolution.description, "1280x720p30")
        XCTAssertEqual(n.levelBit, 0x01)
        XCTAssertNil(n.audio, "no audio codecs advertised")
    }

    func testMandatoryFallbackAndNoAudioPreference() {
        let caps = WFDSinkCapabilities.parse("wfd_video_formats: 00 00 01 01 00000001 00000000 00000000 00 0000 0000 00 none none\r\nwfd_audio_codecs: AAC 00000001 00\r\nwfd_client_rtp_ports: RTP/AVP/UDP;unicast 19000 0 mode=play\r\n")
        var prefs = StreamPreferences()
        prefs.audio = false
        let n = WFDNegotiatedFormat.choose(sink: caps, prefs: prefs)
        XCTAssertEqual(n.resolution, WFDResolution.mandatory)
        XCTAssertNil(n.audio)
        XCTAssertFalse(n.m4Body(presentationURL: "rtsp://x/wfd1.0/streamid=0").contains("wfd_audio_codecs"))
    }

    func testAACRequires48kStereoMode() {
        let caps = WFDSinkCapabilities.parse("wfd_audio_codecs: AAC 00000002 00\r\n")
        XCTAssertNil(WFDNegotiatedFormat.choose(sink: caps, prefs: StreamPreferences()).audio)
    }

    func testTransportClientPorts() {
        XCTAssertEqual(RTSPTransport.clientPorts("RTP/AVP/UDP;unicast;client_port=19000")?.rtp, 19000)
        let both = RTSPTransport.clientPorts("RTP/AVP/UDP;unicast;client_port=1028-1029;mode=play")
        XCTAssertEqual(both?.rtp, 1028)
        XCTAssertEqual(both?.rtcp, 1029)
        XCTAssertNil(RTSPTransport.clientPorts("RTP/AVP/UDP;unicast"))
    }
}

final class AudioNegotiationTests: XCTestCase {
    func caps(_ audio: String) -> WFDSinkCapabilities {
        WFDSinkCapabilities.parse("wfd_audio_codecs: \(audio)\r\nwfd_client_rtp_ports: RTP/AVP/UDP;unicast 1 0 mode=play\r\n")
    }

    func testPrefersAACThenFallsBackToLPCM() {
        let prefs = StreamPreferences()
        XCTAssertEqual(WFDNegotiatedFormat.choose(sink: caps("LPCM 00000003 00, AAC 00000001 00"), prefs: prefs).audio?.format, "AAC")
        XCTAssertEqual(WFDNegotiatedFormat.choose(sink: caps("LPCM 00000003 00"), prefs: prefs).audio?.descriptor, "LPCM 00000002 00")
        XCTAssertNil(WFDNegotiatedFormat.choose(sink: caps("LPCM 00000001 00"), prefs: prefs).audio, "44.1 kHz only → no audio")
    }

    func testForcedCodec() {
        var prefs = StreamPreferences()
        prefs.audioCodec = .lpcm
        XCTAssertEqual(WFDNegotiatedFormat.choose(sink: caps("LPCM 00000002 00, AAC 00000001 00"), prefs: prefs).audio?.format, "LPCM")
        prefs.audioCodec = .aac
        XCTAssertNil(WFDNegotiatedFormat.choose(sink: caps("LPCM 00000002 00"), prefs: prefs).audio)
    }

    func testDefaultDelays() {
        XCTAssertEqual(MiraController.defaultDelay(WFDAudioCodec(format: "AAC", modes: 1, latency: 0)), 0.2)
        XCTAssertEqual(MiraController.defaultDelay(WFDAudioCodec(format: "LPCM", modes: 2, latency: 0)), 0.15)
        XCTAssertEqual(MiraController.defaultDelay(nil), 0.12)
    }
}

final class UpdateCheckerTests: XCTestCase {
    func testVersionOrdering() {
        XCTAssertTrue(UpdateChecker.isNewer("0.2.1", than: "0.2.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0", than: "0.2.0-beta.1"))
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0-beta.2", than: "0.2.0-beta.1"))
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0-beta.10", than: "0.2.0-beta.9"))
        XCTAssertFalse(UpdateChecker.isNewer("0.2.0-beta.1", than: "0.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.2.0", than: "0.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0", than: "dev"), "source builds (version \"dev\") see any release as newer")
    }
}
