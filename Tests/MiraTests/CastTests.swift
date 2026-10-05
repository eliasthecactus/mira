import XCTest
@testable import Mira

final class CastMessageTests: XCTestCase {
    func testProtobufRoundTripAndFraming() throws {
        let m = CastMessage.json(["type": "LAUNCH", "requestId": 2, "appId": "0F5096E8"],
                                 namespace: CastMessage.receiver, from: "sender-0", to: "receiver-0")
        let encoded = m.encode()
        // Field 1 (protocol_version) = 0, then source_id "sender-0".
        XCTAssertEqual(Array(encoded.prefix(4)), [0x08, 0x00, 0x12, 0x08])
        XCTAssertEqual(CastMessage.decode(encoded), m)

        var stream = m.framed() + CastMessage.json(["type": "PING"], namespace: CastMessage.heartbeat,
                                                   from: "a", to: "b").framed()
        let partial = stream.prefix(10)
        var buf = Data(partial)
        XCTAssertEqual(CastMessage.extract(from: &buf)?.count, 0)
        stream = Data(stream)
        let messages = try XCTUnwrap(CastMessage.extract(from: &stream))
        XCTAssertEqual(messages.map(\.type), ["LAUNCH", "PING"])
        XCTAssertTrue(stream.isEmpty)
        XCTAssertEqual(messages[0].json?["appId"] as? String, "0F5096E8")
    }

    func testRejectsOversizedFrames() {
        var buf = Data([0x00, 0x10, 0x00, 0x01]) + Data(repeating: 0, count: 8)
        XCTAssertNil(CastMessage.extract(from: &buf))
    }
}

final class CastNegotiationTests: XCTestCase {
    func testOfferUsesChromeCompatibleFields() throws {
        let offer = CastOffer.make(videoCodecs: [.h264], audioCodecs: [.opus, .aac], width: 1920, height: 1080,
                                   fps: 30, maxBitRate: 10_000_000, targetDelayMs: 250)
        XCTAssertEqual(offer.streams.map(\.index), [0, 1, 2])
        XCTAssertEqual(Set(offer.streams.map(\.ssrc)).count, 3)
        let video = try XCTUnwrap(offer.streams.first { $0.kind == .video })
        let json = video.json
        XCTAssertEqual(json["type"] as? String, "video_source")
        XCTAssertEqual(json["codecName"] as? String, "h264")
        XCTAssertEqual(json["rtpProfile"] as? String, "cast")
        XCTAssertEqual(json["rtpPayloadType"] as? Int, 96)
        XCTAssertEqual(json["timeBase"] as? String, "1/90000")
        XCTAssertEqual((json["aesKey"] as? String)?.count, 32)
        XCTAssertEqual((json["aesIvMask"] as? String)?.count, 32)
        XCTAssertEqual(offer.streams.first { $0.kind == .audio }?.json["rtpPayloadType"] as? Int, 127)
        XCTAssertEqual(offer.json["castMode"] as? String, "mirroring")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: offer.json))
    }

    func testParsesAnswerAndFitsConstraints() throws {
        let message: [String: Any] = [
            "type": "ANSWER", "seqNum": 3, "result": "ok",
            "answer": [
                "udpPort": 2344, "sendIndexes": [0, 1], "ssrcs": [12345, 67890],
                "constraints": ["video": ["maxDimensions": ["width": 1280, "height": 720, "frameRate": "30000/1001"],
                                          "maxBitRate": 4_000_000, "maxPixelsPerSecond": 27_648_000.0]],
                "display": ["dimensions": ["width": 1920, "height": 1080, "frameRate": "60"], "scaling": "sender"],
            ] as [String: Any],
        ]
        let a = try CastAnswer.parse(message).get()
        XCTAssertEqual(a.udpPort, 2344)
        XCTAssertEqual(a.ssrcs, [12345, 67890])
        XCTAssertEqual(a.maxVideoBitRate, 4_000_000)
        XCTAssertEqual(a.maxFrameRate ?? 0, 29.97, accuracy: 0.01)
        let fit = a.fit(width: 1920, height: 1080, fps: 30)
        XCTAssertEqual(fit.width, 1280)
        XCTAssertEqual(fit.height, 720)
        XCTAssertEqual(fit.fps, 29)

        let rejected = CastAnswer.parse(["type": "ANSWER", "result": "error",
                                         "error": ["code": 3, "description": "no codecs"]])
        XCTAssertEqual(rejected, .failure(.answerRejected("no codecs")))
    }
}

final class CastStreamSenderTests: XCTestCase {
    func makeSender(video: Bool = true) -> CastStreamSender {
        CastStreamSender(config: .init(ssrc: 0x1111_1111, receiverSSRC: 0x2222_2222, payloadType: 96,
                                       timeBase: 90_000, targetDelay: 0.25,
                                       aesKey: Array(0..<16), aesIvMask: Array(16..<32), isVideo: video))
    }

    func testPacketHeaderAndEncryption() throws {
        let s = makeSender()
        let plain = Data([0, 0, 0, 1] + Array(repeating: UInt8(7), count: 3000))
        XCTAssertEqual(s.enqueue(plain, rtpTimestamp: 9000, referenceTime: 1, isKey: true, now: 1), .ok)
        var packets: [Data] = []
        while let p = s.nextPacket(now: 1) { packets.append(p) }
        XCTAssertEqual(packets.count, 3)                       // 3004 bytes / 1453 per packet
        let first = [UInt8](packets[0]), last = [UInt8](packets[2])
        XCTAssertEqual(first[0], 0x80)
        XCTAssertEqual(first[1], 96)                            // no marker on packet 0
        XCTAssertEqual(last[1], 0x80 | 96)                      // marker on the last packet
        XCTAssertEqual(CastStreamSender.u32(first, 4), 9000)
        XCTAssertEqual(CastStreamSender.u32(first, 8), 0x1111_1111)
        XCTAssertEqual(first[12], 0xC0)                         // key frame, reference ID present
        XCTAssertEqual(first[13], 0)                            // frame 0
        XCTAssertEqual(Array(first[14...17]), [0, 0, 0, 2])     // packet 0 of 0...2
        XCTAssertEqual(first[18], 0)                            // references itself
        XCTAssertEqual(last[15], 2)
        // AES-CTR is symmetric: decrypting the payload gives the frame back.
        let payload = packets.flatMap { [UInt8]($0.dropFirst(CastStreamSender.headerSize)) }
        XCTAssertNotEqual(Array(payload.prefix(4)), [0, 0, 0, 1])
        XCTAssertEqual(CastStreamSender.crypt(payload, frameID: 0, key: Array(0..<16), ivMask: Array(16..<32)), [UInt8](plain))
        // A different frame ID gives a different key stream.
        XCTAssertNotEqual(CastStreamSender.crypt([UInt8](plain), frameID: 1, key: Array(0..<16), ivMask: Array(16..<32)),
                          CastStreamSender.crypt([UInt8](plain), frameID: 0, key: Array(0..<16), ivMask: Array(16..<32)))
    }

    func testDeltaFramesReferencePreviousAndIDsWrap() {
        XCTAssertEqual(CastStreamSender.expandLessOrEqual(0x05, max: 300), 261)
        XCTAssertEqual(CastStreamSender.expandLessOrEqual(0xFF, max: 2), -1)
        XCTAssertEqual(CastStreamSender.expandGreater(0x02, than: 254), 258)
        XCTAssertEqual(CastStreamSender.expandGreater(0x03, than: -1), 3)
        let s = makeSender()
        _ = s.enqueue(Data([1]), rtpTimestamp: 0, referenceTime: 0, isKey: true, now: 0)
        _ = s.enqueue(Data([2]), rtpTimestamp: 3000, referenceTime: 0.033, isKey: false, now: 0.033)
        _ = s.nextPacket(now: 0.04)
        let second = [UInt8](s.nextPacket(now: 0.04)!)
        XCTAssertEqual(second[12], 0x40)            // not a key frame
        XCTAssertEqual(second[13], 1)
        XCTAssertEqual(second[18], 0)               // references frame 0
    }

    // RTCP: RR + Cast feedback (checkpoint 0, NACK for frame 1 packet 1).
    func feedback(checkpoint: UInt8, nacks: [(UInt8, UInt16)]) -> Data {
        var d = Data()
        d += [0x81, 201, 0, 7]; d.appendBE(UInt32(0x2222_2222))
        d.appendBE(UInt32(0x1111_1111)); d.appendBE(UInt32(0)); d.appendBE(UInt32(0)); d.appendBE(UInt32(0))
        d.appendBE(UInt32(0)); d.appendBE(UInt32(0))
        var body = Data()
        body.appendBE(UInt32(0x2222_2222)); body.appendBE(UInt32(0x1111_1111)); body += Array("CAST".utf8)
        body += [checkpoint, UInt8(nacks.count)]; body.appendBE(UInt16(250))
        for (f, p) in nacks { body.append(f); body.appendBE(p); body.append(0) }
        d += [0x8F, 206]; d.appendBE(UInt16(body.count / 4))
        return d + body
    }

    func testNackRetransmitsAndCheckpointAcks() {
        let s = makeSender()
        let big = Data(repeating: 9, count: 4000)
        _ = s.enqueue(big, rtpTimestamp: 0, referenceTime: 0, isKey: true, now: 0)
        _ = s.enqueue(big, rtpTimestamp: 3000, referenceTime: 0.033, isKey: false, now: 0.033)
        while s.nextPacket(now: 0.04) != nil {}
        XCTAssertEqual(s.framesInFlight, 2)
        s.handleRTCP(feedback(checkpoint: 0, nacks: [(1, 1)]), now: 0.1)
        XCTAssertEqual(s.checkpoint, 0)
        XCTAssertEqual(s.framesInFlight, 1)          // frame 0 acknowledged
        let resent = [UInt8](s.nextPacket(now: 0.1)!)
        XCTAssertEqual(resent[13], 1)
        XCTAssertEqual(Array(resent[14...15]), [0, 1])
        XCTAssertNil(s.nextPacket(now: 0.1))
        XCTAssertEqual(s.retransmissions, 1)
        // "All packets lost" for frame 1 resends the whole frame.
        s.handleRTCP(feedback(checkpoint: 0, nacks: [(1, 0xFFFF)]), now: 0.2)
        var n = 0
        while s.nextPacket(now: 0.2) != nil { n += 1 }
        XCTAssertEqual(n, 3)
    }

    func testPictureLossAndDropsWhenReceiverFallsBehind() {
        let s = makeSender()
        var lost = 0
        s.onPictureLost = { lost += 1 }
        _ = s.enqueue(Data([1]), rtpTimestamp: 0, referenceTime: 0, isKey: true, now: 0)
        while s.nextPacket(now: 0) != nil {}
        var pli = Data([0x81, 206, 0, 2]); pli.appendBE(UInt32(0x2222_2222)); pli.appendBE(UInt32(0x1111_1111))
        s.handleRTCP(pli, now: 0.01)
        XCTAssertEqual(lost, 0, "the key frame is still in flight")
        s.handleRTCP(feedback(checkpoint: 0, nacks: []), now: 0.02)
        s.handleRTCP(pli, now: 0.03)
        XCTAssertEqual(lost, 1)
        // Nothing acknowledged for longer than most of the playout delay: frames are dropped,
        // and after a dropped video frame only a key frame may follow.
        var t: Int64 = 3000
        var result = CastStreamSender.EnqueueResult.ok
        while result == .ok && t < 90_000 {
            result = s.enqueue(Data([2]), rtpTimestamp: t, referenceTime: 0, isKey: false, now: 0)
            t += 3000
        }
        XCTAssertEqual(result, .needsKeyframe)
        XCTAssertEqual(s.enqueue(Data([3]), rtpTimestamp: t, referenceTime: 0, isKey: false, now: 0), .needsKeyframe)
        s.handleRTCP(feedback(checkpoint: UInt8(truncatingIfNeeded: s.lastEnqueued), nacks: []), now: 0.5)
        XCTAssertEqual(s.enqueue(Data([4]), rtpTimestamp: t + 3000, referenceTime: 0, isKey: true, now: 0.5), .ok)
    }
}
