import Foundation

// A Miracast-over-Infrastructure sink. `port` is the MS-MICE signalling port
// (7250), not RTSP - in MICE the sink connects to *our* RTSP port.
struct MiracastDevice: CustomStringConvertible, Equatable {
    static let defaultMICEPort: UInt16 = 7250

    let name: String
    let ipAddress: String
    let port: UInt16
    var containerID: String? = nil

    var description: String { "\(name) @ \(ipAddress):\(port)" }

    init(name: String, ipAddress: String, port: UInt16 = MiracastDevice.defaultMICEPort, containerID: String? = nil) {
        self.name = name
        self.ipAddress = ipAddress
        self.port = port
        self.containerID = containerID
    }
}
