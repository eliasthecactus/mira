import Foundation
import Network

// Live MPEG-TS over HTTP for TV media players (DLNA): the TV fetches
// http://<mac>:<port>/mira.ts and gets an endless stream. Each viewer starts at a
// key frame (which always carries PAT/PMT); slow viewers skip to the next key frame
// instead of building up delay.
final class HTTPStreamTransport: MediaTransport, @unchecked Sendable {   // state confined to `queue`

    var onLoss: ((Double) -> Void)?
    var onKeyframeRequest: (() -> Void)?
    var onViewerCountChanged: ((Int) -> Void)?
    var keyframeRequestsSignalLoss: Bool { false }    // viewers joining, not loss

    static let path = "/mira.ts"
    static let maxBacklog = 6 << 20       // bytes queued to one viewer before it skips ahead

    private final class Viewer {
        let connection: NWConnection
        let id: Int
        var waitingForKeyframe = true
        var inFlight = 0
        init(_ c: NWConnection, id: Int) { connection = c; self.id = id }
    }

    private let queue = DispatchQueue(label: "mira.http", qos: .userInteractive)
    private let muxer: MPEGTSMuxer
    private let ptsDelay: Double
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private var viewers: [Viewer] = []
    private var nextID = 1
    private var baseHost: Double?
    private var paused = false
    private var stopped = false
    private var bytesSent: UInt64 = 0
    private var packetsSent: UInt64 = 0
    private var framesSkipped = 0
    private var skippedReported = 0
    private(set) var everConnected = false

    init(audio: MPEGTSMuxer.AudioFormat?, hevc: Bool = false, ptsDelay: Double = 0.3) {
        muxer = MPEGTSMuxer(audio: audio, hevc: hevc)
        self.ptsDelay = ptsDelay
    }

    var viewerCount: Int { queue.sync { viewers.count } }

    // Binds an ephemeral port (call before telling the TV the URL). Idempotent.
    func start() throws {
        if queue.sync(execute: { listener != nil }) { return }
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options { tcp.noDelay = true }
        let l = try NWListener(using: params, on: .any)
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, let p = l.port?.rawValue else {
            l.cancel()
            throw TransportError.listenFailed
        }
        queue.sync {
            listener = l
            port = p
        }
        Log.info("DLNA", "Serving the live stream on HTTP port \(p)")
    }

    func beginClock(baseHost: Double) {
        queue.sync { self.baseHost = baseHost }
    }

    func sendVideo(_ accessUnit: Data, captureHost: Double, isKeyframe: Bool) -> Bool {
        queue.async { [self] in
            guard let base = baseHost, !paused, !stopped, !viewers.isEmpty else { return }
            let pcr = pcr27M(base)
            let ts = muxer.muxVideo(accessUnit: accessUnit, pts90k: pts90k(captureHost, base), pcr27M: pcr, isKeyframe: isKeyframe)
            broadcast(ts, isKeyframe: isKeyframe, isVideo: true)
        }
        return true
    }

    func sendAudio(_ frame: Data, captureHost: Double) {
        queue.async { [self] in
            guard let base = baseHost, !paused, !stopped, !viewers.isEmpty else { return }
            let pcr = pcr27M(base)
            let ts = muxer.muxAudio(frame, pts90k: pts90k(captureHost, base), pcr27M: pcr)
            broadcast(ts, isKeyframe: false, isVideo: false)
        }
    }

    func setPaused(_ p: Bool) {
        queue.async { self.paused = p }
    }

    func congestion(bitrate: Int) -> BitrateController.Signal? {
        queue.sync {
            defer { skippedReported = framesSkipped }
            return framesSkipped > skippedReported ? .framesDropped(framesSkipped - skippedReported) : nil
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            listener?.cancel(); listener = nil
            viewers.forEach { $0.connection.cancel() }
            viewers.removeAll()
        }
    }

    var counters: TransportCounters {
        queue.sync { TransportCounters(bytesSent: bytesSent, packetsSent: packetsSent) }
    }

    // MARK: - Timing (queue)

    private func pts90k(_ host: Double, _ base: Double) -> UInt64 {
        UInt64(max(0, host - base + ptsDelay + 1.0) * 90_000)
    }

    private func pcr27M(_ base: Double) -> UInt64 {
        UInt64(max(0, MediaPipeline.hostNow() - base + 1.0) * 27_000_000)
    }

    // MARK: - Viewers (queue)

    private func broadcast(_ ts: [Data], isKeyframe: Bool, isVideo: Bool) {
        guard !ts.isEmpty else { return }
        var chunk = Data(capacity: ts.count * MPEGTSMuxer.packetSize)
        for p in ts { chunk.append(p) }
        for v in viewers {
            if v.waitingForKeyframe {
                guard isVideo && isKeyframe else { continue }
                v.waitingForKeyframe = false
                Log.info("DLNA", "Viewer \(v.id) starts at a key frame")
            }
            if v.inFlight > Self.maxBacklog {
                // The TV doesn't keep up: drop what's queued for it and restart at the next key frame.
                v.waitingForKeyframe = true
                framesSkipped += 1
                onKeyframeRequest?()
                continue
            }
            v.inFlight += chunk.count
            v.connection.send(content: chunk, completion: .contentProcessed { [weak self, weak v] err in
                guard let self, let v else { return }
                v.inFlight -= chunk.count
                if err != nil { self.drop(v) }
            })
            bytesSent += UInt64(chunk.count)
            packetsSent += UInt64(ts.count)
        }
    }

    private func accept(_ c: NWConnection) {
        guard !stopped else { c.cancel(); return }
        let v = Viewer(c, id: nextID)
        nextID += 1
        c.stateUpdateHandler = { [weak self, weak v] state in
            guard let self, let v else { return }
            if case .failed = state { self.drop(v) }
            if case .cancelled = state { self.drop(v) }
        }
        c.start(queue: queue)
        readRequest(v, buffer: Data())
    }

    private func readRequest(_ v: Viewer, buffer: Data) {
        v.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if done || err != nil || buf.count > 16384 { v.connection.cancel(); return }
                self.readRequest(v, buffer: buf)
                return
            }
            let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
            self.respond(v, head: head)
        }
    }

    static func responseHeaders(status: String = "200 OK") -> String {
        "HTTP/1.1 \(status)\r\n"
            + "Content-Type: video/mpeg\r\n"
            + "transferMode.dlna.org: Streaming\r\n"
            + "contentFeatures.dlna.org: \(DLNARenderer.liveTSFeatures)\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: close\r\n"
            + "Server: macOS UPnP/1.1 Mira/\(AppInfo.version)\r\n\r\n"
    }

    private func respond(_ v: Viewer, head: String) {
        let request = head.components(separatedBy: "\r\n").first ?? ""
        let parts = request.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let path = parts.count > 1 ? String(parts[1]).components(separatedBy: "?")[0] : ""
        let peer = "\(v.connection.endpoint)"
        guard path == Self.path else {
            v.connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                              completion: .contentProcessed { _ in v.connection.cancel() })
            return
        }
        // Range requests: a live stream has no positions; answer with the stream from now.
        let header = Data(Self.responseHeaders().utf8)
        if method == "HEAD" {
            v.connection.send(content: header, completion: .contentProcessed { _ in v.connection.cancel() })
            Log.info("DLNA", "HEAD from \(peer)")
            return
        }
        guard method == "GET" else { v.connection.cancel(); return }
        v.connection.send(content: header, completion: .contentProcessed { _ in })
        viewers.append(v)
        everConnected = true
        Log.info("DLNA", "Viewer \(v.id) connected from \(peer)")
        onViewerCountChanged?(viewers.count)
        onKeyframeRequest?()          // start them quickly
    }

    private func drop(_ v: Viewer) {
        guard let i = viewers.firstIndex(where: { $0 === v }) else { return }
        viewers.remove(at: i)
        v.connection.cancel()
        Log.info("DLNA", "Viewer \(v.id) disconnected")
        onViewerCountChanged?(viewers.count)
    }

    enum TransportError: LocalizedError {
        case listenFailed
        var errorDescription: String? { "Could not open an HTTP port for the TV" }
    }
}
