import Foundation

struct MiracastDevice: CustomStringConvertible {
    let name: String
    let ipAddress: String
    let port: UInt16
    let wfdVersion: String

    var description: String { "\(name) @ \(ipAddress):\(port)" }

    init(name: String, ipAddress: String, port: UInt16 = 7236, wfdVersion: String = "1.0") {
        self.name = name
        self.ipAddress = ipAddress
        self.port = port
        self.wfdVersion = wfdVersion
    }
}
