import Foundation
import Network

// The source side of UIBC: listens on a TCP port (announced in M4), accepts the sink's
// single connection and turns what arrives into Mac input.
final class UIBCServer {

    static let preferredPort: UInt16 = 7239

    // True while input must be ignored (privacy pause, stream paused).
    var isSuspended: () -> Bool = { false }
    // Host the connection must come from (the sink); nil accepts any.
    var allowedHost: () -> String? = { nil }

    private let queue = DispatchQueue(label: "mira.uibc", qos: .userInteractive)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var parser = UIBCParser()
    private var translator: UIBCTranslator?
    private var injector: InputInjector?
    private var enabled = true
    private(set) var port: UInt16 = 0
    private var inputs = 0
    private var warnedNoPermission = false

    // Binds the preferred port, or any free one. Returns the port (0 on failure).
    func start() -> UInt16 {
        for candidate in [Self.preferredPort, 0] {
            if let p = listen(on: candidate) { return p }
        }
        Log.warn("UIBC", "Could not open a TCP port; input from the TV is off")
        return 0
    }

    private func listen(on candidate: UInt16) -> UInt16? {
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true   // input must not wait for Nagle
        }
        guard let l = try? NWListener(using: params, on: candidate == 0 ? .any : NWEndpoint.Port(rawValue: candidate)!) else {
            return nil
        }
        let ready = DispatchSemaphore(value: 0)
        var ok = false
        l.stateUpdateHandler = { s in
            switch s {
            case .ready: ok = true; ready.signal()
            case .failed: ready.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success, ok, let p = l.port?.rawValue else {
            l.cancel()
            return nil
        }
        listener = l
        port = p
        Log.info("UIBC", "Listening for input from the TV on TCP \(p)")
        return p
    }

    // Starts turning input into events once the stream size is known.
    func activate(streamWidth: Int, streamHeight: Int, region: @escaping () -> InputInjector.Region?) {
        queue.async { [self] in
            translator = UIBCTranslator(streamWidth: streamWidth, streamHeight: streamHeight)
            injector = InputInjector(region: region)
            if !InputInjector.hasPermission {
                Log.warn("UIBC", "Accessibility permission missing: input from the TV will be ignored by macOS. Grant it in System Settings -> Privacy & Security -> Accessibility.")
            }
        }
    }

    // wfd_uibc_setting from the sink (M15) or the user.
    func setEnabled(_ on: Bool) {
        queue.async { [self] in
            guard on != enabled else { return }
            enabled = on
            if !on { releaseAll() }
            Log.info("UIBC", on ? "Input from the TV enabled" : "Input from the TV disabled")
        }
    }

    func stop() {
        queue.sync {
            releaseAll()
            connection?.cancel(); connection = nil
            listener?.cancel(); listener = nil
            if inputs > 0 { Log.info("UIBC", "Received \(inputs) input events, posted \(injector?.eventsPosted ?? 0)") }
        }
    }

    private func accept(_ c: NWConnection) {
        var host = ""
        if case .hostPort(let h, _) = c.endpoint {
            host = "\(h)".components(separatedBy: "%").first ?? "\(h)"
            if host.hasPrefix("::ffff:") { host = String(host.dropFirst(7)) }
        }
        if let allowed = allowedHost(), !allowed.isEmpty, host != allowed {
            Log.warn("UIBC", "Rejecting input connection from \(host) (sink is \(allowed))")
            c.cancel()
            return
        }
        connection?.cancel()
        releaseAll()
        parser = UIBCParser()
        connection = c
        Log.info("UIBC", "TV connected for input from \(host)")
        c.stateUpdateHandler = { [weak self] s in
            if case .failed(let e) = s { Log.warn("UIBC", "Input connection failed: \(e)"); self?.releaseAll() }
        }
        c.start(queue: queue)
        receive(c)
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self, self.connection === c else { return }
            if let data, !data.isEmpty { self.handle(data) }
            if done || err != nil {
                Log.info("UIBC", "TV closed the input connection")
                self.releaseAll()
                self.connection = nil
                return
            }
            self.receive(c)
        }
    }

    private func handle(_ data: Data) {
        let inputs = parser.feed(data)
        self.inputs += inputs.count
        guard enabled, let translator, let injector else { return }
        if isSuspended() {
            for a in translator.releaseAll() { injector.perform(a) }
            return
        }
        if !InputInjector.hasPermission, !warnedNoPermission {
            warnedNoPermission = true
            Log.warn("UIBC", "Input arrives from the TV but Accessibility permission is missing")
        }
        for input in inputs {
            // Deliberately no logging of keys or positions (privacy).
            for action in translator.translate(input) { injector.perform(action) }
        }
    }

    private func releaseAll() {
        guard let translator, let injector else { return }
        for a in translator.releaseAll() { injector.perform(a) }
    }
}
