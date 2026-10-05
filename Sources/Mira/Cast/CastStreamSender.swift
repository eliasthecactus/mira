import Foundation
import CommonCrypto

// One Cast Streaming RTP stream (audio or video), the sender side of openscreen's
// sender_impl.cc: frame encryption, packetizing, ACK/NACK handling, retransmission,
// kickstarts and RTCP sender reports. Pure logic; the transport owns socket and clock.
//
// RTP header (12 bytes) + Cast header:
//   byte 12: K (key frame) | R (reference frame ID present) | extension count
//   byte 13: frame ID (lower 8 bits)
//   bytes 14-15: packet ID, 16-17: last packet ID, 18: reference frame ID (lower 8 bits)
final class CastStreamSender {

    struct Config {
        var ssrc: UInt32
        var receiverSSRC: UInt32
        var payloadType: UInt8
        var timeBase: Int
        var targetDelay: Double          // seconds
        var aesKey: [UInt8]
        var aesIvMask: [UInt8]
        var isVideo: Bool
    }

    struct Frame {
        var id: Int64
        var rtpTimestamp: Int64          // in time base ticks
        var referenceTime: Double        // capture time, host clock
        var isKey: Bool
        var referencedID: Int64
        var payload: [UInt8]             // encrypted
        var sentTimes: [Double?]         // per packet
        var needsSend: [Bool]
    }

    static let maxPacketSize = 1500 - 20 - 8    // IPv4 + UDP on Ethernet
    static let headerSize = 19
    static var maxPayload: Int { maxPacketSize - headerSize }
    static let maxUnackedFrames: Int64 = 120

    let config: Config
    private var frames: [Int64: Frame] = [:]
    private(set) var lastEnqueued: Int64 = -1
    private(set) var checkpoint: Int64 = -1      // all frames <= this are received
    private var latestExpected: Int64 = -1       // receiver knows about frames up to this
    private var lastKeyEnqueued: Int64 = -1
    private var awaitingKeyframe = false         // a frame was dropped: only a keyframe can follow
    private var sequence = UInt16.random(in: 0...UInt16.max)
    private(set) var roundTripTime: Double = 0
    private var reportTimes: [UInt32: Double] = [:]   // SR id (middle NTP bits) -> send time
    private(set) var lastSR: (rtp: Int64, time: Double)?
    private(set) var packetsSent: UInt64 = 0
    private(set) var octetsSent: UInt64 = 0
    private(set) var retransmissions: UInt64 = 0
    private(set) var framesDropped = 0
    var onPictureLost: (() -> Void)?
    var onLoss: ((Double) -> Void)?

    init(config: Config) {
        self.config = config
    }

    var framesInFlight: Int { frames.count }

    // MARK: - Enqueue

    enum EnqueueResult: Equatable { case ok, dropped, needsKeyframe }

    // `rtpTimestamp` must increase from frame to frame.
    func enqueue(_ data: Data, rtpTimestamp: Int64, referenceTime: Double, isKey: Bool, now: Double) -> EnqueueResult {
        if awaitingKeyframe && !isKey {
            framesDropped += 1
            return .needsKeyframe
        }
        // Too far ahead of the receiver: drop rather than build a backlog.
        let oldestInFlight = frames.values.min { $0.id < $1.id }
        let inFlight = oldestInFlight.map { Double(rtpTimestamp - $0.rtpTimestamp) / Double(config.timeBase) } ?? 0
        if lastEnqueued + 1 - checkpoint > Self.maxUnackedFrames || inFlight > maxInFlightDuration {
            framesDropped += 1
            if config.isVideo {
                awaitingKeyframe = true
                return .needsKeyframe
            }
            return .dropped
        }
        if let last = frames[lastEnqueued], rtpTimestamp <= last.rtpTimestamp { return .dropped }

        let id = lastEnqueued + 1
        let referenced = (isKey || !config.isVideo) ? id : id - 1
        let encrypted = Self.crypt([UInt8](data), frameID: id, key: config.aesKey, ivMask: config.aesIvMask)
        let count = max(1, (encrypted.count + Self.maxPayload - 1) / Self.maxPayload)
        guard count < 0xFFFF else { return .dropped }
        frames[id] = Frame(id: id, rtpTimestamp: rtpTimestamp, referenceTime: referenceTime, isKey: isKey,
                           referencedID: referenced, payload: encrypted,
                           sentTimes: Array(repeating: nil, count: count), needsSend: Array(repeating: true, count: count))
        lastEnqueued = id
        if isKey {
            lastKeyEnqueued = id
            awaitingKeyframe = false
        }
        if rtpTimestamp > (lastFrameTimestamp?.rtp ?? Int64.min) { lastFrameTimestamp = (rtpTimestamp, referenceTime) }
        return .ok
    }
    private var lastFrameTimestamp: (rtp: Int64, time: Double)?

    // Media allowed in flight before new frames are dropped: most of the playout delay.
    var maxInFlightDuration: Double { max(0.1, config.targetDelay * 0.8) }

    // MARK: - Packets

    // Next packet to (re)send, oldest frame first.
    func nextPacket(now: Double) -> Data? {
        for id in (checkpoint + 1)...max(checkpoint + 1, lastEnqueued) {
            guard var f = frames[id], let p = f.needsSend.firstIndex(of: true) else { continue }
            if f.sentTimes[p] != nil { retransmissions += 1 }
            f.needsSend[p] = false
            f.sentTimes[p] = now
            frames[id] = f
            return packet(f, p)
        }
        return nil
    }

    // When the receiver hasn't acknowledged knowing about the newest frame, resend its
    // last packet after a while: the only way it can learn the frame exists.
    func kickstart(now: Double) -> Data? {
        guard latestExpected < lastEnqueued, var f = frames[lastEnqueued],
              !f.needsSend.contains(true), let sent = f.sentTimes.last ?? nil else { return nil }
        let interval = max(config.targetDelay / 20, roundTripTime * 2)
        guard now >= sent + interval else { return nil }
        f.sentTimes[f.sentTimes.count - 1] = now
        frames[lastEnqueued] = f
        return packet(f, f.sentTimes.count - 1)
    }

    func packet(_ f: Frame, _ packetID: Int) -> Data {
        let count = f.sentTimes.count
        let start = packetID * Self.maxPayload
        let end = min(f.payload.count, start + Self.maxPayload)
        var b = [UInt8]()
        b.reserveCapacity(Self.headerSize + end - start)
        b.append(0x80)
        b.append((packetID == count - 1 ? 0x80 : 0) | (config.payloadType & 0x7F))
        b.append(UInt8(sequence >> 8)); b.append(UInt8(sequence & 0xFF))
        sequence &+= 1
        let ts = UInt32(truncatingIfNeeded: f.rtpTimestamp)
        b += [UInt8(ts >> 24), UInt8(ts >> 16 & 0xFF), UInt8(ts >> 8 & 0xFF), UInt8(ts & 0xFF)]
        let s = config.ssrc
        b += [UInt8(s >> 24), UInt8(s >> 16 & 0xFF), UInt8(s >> 8 & 0xFF), UInt8(s & 0xFF)]
        b.append((f.isKey ? 0x80 : 0) | 0x40)                     // K, R, no extensions
        b.append(UInt8(truncatingIfNeeded: f.id))
        b.append(UInt8(packetID >> 8)); b.append(UInt8(packetID & 0xFF))
        b.append(UInt8((count - 1) >> 8)); b.append(UInt8((count - 1) & 0xFF))
        b.append(UInt8(truncatingIfNeeded: f.referencedID))
        if start < end { b += f.payload[start..<end] }
        packetsSent += 1
        octetsSent += UInt64(end - start)
        return Data(b)
    }

    // MARK: - RTCP sender report

    // RTCP SR mapping "now" on the host clock to the stream's RTP time.
    func senderReport(now: Double, ntp: (Double) -> UInt64) -> Data? {
        guard let anchor = lastFrameTimestamp else { return nil }
        let rtp = anchor.rtp + Int64(((now - anchor.time) * Double(config.timeBase)).rounded())
        let ntpTime = ntp(now)
        reportTimes[UInt32(truncatingIfNeeded: ntpTime >> 16)] = now
        if reportTimes.count > 64, let oldest = reportTimes.min(by: { $0.value < $1.value }) {
            reportTimes.removeValue(forKey: oldest.key)
        }
        var d = Data(capacity: 28)
        d.append(0x80); d.append(200)
        d.appendBE(UInt16(6))
        d.appendBE(config.ssrc)
        d.appendBE(UInt32(ntpTime >> 32))
        d.appendBE(UInt32(ntpTime & 0xFFFF_FFFF))
        d.appendBE(UInt32(truncatingIfNeeded: rtp))
        d.appendBE(UInt32(truncatingIfNeeded: packetsSent))
        d.appendBE(UInt32(truncatingIfNeeded: octetsSent))
        lastSR = (rtp, now)
        return d
    }

    // MARK: - RTCP from the receiver

    // Handles one compound RTCP packet addressed to this stream.
    func handleRTCP(_ packet: Data, now: Double) {
        let b = [UInt8](packet)
        var i = 0
        while i + 4 <= b.count {
            let count = Int(b[i] & 0x1F)
            let type = b[i + 1]
            let length = (Int(b[i + 2]) << 8 | Int(b[i + 3])) * 4
            let start = i + 4, end = start + length
            guard end <= b.count else { return }
            let body = Array(b[start..<end])
            switch type {
            case 201: receiverReport(body, count: count, now: now)
            case 206 where count == 1: pictureLoss(body)
            case 206 where count == 15: feedback(body, now: now)
            default: break
            }
            i = end
        }
    }

    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    private func receiverReport(_ b: [UInt8], count: Int, now: Double) {
        guard b.count >= 4 + 24, count >= 1, Self.u32(b, 0) == config.receiverSSRC,
              Self.u32(b, 4) == config.ssrc else { return }
        let fractionLost = Double(b[8]) / 256
        onLoss?(fractionLost)
        let lsr = Self.u32(b, 20), dlsr = Double(Self.u32(b, 24)) / 65536
        if let sent = reportTimes[lsr] {
            let measured = max(0.000075, now - sent - dlsr)
            let clamped = min(measured, config.targetDelay)
            if roundTripTime == 0 { roundTripTime = clamped }
            else if clamped > roundTripTime { roundTripTime = (roundTripTime + clamped) / 2 }
            else { roundTripTime = (7 * roundTripTime + clamped) / 8 }
        }
    }

    private func pictureLoss(_ b: [UInt8]) {
        guard b.count >= 8, Self.u32(b, 0) == config.receiverSSRC, Self.u32(b, 4) == config.ssrc else { return }
        // A keyframe already on its way will fix it.
        if checkpoint < lastKeyEnqueued { return }
        onPictureLost?()
    }

    // Cast feedback: checkpoint (all frames up to it complete), NACKs, ACK bit vector.
    private func feedback(_ b: [UInt8], now: Double) {
        guard b.count >= 16, Self.u32(b, 0) == config.receiverSSRC, Self.u32(b, 4) == config.ssrc,
              Self.u32(b, 8) == 0x4341_5354 /* CAST */ else { return }
        guard lastEnqueued >= 0 else { return }
        let newCheckpoint = Self.expandLessOrEqual(b[12], max: lastEnqueued)
        let lossFields = Int(b[13])
        if newCheckpoint > checkpoint {
            for id in (checkpoint + 1)...newCheckpoint { frames.removeValue(forKey: id) }
            checkpoint = newCheckpoint
        }
        latestExpected = max(latestExpected, newCheckpoint)

        var i = 16
        var nacked: [(Int64, Int?)] = []      // packet nil = all packets
        for _ in 0..<lossFields {
            guard i + 4 <= b.count else { return }
            let frameID = Self.expandGreater(b[i], than: newCheckpoint)
            let packetID = Int(b[i + 1]) << 8 | Int(b[i + 2])
            var bits = b[i + 3]
            i += 4
            if packetID == 0xFFFF {
                nacked.append((frameID, nil))
            } else {
                nacked.append((frameID, packetID))
                var p = packetID
                while bits != 0 {
                    p += 1
                    if bits & 1 != 0 { nacked.append((frameID, p)) }
                    bits >>= 1
                }
            }
        }
        // Optional ACK bit vector ('CST2'), starting at checkpoint + 2.
        if i + 6 <= b.count, Self.u32(b, i) == 0x4353_5432 {
            let octets = Int(b[i + 5])
            var frameID = newCheckpoint + 2
            for k in 0..<octets where i + 6 + k < b.count {
                var bits = b[i + 6 + k]
                var id = frameID
                while bits != 0 {
                    if bits & 1 != 0, id <= lastEnqueued {
                        frames.removeValue(forKey: id)
                        latestExpected = max(latestExpected, id)
                    }
                    id += 1
                    bits >>= 1
                }
                frameID += 8
            }
        }
        if !nacked.isEmpty {
            Log.debug("Cast", "\(config.isVideo ? "video" : "audio") NACK: \(nacked.map { "\($0.0):\($0.1.map(String.init) ?? "all")" }.joined(separator: " ")) (checkpoint \(newCheckpoint), last \(lastEnqueued))")
        }
        // Retransmit, but not packets sent less than a round trip ago (still in transit).
        let tooRecent = now - roundTripTime
        for (frameID, packetID) in nacked where frameID <= lastEnqueued {
            latestExpected = max(latestExpected, frameID)
            guard var f = frames[frameID] else { continue }
            let range = packetID.map { [$0] } ?? Array(0..<f.sentTimes.count)
            for p in range where p < f.sentTimes.count {
                if let sent = f.sentTimes[p], sent <= tooRecent { f.needsSend[p] = true }
            }
            frames[frameID] = f
        }
    }

    // 8-bit frame ID -> the largest ID <= max with those low bits.
    static func expandLessOrEqual(_ low: UInt8, max: Int64) -> Int64 {
        let candidate = (max & ~0xFF) | Int64(low)
        return candidate <= max ? candidate : candidate - 256
    }

    // 8-bit frame ID -> the smallest ID > than with those low bits.
    static func expandGreater(_ low: UInt8, than: Int64) -> Int64 {
        let candidate = (than & ~0xFF) | Int64(low)
        return candidate > than ? candidate : candidate + 256
    }

    // MARK: - Encryption

    // AES-128-CTR; nonce = IV mask XOR (frame ID, big-endian, at bytes 8...11).
    static func crypt(_ data: [UInt8], frameID: Int64, key: [UInt8], ivMask: [UInt8]) -> [UInt8] {
        var nonce = ivMask
        let id = UInt32(truncatingIfNeeded: frameID)
        nonce[8] ^= UInt8(id >> 24); nonce[9] ^= UInt8(id >> 16 & 0xFF)
        nonce[10] ^= UInt8(id >> 8 & 0xFF); nonce[11] ^= UInt8(id & 0xFF)
        var cryptor: CCCryptorRef?
        guard CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                      CCPadding(ccNoPadding), nonce, key, key.count, nil, 0, 0,
                                      CCModeOptions(kCCModeOptionCTR_BE), &cryptor) == kCCSuccess,
              let cryptor else { return data }
        defer { CCCryptorRelease(cryptor) }
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        CCCryptorUpdate(cryptor, data, data.count, &out, out.count, &moved)
        return out
    }
}
