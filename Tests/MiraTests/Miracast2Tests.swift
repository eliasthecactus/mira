import XCTest
import CoreGraphics
@testable import Mira

// Miracast R2 (wfd2_video_formats), Microsoft wfdx_video_formats and HEVC.
final class Miracast2NegotiationTests: XCTestCase {

    // Windows' own sink, as captured by lazycast (d2win10debug.py).
    let windowsSink = WFDSinkCapabilities.parse("""
    wfd_video_formats: 00 00 03 10 0001ffff 1fffffff 00001fff 00 0000 0000 10 none none\r
    wfd_audio_codecs: LPCM 00000003 00, AAC 0000000f 00\r
    wfd2_video_formats: 40 01 04 0080 000001ffbdeb 000155557fff 000000000fff 10 0000 001f 11, 01 01 0080 000001ffbdeb 0001555557ff 000000000fff 10 0000 001f 11 00\r
    wfd2_audio_codecs: LPCM 000001ff 00\r
    wfd_client_rtp_ports: RTP/AVP/UDP;unicast 1028 0 mode=play\r
    wfd_uibc_capability: input_category_list=HIDC;hidc_cap_list=Keyboard/USB, Mouse/USB, MultiTouch/USB, Gesture/USB, RemoteControl/USB, Joystick/USB;port=none\r

    """)

    // A sink with H.264 up to 1080p and HEVC Main up to 4K30 (level 5.1).
    let hevcSink = WFDSinkCapabilities.parse("""
    wfd_video_formats: 00 00 01 10 000001ff 00000000 00000000 00 0000 0000 00 none none\r
    wfd_audio_codecs: AAC 00000001 00\r
    wfd2_video_formats: 00 01 01 0010 0000000181ff 000000000000 000000000000 00 0000 0000 00, 02 01 0010 0000000f81ff 000000000000 000000000000 00 0000 0000 00 00\r
    wfd2_audio_codecs: AAC 00000001 00, LPCM 00000002 00\r
    wfd_client_rtp_ports: RTP/AVP/UDP;unicast 1028 0 mode=play\r

    """)

    // Windows 10 v1511 style: wfdx with CBP + HEVC Main at level 5.1, 1080p30 and 3840x2160p30/p60.
    let wfdxSink = WFDSinkCapabilities.parse("""
    wfd_video_formats: 00 00 01 10 000001ff 00000000 00000000 00 0000 0000 00 none none\r
    wfd_audio_codecs: LPCM 00000003 00\r
    wfdx_video_formats: 0000 00 0005 0040 0000060080 0000000000 00000000 00 0000 0000 11 none none\r
    wfd_client_rtp_ports: RTP/AVP/UDP;unicast 1028 0 mode=play\r

    """)

    func testParsesWindowsR2Formats() throws {
        let v = try XCTUnwrap(windowsSink.videoFormats)
        XCTAssertEqual(v.flavor, .r2)
        XCTAssertEqual(v.codecs.count, 2)
        XCTAssertEqual(v.codecs[0].codec, .h264)
        XCTAssertEqual(v.codecs[0].h264Profiles, [.restrictedHigh2])
        XCTAssertEqual(v.codecs[1].h264Profiles, [.constrainedBaseline])
        XCTAssertEqual(v.codecs[1].maxLevelBit, 0x80)
        XCTAssertEqual(v.codecs[1].frameRateControl, 0x11)
        XCTAssertTrue(v.codecs[1].supports(WFDResolution.find(width: 3840, height: 2160, fps: 30, flavor: .r2)!))
        XCTAssertEqual(windowsSink.audioParameter, "wfd2_audio_codecs")
        XCTAssertEqual(windowsSink.uibc?.categories, ["HIDC"])
        XCTAssertNotNil(windowsSink.r1VideoFormats)
    }

    func testWindows4KUsesR2WithBaseline() {
        var prefs = StreamPreferences()
        prefs.resolution = .p2160
        let n = WFDNegotiatedFormat.choose(sink: windowsSink, prefs: prefs)
        XCTAssertEqual(n.resolution.description, "3840x2160p30")
        XCTAssertEqual(n.codec, .h264, "this sink has no HEVC")
        XCTAssertEqual(n.h264Profile, .constrainedBaseline)
        XCTAssertEqual(n.levelBit, 0x40)
        XCTAssertEqual(n.videoFormatsDescriptor, "00 01 01 0040 000000080000 000000000000 000000000000 00 0000 0000 00 00")
        let body = n.m4Body(presentationURL: "rtsp://10.0.0.2/wfd1.0/streamid=0")
        XCTAssertTrue(body.hasPrefix("wfd2_video_formats: 00 01 01 0040 "))
        XCTAssertTrue(body.contains("wfd2_audio_codecs: LPCM 00000002 00\r\n"))
        XCTAssertFalse(body.contains("wfd_video_formats"), "an R2 M4 must not mix in R1 video formats")
        XCTAssertFalse(body.contains("wfd_audio_codecs"))
    }

    func testR1BitsAbove16AreNot4K() {
        // Bits 17-21 are reserved in R1; a sink setting them must not get 4K over R1.
        var prefs = StreamPreferences()
        prefs.resolution = .p2160
        let r1Only = WFDSinkCapabilities.parse("wfd_video_formats: 00 00 02 80 003fffff 00000000 00000000 00 0000 0000 00 none none\r\nwfd_client_rtp_ports: RTP/AVP/UDP;unicast 1 0 mode=play\r\n")
        let n = WFDNegotiatedFormat.choose(sink: r1Only, prefs: prefs)
        XCTAssertEqual(n.resolution.description, "1920x1080p30")
        XCTAssertEqual(n.flavor, .r1)
        XCTAssertEqual(n.videoFormatsDescriptor, "00 00 02 04 00000080 00000000 00000000 00 0000 0000 00 none none")
    }

    func testHEVCFor4KAndH264For1080p() {
        var prefs = StreamPreferences()
        prefs.resolution = .p2160
        let k4 = WFDNegotiatedFormat.choose(sink: hevcSink, prefs: prefs)
        XCTAssertEqual(k4.resolution.description, "3840x2160p30")
        XCTAssertEqual(k4.codec, .h265)
        XCTAssertEqual(k4.levelBit, 0x10, "HEVC announces the sink's max level (5.1)")
        XCTAssertEqual(k4.maxBitrate, 40_000_000)
        XCTAssertEqual(k4.videoFormatsDescriptor, "00 02 01 0010 000000080000 000000000000 000000000000 00 0000 0000 00 00")
        XCTAssertEqual(k4.audioParameter, "wfd2_audio_codecs")

        let hd = WFDNegotiatedFormat.choose(sink: hevcSink, prefs: StreamPreferences())
        XCTAssertEqual(hd.resolution.description, "1920x1080p30")
        XCTAssertEqual(hd.codec, .h264)
        XCTAssertEqual(hd.levelBit, 0x04)

        prefs.resolution = .p1080
        prefs.codec = .hevc
        let hevc1080 = WFDNegotiatedFormat.choose(sink: hevcSink, prefs: prefs)
        XCTAssertEqual(hevc1080.codec, .h265)
        XCTAssertEqual(hevc1080.levelBit, 0x10)
    }

    func testCodecH264FallsBackToHEVCOnlyWhenNeeded() {
        var prefs = StreamPreferences()
        prefs.resolution = .p2160
        prefs.codec = .h264
        // H.264 tops out at 1080p on this sink: 4K needs HEVC even though H.264 is preferred.
        let n = WFDNegotiatedFormat.choose(sink: hevcSink, prefs: prefs)
        XCTAssertEqual(n.resolution.description, "3840x2160p30")
        XCTAssertEqual(n.codec, .h265)
    }

    func testLegacyFormatsIgnoresR2() {
        var prefs = StreamPreferences()
        prefs.resolution = .p2160
        prefs.legacyFormats = true
        let n = WFDNegotiatedFormat.choose(sink: hevcSink, prefs: prefs)
        XCTAssertEqual(n.flavor, .r1)
        XCTAssertEqual(n.codec, .h264)
        XCTAssertEqual(n.resolution.description, "1920x1080p30")
        XCTAssertTrue(n.m4Body(presentationURL: "rtsp://x").contains("wfd_audio_codecs: AAC"))
        XCTAssertFalse(prefs.m3Parameters.contains("wfd2_video_formats"))
    }

    func testWfdxHEVCUsesMicrosoftNumbering() throws {
        let v = try XCTUnwrap(wfdxSink.videoFormats)
        XCTAssertEqual(v.flavor, .wfdx)
        XCTAssertEqual(v.codecs.map(\.codec), [.h264, .h265])
        // wfdx bit 17 = 3840x2160p30, bit 18 = p60 (different from the WFA table).
        XCTAssertEqual(WFDResolution.find(width: 3840, height: 2160, fps: 30, flavor: .wfdx)?.bit, 17)
        XCTAssertEqual(WFDResolution.find(width: 3840, height: 2160, fps: 30, flavor: .r2)?.bit, 19)

        var prefs = StreamPreferences()
        prefs.resolution = .p2160
        let n = WFDNegotiatedFormat.choose(sink: wfdxSink, prefs: prefs)
        XCTAssertEqual(n.codec, .h265)
        XCTAssertEqual(n.resolution.description, "3840x2160p30")
        XCTAssertEqual(n.levelBit, 0x40, "the sink's max level on the shared wfdx bitmap")
        XCTAssertEqual(n.maxBitrate, 40_000_000)
        XCTAssertEqual(n.videoFormatsDescriptor, "0000 00 0004 0040 0000020000 0000000000 00000000 00 0000 0000 00 none none")
        let body = n.m4Body(presentationURL: "rtsp://x")
        XCTAssertTrue(body.hasPrefix("wfdx_video_formats: "))
        XCTAssertTrue(body.contains("wfd_audio_codecs: LPCM 00000002 00"))
        XCTAssertFalse(body.contains("wfd_video_formats"))
    }

    func testM3AsksForR2AndUIBCOnlyWhenEnabled() {
        var prefs = StreamPreferences()
        XCTAssertEqual(Array(prefs.m3Parameters.prefix(4)), StreamPreferences.basicM3Parameters)
        XCTAssertTrue(prefs.m3Parameters.contains("wfd2_video_formats"))
        XCTAssertTrue(prefs.m3Parameters.contains("wfdx_video_formats"))
        XCTAssertFalse(prefs.m3Parameters.contains("wfd_uibc_capability"))
        prefs.uibcPort = 7239
        prefs.extraM3Parameters = StreamPreferences.wfd2ProbeParameters
        XCTAssertTrue(prefs.m3Parameters.contains("wfd_uibc_capability"))
        XCTAssertEqual(Set(prefs.m3Parameters).count, prefs.m3Parameters.count, "no duplicates")
    }

    func testUIBCInM4AndFallbacks() throws {
        var prefs = StreamPreferences()
        prefs.uibcPort = 7239
        let n = WFDNegotiatedFormat.choose(sink: windowsSink, prefs: prefs)
        let uibc = try XCTUnwrap(n.uibc)
        XCTAssertEqual(uibc.hidc, ["Keyboard/USB", "Mouse/USB", "MultiTouch/USB"])
        let body = n.m4Body(presentationURL: "rtsp://x")
        XCTAssertTrue(body.contains("wfd_uibc_capability: input_category_list=HIDC;generic_cap_list=none;hidc_cap_list=Keyboard/USB, Mouse/USB, MultiTouch/USB;port=7239\r\n"))
        XCTAssertTrue(body.contains("wfd_uibc_setting: enable\r\n"))

        let fallbacks = WFDNegotiatedFormat.fallbacks(after: n, sink: windowsSink, prefs: prefs)
        XCTAssertEqual(fallbacks.count, 2)
        XCTAssertNil(fallbacks[0].uibc)
        XCTAssertEqual(fallbacks[0].flavor, .r2)
        XCTAssertEqual(fallbacks[1].flavor, .r1)
        XCTAssertNil(fallbacks[1].uibc)
    }

    func testH265LevelTable() {
        func level(_ w: Int, _ h: Int, _ f: Int) -> UInt16 {
            WFDResolution(width: w, height: h, fps: f, table: .cea, bit: 0).requiredH265LevelBit
        }
        XCTAssertEqual(level(1280, 720, 30), 0x01)    // 3.1
        XCTAssertEqual(level(1920, 1080, 30), 0x02)   // 4
        XCTAssertEqual(level(1920, 1080, 60), 0x04)   // 4.1
        XCTAssertEqual(level(3840, 2160, 30), 0x08)   // 5
        XCTAssertEqual(level(3840, 2160, 60), 0x10)   // 5.1
    }
}

final class HEVCBitstreamTests: XCTestCase {
    func testAccessUnitHasAUDAndParameterSetsOnce() {
        let vps = Data([0x40, 0x01, 0x0C]), sps = Data([0x42, 0x01, 0x01]), pps = Data([0x44, 0x01, 0xC1])
        let idr = Data([0x26, 0x01, 0xAF])
        let au = HEVCBitstream.annexB(nalus: [vps, sps, pps, idr], parameterSets: [vps, sps, pps])
        let sc: [UInt8] = [0, 0, 0, 1]
        XCTAssertEqual([UInt8](au), sc + [0x46, 0x01, 0x50] + sc + [UInt8](vps) + sc + [UInt8](sps) + sc + [UInt8](pps) + sc + [UInt8](idr))
        XCTAssertEqual(HEVCBitstream.nalType(Data(HEVCBitstream.accessUnitDelimiter)), 35)
        XCTAssertEqual(HEVCBitstream.nalType(idr), 19)
    }

    func testPMTSignalsHEVC() {
        let pmt = [UInt8](MPEGTSMuxer(audio: .aac, hevc: true).psiPackets()[1])
        let len = Int(pmt[6] & 0x0F) << 8 | Int(pmt[7])
        let section = Array(pmt[5..<(8 + len)])
        XCTAssertEqual(MPEGTSMuxer.crc32MPEG(section), 0)
        XCTAssertNotNil(Data(section).range(of: Data([0x24, 0xF0, 0x11])), "stream_type 0x24 on PID 0x1011")
        XCTAssertNil(Data(section).range(of: Data([0x1B, 0xF0, 0x11])))
    }
}

final class UIBCTests: XCTestCase {

    func testCapabilityParsingIsLenient() throws {
        let win = try XCTUnwrap(UIBCCapability.parse("input_category_list=HIDC;hidc_cap_list=Keyboard/USB, Mouse/USB, MultiTouch/USB, Gesture/USB;port=none"))
        XCTAssertEqual(win.categories, ["HIDC"])
        XCTAssertEqual(win.generic, [])
        XCTAssertNil(win.port)
        let mc = try XCTUnwrap(UIBCCapability.parse("input_category_list=GENERIC;generic_cap_list=Mouse,SingleTouch;hidc_cap_list=none;port=none"))
        XCTAssertEqual(mc.generic, ["Mouse", "SingleTouch"])
        XCTAssertEqual(mc.hidc, [])
        XCTAssertNil(UIBCCapability.parse("none"))
        XCTAssertNil(UIBCCapability.parse("input_category_list=GENERIC;generic_cap_list=Camera;hidc_cap_list=none;port=none")?.accepted(port: 1))

        let ours = try XCTUnwrap(mc.accepted(port: 7239))
        XCTAssertEqual(ours.descriptor, "input_category_list=GENERIC;generic_cap_list=Mouse, SingleTouch;hidc_cap_list=none;port=7239")
        XCTAssertEqual(UIBCCapability.parse(ours.descriptor), ours)
    }

    func testParsesSpecTouchExampleAcrossSplitReads() {
        // Worked example: single touch down at (960, 540), padded to 14 bytes.
        let frame: [UInt8] = [0x00, 0x00, 0x00, 0x0E, 0x00, 0x00, 0x06, 0x01, 0x00, 0x03, 0xC0, 0x02, 0x1C, 0x00]
        XCTAssertEqual(UIBCParser.genericTouch(.down, [UIBCPointer(id: 0, x: 960, y: 540)]), Data(frame))
        var p = UIBCParser()
        XCTAssertEqual(p.feed(Data(frame[0..<5])), [])
        XCTAssertEqual(p.feed(Data(frame[5...]) + Data(frame[0..<3])), [.touch(.down, [UIBCPointer(id: 0, x: 960, y: 540)])])
        XCTAssertEqual(p.feed(Data(frame[3...])), [.touch(.down, [UIBCPointer(id: 0, x: 960, y: 540)])])
        XCTAssertEqual(p.framesParsed, 2)
    }

    func testParsesHIDCWithTimestampAndPadding() {
        // lazycast's mouse descriptor registration header: T=1, HIDC, USB, Mouse, descriptor.
        let descriptor: [UInt8] = Array(repeating: 0x05, count: 51)
        var frame: [UInt8] = [0x10, 0x01, 0x00, 0x3E, 0x2A, 0xB6, 0x01, 0x01, 0x01, 0x00, 0x33]
        frame += descriptor
        var p = UIBCParser()
        XCTAssertEqual(p.feed(Data(frame)), [.hid(path: 1, type: 1, isDescriptor: true, value: Data(descriptor))])
        // lazycast live mouse report: 16 bytes with one pad byte.
        let report: [UInt8] = [0x00, 0x01, 0x00, 0x10, 0x01, 0x01, 0x00, 0x00, 0x06, 0x28, 0x01, 0x05, 0xFB, 0x00, 0x00, 0x00]
        XCTAssertEqual(p.feed(Data(report)), [.hid(path: 1, type: 1, isDescriptor: false, value: Data([0x28, 0x01, 0x05, 0xFB, 0x00, 0x00]))])
    }

    func testGenericKeysAndScroll() {
        let t = UIBCTranslator(streamWidth: 1920, streamHeight: 1080)
        XCTAssertEqual(t.translate(.key(down: true, code1: 0x41, code2: 0)), [.text("A")])
        XCTAssertEqual(t.translate(.key(down: false, code1: 0x41, code2: 0)), [])
        XCTAssertEqual(t.translate(.key(down: true, code1: 0x0D, code2: 0)), [.key(36, down: true)])
        let scroll = UIBCParser.parseGeneric([6, 0, 2, 0x40, 0x03])        // 3 notches down
        XCTAssertEqual(scroll, [.scroll(vertical: true, unit: .notches, amount: 3)])
        XCTAssertEqual(t.translate(scroll[0]), [.scroll(dy: -3, dx: 0, pixels: false)])
        let up = UIBCParser.parseGeneric([6, 0, 2, 0x60, 0x02])           // 2 notches up
        XCTAssertEqual(t.translate(up[0]), [.scroll(dy: 2, dx: 0, pixels: false)])
    }

    func testGenericTouchBecomesClick() {
        let t = UIBCTranslator(streamWidth: 1920, streamHeight: 1080)
        XCTAssertEqual(t.translate(.touch(.down, [UIBCPointer(id: 0, x: 960, y: 540)])),
                       [.moveTo(x: 0.5, y: 0.5), .button(.left, down: true)])
        XCTAssertEqual(t.translate(.touch(.move, [UIBCPointer(id: 0, x: 0, y: 1080)])), [.moveTo(x: 0, y: 1)])
        XCTAssertEqual(t.translate(.touch(.up, [UIBCPointer(id: 0, x: 0, y: 1080)])),
                       [.moveTo(x: 0, y: 1), .button(.left, down: false)])
    }

    func testBootKeyboardReports() {
        let t = UIBCTranslator(streamWidth: 1920, streamHeight: 1080)
        // Left Shift + 'a' (usage 0x04 -> kVK_ANSI_A = 0), no descriptor sent: boot layout.
        XCTAssertEqual(t.translate(.hid(path: 1, type: 0, isDescriptor: false, value: Data([0x02, 0, 0x04, 0, 0, 0, 0, 0]))),
                       [.modifiers(0x20000), .key(0, down: true)])
        // Add Right Arrow (0x4F -> 124).
        XCTAssertEqual(t.translate(.hid(path: 1, type: 0, isDescriptor: false, value: Data([0x02, 0, 0x04, 0x4F, 0, 0, 0, 0]))),
                       [.key(124, down: true)])
        XCTAssertEqual(t.translate(.hid(path: 1, type: 0, isDescriptor: false, value: Data(repeating: 0, count: 8))),
                       [.modifiers(0), .key(0, down: false), .key(124, down: false)])
        // Phantom state is ignored.
        XCTAssertEqual(t.translate(.hid(path: 1, type: 0, isDescriptor: false, value: Data([0, 0, 1, 1, 1, 1, 1, 1]))), [])
    }

    func testMouseWithReportIDDescriptor() {
        // Like lazycast's: report ID 0x28, 3 buttons, relative X/Y/wheel.
        let desc: [UInt8] = [0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, 0x28, 0x09, 0x01, 0xA1, 0x00, 0x05, 0x09, 0x19, 0x01,
                             0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01, 0x81, 0x02, 0x95, 0x01, 0x75, 0x05,
                             0x81, 0x03, 0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08,
                             0x95, 0x03, 0x81, 0x06, 0xC0, 0xC0]
        let t = UIBCTranslator(streamWidth: 1920, streamHeight: 1080)
        XCTAssertEqual(t.translate(.hid(path: 1, type: 1, isDescriptor: true, value: Data(desc))), [])
        XCTAssertEqual(t.translate(.hid(path: 1, type: 1, isDescriptor: false, value: Data([0x28, 0x02, 0x03, 0x04, 0xFF]))),
                       [.moveBy(dx: 3, dy: 4), .button(.right, down: true), .scroll(dy: -1, dx: 0, pixels: false)])
        XCTAssertEqual(t.translate(.hid(path: 1, type: 1, isDescriptor: false, value: Data([0x28, 0x00, 0xFB, 0x00, 0x00]))),
                       [.moveBy(dx: -5, dy: 0), .button(.right, down: false)])
        XCTAssertEqual(t.releaseAll(), [])
    }

    func testTouchScreenDescriptor() {
        // Digitizer touch screen, one finger: tip switch, contact ID, 16-bit absolute X/Y (0...32767).
        let desc: [UInt8] = [0x05, 0x0D, 0x09, 0x04, 0xA1, 0x01, 0x85, 0x01, 0x09, 0x22, 0xA1, 0x02,
                             0x09, 0x42, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x01, 0x81, 0x02,
                             0x75, 0x07, 0x81, 0x03, 0x09, 0x51, 0x75, 0x08, 0x25, 0x0A, 0x81, 0x02,
                             0x05, 0x01, 0x26, 0xFF, 0x7F, 0x75, 0x10, 0x09, 0x30, 0x81, 0x02, 0x09, 0x31, 0x81, 0x02,
                             0xC0, 0xC0]
        let parsed = HIDReportDescriptor(desc)
        XCTAssertTrue(parsed.usesReportIDs)
        let t = UIBCTranslator(streamWidth: 1920, streamHeight: 1080)
        _ = t.translate(.hid(path: 1, type: 3, isDescriptor: true, value: Data(desc)))
        let down = t.translate(.hid(path: 1, type: 3, isDescriptor: false, value: Data([0x01, 0x01, 0x03, 0xFF, 0x7F, 0x00, 0x00])))
        XCTAssertEqual(down, [.moveTo(x: 1, y: 0), .button(.left, down: true)])
        let move = t.translate(.hid(path: 1, type: 3, isDescriptor: false, value: Data([0x01, 0x01, 0x03, 0x00, 0x00, 0xFF, 0x7F])))
        XCTAssertEqual(move, [.moveTo(x: 0, y: 1)])
        let up = t.translate(.hid(path: 1, type: 3, isDescriptor: false, value: Data([0x01, 0x00, 0x03, 0x00, 0x00, 0xFF, 0x7F])))
        XCTAssertEqual(up, [.moveTo(x: 0, y: 1), .button(.left, down: false)])
    }

    func testCoordinateMappingInvertsLetterbox() {
        // A 1440x900 (16:10) display in a 1920x1080 stream: pillarboxed, 96 px bars.
        let r = InputInjector.Region(content: CGRect(x: 1440, y: 0, width: 1440, height: 900), streamWidth: 1920, streamHeight: 1080)
        XCTAssertEqual(InputInjector.map(x: 0.5, y: 0.5, region: r), CGPoint(x: 1440 + 720, y: 450))
        XCTAssertEqual(InputInjector.map(x: 96.0 / 1920, y: 0, region: r), CGPoint(x: 1440, y: 0))
        XCTAssertEqual(InputInjector.map(x: 0, y: 0, region: r), CGPoint(x: 1440, y: 0), "bars clamp to the edge")
        XCTAssertEqual(InputInjector.map(x: 1, y: 1, region: r), CGPoint(x: 1440 + 1439, y: 899))
    }
}
