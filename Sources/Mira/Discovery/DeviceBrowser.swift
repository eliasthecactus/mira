import Foundation
import Network

final class DeviceBrowser {
    var onDeviceFound: ((MiracastDevice) -> Void)?
    var onDeviceLost: ((String) -> Void)?

    private var browsers: [NWBrowser] = []
    private var resolving: [String: NWBrowser.Result] = [:]
    private let queue = DispatchQueue(label: "mira.discovery")

    // WFD service types used by different Miracast sinks
    private let serviceTypes = ["_wfd._tcp", "_display._tcp", "_miracast._tcp"]

    func start() {
        for type in serviceTypes {
            let params = NWParameters()
            params.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: params)
            browser.browseResultsChangedHandler = { [weak self] results, changes in
                self?.handleChanges(changes)
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .failed(let err):
                    print("[Discovery] Browser \(type) failed: \(err)")
                case .ready:
                    print("[Discovery] Browsing \(type)...")
                default:
                    break
                }
            }
            browser.start(queue: queue)
            browsers.append(browser)
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
    }

    private func handleChanges(_ changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case .added(let result):
                resolve(result)
            case .removed(let result):
                if case .service(let name, _, _, _) = result.endpoint {
                    onDeviceLost?(name)
                }
            default:
                break
            }
        }
    }

    private func resolve(_ result: NWBrowser.Result) {
        guard case .service(let name, _, _, _) = result.endpoint else { return }

        let resolveParams = NWParameters.tcp
        let conn = NWConnection(to: result.endpoint, using: resolveParams)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .ready = state {
                if let path = conn.currentPath,
                   let remote = path.remoteEndpoint,
                   case .hostPort(let host, let port) = remote {
                    let ipStr = "\(host)".components(separatedBy: "%").first ?? "\(host)"
                    let device = MiracastDevice(name: name, ipAddress: ipStr, port: port.rawValue)
                    print("[Discovery] Resolved: \(device)")
                    self.onDeviceFound?(device)
                }
                conn.cancel()
            } else if case .failed = state {
                conn.cancel()
            }
        }
        conn.start(queue: queue)
    }
}
