import Foundation

// Minimal logger: concise lines on stderr, full detail (incl. every RTSP message)
// in ~/Library/Logs/Mira/mira.log so a failed session against real hardware can
// be diagnosed after the fact.
enum Log {
    enum Level: Int { case debug = 0, info, warn, error }

    static var consoleLevel: Level = .info
    static let logFileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Mira", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mira.log")
    }()

    private static let queue = DispatchQueue(label: "mira.log")
    static var previousLogFileURL: URL { logFileURL.deletingPathExtension().appendingPathExtension("1.log") }

    private static var fileHandle: FileHandle? = {
        let url = logFileURL
        // Keep the log bounded: rotate to mira.1.log once it passes 10 MB.
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int, size > 10 << 20 {
            try? FileManager.default.removeItem(at: previousLogFileURL)
            try? FileManager.default.moveItem(at: url, to: previousLogFileURL)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        h?.seekToEndOfFile()
        return h
    }()
    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func debug(_ tag: String, _ msg: @autoclosure () -> String) { write(.debug, tag, msg()) }
    static func info(_ tag: String, _ msg: @autoclosure () -> String) { write(.info, tag, msg()) }
    static func warn(_ tag: String, _ msg: @autoclosure () -> String) { write(.warn, tag, msg()) }
    static func error(_ tag: String, _ msg: @autoclosure () -> String) { write(.error, tag, msg()) }

    private static func write(_ level: Level, _ tag: String, _ msg: String) {
        let now = Date()
        queue.async {
            let prefix = level == .warn ? "WARN " : level == .error ? "ERROR " : ""
            let line = "\(timestamp.string(from: now)) [\(tag)] \(prefix)\(msg)\n"
            fileHandle?.write(Data(line.utf8))
            if level.rawValue >= consoleLevel.rawValue {
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
    }

    static func flush() { queue.sync { try? fileHandle?.synchronize() } }
}

extension Data {
    mutating func appendBE(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xFF)) }
    mutating func appendBE(_ v: UInt32) {
        append(UInt8(v >> 24)); append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF)); append(UInt8(v & 0xFF))
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
}
