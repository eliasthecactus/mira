import Foundation
import Network

// For "connect by IP": which protocol does the device at this address speak?
// Tries the Google Cast port (8009) and the MS-MICE port (7250) in parallel.
enum DeviceProbe {
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
