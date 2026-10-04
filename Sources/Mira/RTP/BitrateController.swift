import Foundation

// Adapts the video bitrate to the Wi-Fi link (AIMD, like TCP congestion control):
//   • back off to 70 % on packet loss reported by the sink (RTCP receiver reports),
//     on local send congestion, or when the sink asks for IDR frames (decoder lost data)
//   • creep back up by 8 % after 4 s without trouble, never above the configured maximum
// The sink isn't required to send RTCP, so the local signals matter most in practice.
final class BitrateController {

    struct Config {
        var initial: Int
        var minimum: Int
        var maximum: Int
    }

    var onChange: ((Int) -> Void)?

    let config: Config
    private(set) var current: Int
    private var lastDecrease = Date.distantPast
    private var lastTrouble = Date.distantPast
    private var lastIncrease = Date()
    private let decreaseFactor = 0.7
    private let increaseFactor = 1.08
    private let calmPeriod: TimeInterval = 4
    private let decreaseCooldown: TimeInterval = 1.5

    init(config: Config) {
        self.config = config
        current = min(max(config.initial, config.minimum), config.maximum)
    }

    enum Signal: CustomStringConvertible {
        case loss(fraction: Double)      // RTCP fraction lost, 0…1
        case sendCongestion(backlog: Int)
        case idrRequest

        var description: String {
            switch self {
            case .loss(let f): return String(format: "%.1f%% packet loss", f * 100)
            case .sendCongestion(let b): return "send backlog \(b) packets"
            case .idrRequest: return "display requested a keyframe"
            }
        }
    }

    private var idrRequests: [Date] = []

    func report(_ signal: Signal, now: Date = Date()) {
        switch signal {
        case .loss(let f) where f < 0.02:
            return                          // ≤2 % is normal Wi-Fi noise
        case .idrRequest:
            // Sinks often ask for one keyframe at startup; only repeated requests mean loss.
            idrRequests = idrRequests.filter { now.timeIntervalSince($0) < 10 } + [now]
            guard idrRequests.count >= 2 else { return }
        default:
            break
        }
        lastTrouble = now
        guard now.timeIntervalSince(lastDecrease) >= decreaseCooldown else { return }
        let factor: Double
        if case .loss(let f) = signal, f > 0.15 { factor = 0.5 } else { factor = decreaseFactor }
        set(Int(Double(current) * factor), reason: "↓ \(signal)", now: now)
        lastDecrease = now
    }

    // Call about once a second.
    func tick(now: Date = Date()) {
        guard current < config.maximum,
              now.timeIntervalSince(lastTrouble) >= calmPeriod,
              now.timeIntervalSince(lastIncrease) >= 1 else { return }
        set(Int(Double(current) * increaseFactor), reason: "↑ link is clean", now: now)
        lastIncrease = now
    }

    private func set(_ value: Int, reason: String, now: Date) {
        let clamped = min(max(value, config.minimum), config.maximum)
        guard clamped != current else { return }
        current = clamped
        Log.info("Bitrate", String(format: "%.1f Mbit/s (%@)", Double(clamped) / 1_000_000, reason))
        onChange?(clamped)
    }
}

// RTCP receiver/sender report blocks (RFC 3550 §6.4).
struct RTCPReportBlock: Equatable {
    var ssrc: UInt32
    var fractionLost: Double
    var cumulativeLost: Int32
    var highestSequence: UInt32
    var jitter: UInt32

    // Parses a compound RTCP packet and returns all report blocks from SR/RR packets.
    static func parse(_ data: Data) -> [RTCPReportBlock] {
        let b = [UInt8](data)
        var out: [RTCPReportBlock] = []
        var i = 0
        while i + 4 <= b.count {
            guard b[i] >> 6 == 2 else { break }
            let count = Int(b[i] & 0x1F)
            let pt = b[i + 1]
            let length = (((Int(b[i + 2]) << 8) | Int(b[i + 3])) + 1) * 4
            guard length > 0, i + length <= b.count else { break }
            // RR: header(4) + sender SSRC(4); SR adds 20 bytes of sender info.
            var j = i + 8 + (pt == 200 ? 20 : 0)
            if pt == 200 || pt == 201 {
                for _ in 0..<count where j + 24 <= i + length {
                    let ssrc = UInt32(b[j]) << 24 | UInt32(b[j + 1]) << 16 | UInt32(b[j + 2]) << 8 | UInt32(b[j + 3])
                    let lostRaw = Int32(b[j + 5]) << 16 | Int32(b[j + 6]) << 8 | Int32(b[j + 7])
                    let lost = lostRaw & 0x800000 != 0 ? lostRaw - 0x1000000 : lostRaw
                    let seq = UInt32(b[j + 8]) << 24 | UInt32(b[j + 9]) << 16 | UInt32(b[j + 10]) << 8 | UInt32(b[j + 11])
                    let jitter = UInt32(b[j + 12]) << 24 | UInt32(b[j + 13]) << 16 | UInt32(b[j + 14]) << 8 | UInt32(b[j + 15])
                    out.append(RTCPReportBlock(ssrc: ssrc, fractionLost: Double(b[j + 4]) / 256,
                                               cumulativeLost: lost, highestSequence: seq, jitter: jitter))
                    j += 24
                }
            }
            i += length
        }
        return out
    }
}
