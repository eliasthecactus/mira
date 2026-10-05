import Foundation
import Network

// For "connect by IP": which protocol does the device at this address speak?
// Tries the Google Cast port (8009) and the MS-MICE port (7250) in parallel.
enum DeviceProbe {
    // This Mac's IPv4 address on the interface that reaches `host` (no packet is sent).
    static func localAddress(toward host: String) -> String? {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return nil }
        defer { close(s) }
        var dest = DTLSTunnel.address(host, 9)
        let ok = withUnsafePointer(to: &dest) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { return nil }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &local, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(s, $0, &len) } }) == 0 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &local.sin_addr, &buf, socklen_t(buf.count))
        return String(cString: buf)
    }

    static func kind(of host: String, timeout: TimeInterval = 2, completion: @escaping (MiracastDevice.Kind?) -> Void) {
        let queue = DispatchQueue(label: "mira.probe")
        var answered = false
        var pending = 2
        func finish(_ kind: MiracastDevice.Kind?) {
            queue.async {
                if let kind, !answered {
                    answered = true
                    completion(kind)
                    return
                }
                pending -= 1
                if pending == 0, !answered {
                    answered = true
                    completion(nil)
                }
            }
        }
        for kind in [MiracastDevice.Kind.googleCast, .miracast] {
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: kind.defaultPort)!, using: .tcp)
            var done = false
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !done else { return }
                    done = true
                    conn.cancel()
                    finish(kind)
                case .failed, .waiting:
                    guard !done else { return }
                    done = true
                    conn.cancel()
                    finish(nil)
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                guard !done else { return }
                done = true
                conn.cancel()
                finish(nil)
            }
        }
    }
}
