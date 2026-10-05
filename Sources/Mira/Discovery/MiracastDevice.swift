import Foundation

// A display Mira can stream to: a Miracast-over-Infrastructure sink, where `port` is
// the MS-MICE signalling port (7250, not RTSP - in MICE the sink connects to *our*
// RTSP port), or a Google Cast device (port 8009).
struct MiracastDevice: CustomStringConvertible, Equatable {
    enum Kind: String, CaseIterable {
        case miracast
        case googleCast = "cast"

        var defaultPort: UInt16 { self == .miracast ? MiracastDevice.defaultMICEPort : CastChannel.defaultPort }
        var label: String { self == .miracast ? "Miracast" : "Google Cast" }
    }

    static let defaultMICEPort: UInt16 = 7250

    let name: String
    let ipAddress: String
    let port: UInt16
    var containerID: String? = nil
    var kind: Kind = .miracast
    var model: String? = nil
    var serviceName: String = ""       // DNS-SD instance name (identity for add/remove)

    var description: String { "\(name) @ \(ipAddress):\(port)\(kind == .googleCast ? " (Google Cast)" : "")" }

    init(name: String, ipAddress: String, port: UInt16? = nil, containerID: String? = nil,
         kind: Kind = .miracast, model: String? = nil, serviceName: String? = nil) {
        self.name = name
        self.ipAddress = ipAddress
        self.port = port ?? kind.defaultPort
        self.containerID = containerID
        self.kind = kind
        self.model = model
        self.serviceName = serviceName ?? name
    }
}
