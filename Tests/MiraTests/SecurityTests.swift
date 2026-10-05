import XCTest
@testable import Mira

final class MICESecurityTests: XCTestCase {

    // [MS-MICE] 3.1.5.6.1 test vectors.
    func testPINHashSpecVectors() {
        XCTAssertEqual(MICEMessage.pinHash(pin: "12345678", senderIP: "192.0.2.100")?.hexString,
                       "60 54 09 f8 32 30 8a d0 b8 93 a7 f9 1b e4 2b 26 4c 73 72 b3 6e 90 77 50 6e 1b 4c c1 83 de 79 da")
        XCTAssertEqual(MICEMessage.pinHash(pin: "98765432", senderIP: "2001:db8:1f::4242")?.hexString,
                       "b3 45 2b 2c 46 c8 3d 28 d8 d4 64 b6 69 7a 81 d1 af 3f 35 61 07 e1 d0 73 1e a9 bb 18 38 03 f9 c7")
        XCTAssertNil(MICEMessage.pinHash(pin: "1", senderIP: "not-an-ip"))
    }

    // [MS-MICE] 4.6 PIN Challenge message example, byte for byte.
    func testPINChallengeMatchesSpecExample() {
        let hash = MICEMessage.pinHash(pin: "12345678", senderIP: "192.0.2.100")!
        let sourceID = Data([0x91, 0xF4, 0xAB, 0xE9, 0xEF, 0xF5, 0x46, 0x4A, 0xAE, 0xE2, 0x69, 0x72, 0x2A, 0xED, 0x11, 0xB5])
        let bytes = [UInt8](MICEMessage.pinChallenge(pinHash: hash, sourceID: sourceID).serialize())
        let expected: [UInt8] = [0x00, 0x3A, 0x01, 0x05, 0x06, 0x00, 0x20] + [UInt8](hash) + [0x03, 0x00, 0x10] + [UInt8](sourceID)
        XCTAssertEqual(bytes, expected)
    }

    func testSessionRequestSecurityOptions() throws {
        let msg = MICEMessage.sessionRequest(friendlyName: "Mac", sourceID: Data(count: 16),
                                             options: [.streamEncryption, .sinkDisplaysPin])
        var buf = msg.serialize()
        let parsed = try XCTUnwrap(try MICEMessage.extract(from: &buf))
        XCTAssertEqual(parsed.command, 0x04)
        XCTAssertEqual(parsed.value(.securityOptions), Data([0x03]), "bit A (encryption) + bit B (sink displays PIN)")
        XCTAssertEqual(parsed.friendlyName, "Mac")
    }

    func testSecurityHandshakeCarriesTokenAndSourceID() throws {
        let token = Data([0x16, 0xFE, 0xFD, 0x00, 0x00])
        var buf = MICEMessage.securityHandshake(token: token, sourceID: Data([7])).serialize()
        let parsed = try XCTUnwrap(try MICEMessage.extract(from: &buf))
        XCTAssertEqual(parsed.command, 0x03)
        XCTAssertEqual(parsed.securityToken, token)
        XCTAssertEqual(parsed.value(.sourceID)?.count, 16)
    }

    func testEncryptedFrameRoundTrip() throws {
        // An encrypted TLVArray is opaque: header stays plain, body is the DTLS record.
        let record = Data([0x17, 0xFE, 0xFD] + [UInt8](repeating: 0xAB, count: 40))
        var buf = MICEMessage.serialize(command: 0x01, body: record) + Data([0x00])   // + start of next message
        let frame = try XCTUnwrap(try MICEMessage.extractFrame(from: &buf))
        XCTAssertEqual(frame.command, 0x01)
        XCTAssertEqual(frame.body, record)
        XCTAssertEqual(buf, Data([0x00]))
    }

    func testPINResponseParsing() throws {
        let tlvs = try MICEMessage.parseTLVs(Data([0x07, 0x00, 0x01, 0x01, 0x03, 0x00, 0x00]))
        let msg = MICEMessage(command: 0x06, tlvs: tlvs)
        XCTAssertEqual(msg.pinResponseReason, .wrongPIN)
        XCTAssertThrowsError(try MICEMessage.parseTLVs(Data([0x07, 0x00, 0x05, 0x00])))
    }

    func testDTLSRecordDescription() {
        // ServerHello (handshake type 2) in an epoch-0 record.
        var rec: [UInt8] = [22, 0xFE, 0xFD, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2]
        rec += [23, 0xFE, 0xFD, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(DTLSTunnel.describe(Data(rec)), "[Handshake ServerHello, AppData]")
    }
}

final class AdaptiveBitrateTests: XCTestCase {
    let config = BitrateController.Config(initial: 8_000_000, minimum: 2_000_000, maximum: 12_000_000)

    func testBacksOffOnLossButIgnoresNoise() {
        let c = BitrateController(config: config)
        let t0 = Date()
        c.report(.loss(fraction: 0.01), now: t0)
        XCTAssertEqual(c.current, 8_000_000, "<=2 % loss is Wi-Fi noise")
        c.report(.loss(fraction: 0.05), now: t0)
        XCTAssertEqual(c.current, 5_600_000)
        c.report(.loss(fraction: 0.05), now: t0.addingTimeInterval(0.5))
        XCTAssertEqual(c.current, 5_600_000, "cooldown between decreases")
        c.report(.loss(fraction: 0.30), now: t0.addingTimeInterval(2))
        XCTAssertEqual(c.current, 2_800_000, "heavy loss halves")
        c.report(.sendCongestion(backlog: 500), now: t0.addingTimeInterval(4))
        XCTAssertEqual(c.current, 2_000_000, "never below the minimum")
    }

    func testSingleIDRRequestIsNotCongestion() {
        let c = BitrateController(config: config)
        let t0 = Date()
        c.report(.idrRequest, now: t0)
        XCTAssertEqual(c.current, 8_000_000)
        c.report(.idrRequest, now: t0.addingTimeInterval(3))
        XCTAssertEqual(c.current, 5_600_000)
    }

    func testRampsUpOnlyAfterCalmPeriodAndCapsAtMaximum() {
        let c = BitrateController(config: config)
        let t0 = Date()
        c.report(.loss(fraction: 0.1), now: t0)                       // 5.6
        c.tick(now: t0.addingTimeInterval(2))
        XCTAssertEqual(c.current, 5_600_000, "no increase within 4 s of trouble")
        var t = t0.addingTimeInterval(4)
        for _ in 0..<40 { c.tick(now: t); t += 1 }
        XCTAssertEqual(c.current, 12_000_000)
    }
}

final class RTCPTests: XCTestCase {
    func testParsesReceiverReport() {
        var rr = Data([0x81, 201, 0x00, 0x07])
        rr.appendBE(UInt32(0x11111111))             // reporter SSRC
        rr.appendBE(UInt32(0xDEADBEEF))             // source SSRC
        rr.append(64)                               // fraction lost = 64/256 = 25 %
        rr.append(contentsOf: [0x00, 0x01, 0x2C])   // cumulative lost = 300
        rr.appendBE(UInt32(70_000)); rr.appendBE(UInt32(12)); rr.appendBE(UInt32(0)); rr.appendBE(UInt32(0))
        let blocks = RTCPReportBlock.parse(rr)
        XCTAssertEqual(blocks, [RTCPReportBlock(ssrc: 0xDEADBEEF, fractionLost: 0.25, cumulativeLost: 300,
                                                highestSequence: 70_000, jitter: 12)])
    }

    func testIgnoresGarbageAndOwnSenderReports() {
        XCTAssertEqual(RTCPReportBlock.parse(Data([0xFF, 0x00, 0x00])), [])
        let sr = RTCPSender(ssrc: 1).senderReport(.init(rtpTimestamp: 1, packets: 2, octets: 3))
        XCTAssertEqual(RTCPReportBlock.parse(sr), [], "an SR with RC=0 carries no report blocks")
    }
}
