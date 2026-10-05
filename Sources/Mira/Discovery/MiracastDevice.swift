import Foundation

// A display Mira can stream to: a Miracast-over-Infrastructure sink, where `port` is
// the MS-MICE signalling port (7250, not RTSP - in MICE the sink connects to *our*
// RTSP port), a Google Cast device (port 8009), or a DLNA media renderer (a smart TV's
// built-in media player; `location` is its UPnP device description).
struct MiracastDevice: CustomStringConvertible, Equatable {
    enum Kind: String, CaseIterable {
        case miracast
        case googleCast = "cast"
        case dlna
        case airplay        // shown with a hint: macOS mirrors to these itself

        var defaultPort: UInt16 {
            switch self {
            case .miracast: return MiracastDevice.defaultMICEPort
            case .googleCast: return CastChannel.defaultPort
            case .dlna, .airplay: return 0
            }
        }
        var label: String {
            switch self {
            case .miracast: return "Miracast"
            case .googleCast: return "Google Cast"
            case .dlna: return "DLNA"
            case .airplay: return "AirPlay"
            }
        }
    }

    static let defaultMICEPort: UInt16 = 7250

    let name: String
    let ipAddress: String
    let port: UInt16
    var containerID: String? = nil
    var kind: Kind = .miracast
    var model: String? = nil
    var serviceName: String = ""       // DNS-SD instance name / UPnP UDN (identity for add/remove)
    var location: URL? = nil           // DLNA device description

    var description: String { "\(name) @ \(ipAddress)\(port > 0 ? ":\(port)" : "")\(kind == .miracast ? "" : " (\(kind.label))")" }

    init(name: String, ipAddress: String, port: UInt16? = nil, containerID: String? = nil,
         kind: Kind = .miracast, model: String? = nil, serviceName: String? = nil, location: URL? = nil) {
        self.name = name
        self.ipAddress = ipAddress
        self.port = port ?? kind.defaultPort
        self.containerID = containerID
        self.kind = kind
        self.model = model
        self.serviceName = serviceName ?? name
        self.location = location
    }
}
