import Foundation
import Network
import FleetKit
import HostKit

/// Reported in `host.info`. A constant bumped with the wire, as on Linux (`hostdVersion` in
/// LinuxHostd.swift): a tool inside the app's `Contents/MacOS` has no `Bundle.main` of its own
/// to read a version from, and two hosts of one build must report the same string.
let darwinHostdVersion = "0.1.0"

/// One NWConnection as `HostServerCore` sees it.
///
/// `slot` is the PSK identity the handshake authenticated (`HostTransport.PeerIdentities`),
/// never anything the client sends, because revocation and naming are keyed on it: a slot
/// taken from a frame would let one controller hello as another and survive the other's
/// revoke.
final class DarwinHostPeer: HostPeer, @unchecked Sendable {
    let slot: UUID
    let connection: NWConnection
    /// The core's threading contract: serial per connection and off the delivery queue,
    /// because `host.info` shells out and can take ~7 s. On the listener's queue that would
    /// stall every other connection's handshake and every revoke with it.
    let queue: DispatchQueue

    init(slot: UUID, connection: NWConnection) {
        self.slot = slot
        self.connection = connection
        queue = DispatchQueue(label: "hostd.peer.\(slot.uuidString)")
    }

    func send(text: String) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "host", metadata: [meta])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in })
    }

    /// `cancel()` closes the socket, so a revoked controller sees its connection end rather
    /// than merely being refused at its next handshake.
    func close() { connection.cancel() }
}

/// The macOS host: `HostServerCore` over FleetKit's TLS-PSK WebSocket listener, a
/// host-profile `PairingListener` for pairing windows, and the user-only admin socket.
///
/// Mirrors `LinuxHostd` (Packages/HostDaemonLinux), which is the reference for every rule
/// here; where the two differ it is because Network.framework does.
///
/// Threading: `queue` owns the listener, its connections, the pairing listener and every
/// table below. The admin handler runs on the admin socket's accept thread and the core's
/// callbacks on per-peer queues; both reach this state only through `queue`.
final class DarwinHostServer: @unchecked Sendable {
    static let serviceType = "_fd-host._tcp"

    let root: URL
    private let requestedPort: NWEndpoint.Port?
    private let hostName: @Sendable () -> String
    private let store: ControllerStore
    private let core: HostServerCore
    /// Internal, not private, for one test: closing the code behind a live listener's back is
    /// the only way to reach `paired`'s no-longer-live branch without racing a real expiry.
    let window = PairingWindow()
    private let queue = DispatchQueue(label: "hostd.listener")
    private let identities: HostTransport.PeerIdentities

    /// Fired on `queue` whenever the number of authenticated connections changes. `main.swift`
    /// holds an idle-sleep assertion only while it is non-zero.
    var onConnectionCountChanged: (@Sendable (Int) -> Void)?

    // Confined to `queue`.
    private var listener: NWListener?
    private var boundPort: NWEndpoint.Port?
    private var peers: [ObjectIdentifier: DarwinHostPeer] = [:]
    /// Slots the listener's keys were last built from, so a store change that only renamed a
    /// controller does not rebind (every new controller's first hello renames it).
    private var keyedSlots: Set<UUID> = []
    private var rebinding = false
    private var rebindAgain = false
    private var pairing: PairingListener?
    private var stopped = false

    private var admin: AdminSocketServer?

    /// Held across a pairing's consume-then-add and by `status`, for `LinuxHostd`'s reason: a
    /// `pair` poll landing between the two would see the window closed and the count
    /// unchanged, and report "expired" for a controller that has just paired.
    private let pairingLock = NSLock()

    /// A handshake that has not finished by then is not a controller on a slow link (the
    /// client gives up first); without this a TCP connect that never speaks TLS holds a
    /// socket for the life of the process.
    private static let handshakeDeadline: TimeInterval = 10

    init(root: URL, port: NWEndpoint.Port?, hostName: @escaping @Sendable () -> String) {
        self.root = root
        requestedPort = port
        self.hostName = hostName
        store = ControllerStore(root: root)
        core = HostServerCore(hostName: hostName,
                              probe: HostInfoProbe(stateRoot: root, hostdVersion: darwinHostdVersion))
        identities = HostTransport.PeerIdentities(queue: queue)
    }

    /// The pairing listener's port while a window is armed. Tests dial it directly; a real
    /// controller finds it through `_fd-host-pair._tcp`.
    var pairingPort: NWEndpoint.Port? {
        queue.sync { pairingBoundPort }
    }
    private var pairingBoundPort: NWEndpoint.Port?

    /// Binds the host listener, then the admin socket, so a `status` that answers implies the
    /// listener is up.
    @discardableResult
    func start() async throws -> NWEndpoint.Port {
        // `AdminSocketServer` refuses a parent another user could write into, and the store
        // keeps every controller's secret here.
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

        store.onChange = { [weak self] in self?.storeChanged() }
        // A newly paired controller is stored as "controller"; its first hello names it.
        core.onControllerName = { [weak self] slot, name in self?.rename(slot: slot, to: name) }

        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                rebinding = true
                bind { result in continuation.resume(with: result) }
            }
        }
        admin = try AdminSocketServer(path: root.appendingPathComponent("admin.sock").path) {
            [weak self] request in self?.handle(request) ?? .failed("hostd is shutting down")
        }
        return port
    }

    /// Not callable from `queue` or from the admin handler (`AdminSocketServer.stop` waits for
    /// its own accept thread).
    func stop() {
        admin?.stop()
        admin = nil
        store.onChange = nil
        core.onControllerName = nil
        queue.sync {
            stopped = true
            pairing?.stop()
            pairing = nil
            pairingBoundPort = nil
            listener?.cancel()
            listener = nil
            for peer in peers.values { peer.connection.cancel() }
            peers.removeAll()
            onConnectionCountChanged?(0)
        }
    }

    // MARK: - Listener

    /// Builds the listener from the store's keys *now*, on `boundPort` once one exists, so a
    /// rebind keeps the port controllers already know.
    private func bind(then done: @escaping @Sendable (Result<NWEndpoint.Port, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        let controllers = store.all()
        keyedSlots = Set(controllers.map(\.slot))
        let keys = controllers.map { FleetDeviceKey(slot: $0.slot, secret: $0.secret) }
        let parameters = HostTransport.listenerParameters(keys: keys, identities: identities)
        let listener: NWListener
        do {
            let port = boundPort ?? requestedPort
            listener = try port.map { try NWListener(using: parameters, on: $0) }
                ?? NWListener(using: parameters)
        } catch {
            return finishBind(.failure(error), done)
        }
        listener.service = NWListener.Service(name: hostName(), type: Self.serviceType)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        self.listener = listener

        // Same single-resume shape and 5 s bound as `FleetSocketServer.bind`: the state
        // handler fires repeatedly, and `.ready` can report the `.any` placeholder before the
        // OS assigns the real port.
        nonisolated(unsafe) var resumed = false
        nonisolated(unsafe) let timeout = DispatchWorkItem { [weak self, weak listener] in
            guard !resumed else { return }
            resumed = true
            listener?.cancel()
            self?.finishBind(.failure(DarwinHostError.didNotBind), done)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard !resumed, let self else { return }
            switch state {
            case .ready:
                guard let port = listener.port, port != .any else { return }
                resumed = true
                timeout.cancel()
                boundPort = port
                finishBind(.success(port), done)
            case .failed(let error):
                resumed = true
                timeout.cancel()
                finishBind(.failure(error), done)
            case .cancelled:
                resumed = true
                timeout.cancel()
                finishBind(.failure(DarwinHostError.didNotBind), done)
            default:
                break
            }
        }
        listener.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    private func finishBind(_ result: Result<NWEndpoint.Port, Error>,
                            _ done: @Sendable (Result<NWEndpoint.Port, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        rebinding = false
        if case .failure(let error) = result {
            FileHandle.standardError.write(Data("hostd: listener did not bind: \(error)\n".utf8))
        }
        done(result)
        if rebindAgain {
            rebindAgain = false
            rebind()
        }
    }

    /// A key change (pair or revoke) rebuilds the listener, because Network.framework fixes a
    /// listener's PSKs when it is created. Serialized: a second change while one rebind waits
    /// for its old listener to go away would otherwise bind beside it and lose to
    /// `EADDRINUSE`, so it is folded into one more rebind that reads the store afresh.
    ///
    /// Live connections are left alone, unlike `FleetSocketServer`'s restart: they belong to
    /// other controllers, and pairing a new one must not cut the rest off. A revoked slot's
    /// connections are closed by `storeChanged` itself.
    private func rebind() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped else { return }
        guard !rebinding else { rebindAgain = true; return }
        rebinding = true
        releaseListener { [weak self] in
            self?.bind { [weak self] result in
                // A port still draining past the 2 s release bound would otherwise leave the
                // host with no listener at all until the next pair or revoke.
                guard case .failure = result, let self else { return }
                queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.rebind() }
            }
        }
    }

    /// `FleetSocketServer.releaseListenerOnQueue`'s wait-for-cancel: `cancel()` releases the
    /// port asynchronously, and rebinding the same port before the OS confirms it regularly
    /// fails with `EADDRINUSE`. Bounded at 2 s, after which the bind's own timeout decides.
    private func releaseListener(then: @escaping @Sendable () -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let listener else { return then() }
        self.listener = nil
        nonisolated(unsafe) var resumed = false
        nonisolated(unsafe) let timeout = DispatchWorkItem {
            guard !resumed else { return }
            resumed = true
            then()
        }
        listener.stateUpdateHandler = { state in
            guard !resumed else { return }
            switch state {
            case .cancelled, .failed:
                resumed = true
                timeout.cancel()
                then()
            default:
                break
            }
        }
        queue.asyncAfter(deadline: .now() + 2, execute: timeout)
        listener.cancel()
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        let id = ObjectIdentifier(connection)
        queue.asyncAfter(deadline: .now() + Self.handshakeDeadline) { [weak self, weak connection] in
            guard let self, let connection, peers[id] == nil else { return }
            if case .ready = connection.state { return }
            connection.cancel()
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready: authenticated(connection)
            case .failed, .cancelled: closed(connection)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func authenticated(_ connection: NWConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        // A record exists for every completed handshake on our listener; a slot no longer in
        // the store is a handshake that raced its own revoke on the listener being replaced.
        guard let slot = identities.slot(of: connection),
              store.all().contains(where: { $0.slot == slot })
        else { return connection.cancel() }
        let peer = DarwinHostPeer(slot: slot, connection: connection)
        peers[ObjectIdentifier(connection)] = peer
        onConnectionCountChanged?(peers.count)
        receive(on: peer)
    }

    private func receive(on peer: DarwinHostPeer) {
        peer.connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil { return peer.connection.cancel() }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            if meta?.opcode == .close { return peer.connection.cancel() }
            if meta?.opcode == .text, let data {
                let text = String(decoding: data, as: UTF8.self)
                peer.queue.async { [core] in core.receive(text: text, from: peer) }
            }
            receive(on: peer)
        }
    }

    private func closed(_ connection: NWConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let peer = peers.removeValue(forKey: ObjectIdentifier(connection)) else { return }
        onConnectionCountChanged?(peers.count)
        // Behind any receive still queued for it: "serially per connection".
        peer.queue.async { [core] in core.peerClosed(peer) }
    }

    // MARK: - Store

    /// Called on whichever thread mutated the store (the admin thread for a revoke, `queue`
    /// for a pairing, a peer queue for a rename), so it only ever hops onto `queue`.
    private func storeChanged() {
        queue.async { [self] in
            guard !stopped else { return }
            let now = Set(store.all().map(\.slot))
            let gone = keyedSlots.subtracting(now)
            // Cut off now, not at the next handshake. The core closes the peers that said
            // hello; our own table also catches a connection of that slot that has not
            // spoken yet, which the core has never heard of.
            for slot in gone { core.disconnect(slot: slot) }
            for peer in peers.values where gone.contains(peer.slot) { peer.connection.cancel() }
            if now != keyedSlots { rebind() }
        }
    }

    private func rename(slot: UUID, to name: String) {
        // Every hello carries the name; an unchanged one is not worth rewriting the secrets
        // file on each reconnect.
        guard !name.isEmpty, store.all().first(where: { $0.slot == slot })?.name != name else { return }
        do { _ = try store.rename(slot: slot, to: name) } catch {
            FileHandle.standardError.write(Data("hostd: could not rename \(slot): \(error)\n".utf8))
        }
    }

    // MARK: - Admin

    /// Runs on the admin socket's accept thread, one request at a time.
    func handle(_ request: AdminRequest) -> AdminReply {
        switch request {
        case .status:
            // Read before taking `pairingLock`, never under it: `paired` holds that lock on
            // `queue`, so waiting on `queue` while holding it would deadlock the two.
            let port = queue.sync { boundPort.map { Int($0.rawValue) } }
            pairingLock.lock(); defer { pairingLock.unlock() }
            return .status(paired: store.all().count, armedUntil: window.current?.expiresAt,
                           listeningPort: port, hostName: hostName())
        case .listControllers:
            return .controllers(store.all().map {
                AdminController(slot: $0.slot, name: $0.name, pairedAt: $0.pairedAt)
            })
        case .revoke(let slot):
            do {
                return try store.revoke(slot: slot) ? .ok : .failed("no controller is paired in slot \(slot)")
            } catch {
                return .failed("could not revoke \(slot): \(error)")
            }
        case .cancelArm:
            pairingLock.lock()
            window.cancel()
            pairingLock.unlock()
            queue.sync { closePairing() }
            return .ok
        case .arm:
            return arm()
        }
    }

    /// A fresh code replaces any armed one (PairingWindow's rule), and the old listener is
    /// stopped before the new one exists, so an abandoned code can never pair. Answers only
    /// once the new listener is bound, so `pairingPort` is valid the moment `arm` returns.
    private func arm() -> AdminReply {
        let code = PairingCode.mint()
        let key = FleetDeviceKey.mint()
        pairingLock.lock()
        let expiresAt = window.arm(codeText: code.formatted)
        pairingLock.unlock()

        let pairing = PairingListener(profile: .host, queue: queue)
        queue.sync {
            closePairing()
            self.pairing = pairing
            pairing.onPaired = { [weak self, weak pairing] in
                guard let self, let pairing else { return }
                paired(key, code: code, by: pairing)
            }
            pairing.onAttemptsExhausted = { [weak self, weak pairing] in
                guard let self, let pairing else { return }
                FileHandle.standardError.write(Data("hostd: pairing code burned after \(PairingListener.maxAttempts) wrong guesses\n".utf8))
                closeWindow(code: code)
                if self.pairing === pairing { closePairing() }
            }
        }

        let name = hostName()
        let bound = BlockingResult<NWEndpoint.Port>()
        Task {
            do {
                bound.set(.success(try await pairing.start(
                    code: code, key: key, macName: name, serviceName: name, port: nil)))
            } catch {
                bound.set(.failure(error))
            }
        }
        // `PairingListener.start` bounds its own bind at 5 s; this only guards a scheduler
        // that never runs the Task, inside the admin client's own 5 s timeout.
        guard case .success(let port) = bound.wait(timeout: 6) else {
            closeWindow(code: code)
            queue.sync { if self.pairing === pairing { closePairing() } }
            return .failed("could not open the pairing listener")
        }

        queue.sync {
            guard self.pairing === pairing else { return }
            pairingBoundPort = port
            // The window's lifetime is the listener's: an expired code must stop answering,
            // not only stop showing in `status`.
            queue.asyncAfter(deadline: .now() + max(0, expiresAt.timeIntervalSinceNow)) {
                [weak self, weak pairing] in
                guard let self, let pairing, self.pairing === pairing else { return }
                closePairing()
            }
        }
        return .armed(code: code.formatted, expiresAt: expiresAt)
    }

    /// The sealed key is already out when this runs: the Darwin `PairingListener` fires
    /// `onPaired` from the seal's send completion and offers no gate before it, so a window
    /// cannot refuse a late exchange *before* delivering the key. `LinuxHostd` has the same
    /// shape and simply stores nothing then, which leaves a controller holding a key that its
    /// host silently never accepts. So the window is consumed and the controller stored here,
    /// together, under `pairingLock`; and when the
    /// code is no longer live (expired, replaced or cancelled while the exchange was in
    /// flight) the just-sealed slot is revoked at once, so the key the controller now holds
    /// opens nothing even for a connection already mid-handshake.
    private func paired(_ key: FleetDeviceKey, code: PairingCode, by pairing: PairingListener) {
        dispatchPrecondition(condition: .onQueue(queue))
        pairingLock.lock()
        let live = window.consume(codeText: code.formatted)
        var stored = false
        if live {
            do {
                try store.add(PairedController(slot: key.slot, name: "controller",
                                               secret: key.secret, pairedAt: Date()))
                stored = true
            } catch {
                FileHandle.standardError.write(Data("hostd: paired, but could not store the controller: \(error)\n".utf8))
            }
        }
        pairingLock.unlock()
        if stored {
            FileHandle.standardError.write(Data("hostd: paired controller in slot \(key.slot)\n".utf8))
        } else {
            if !live {
                FileHandle.standardError.write(Data("hostd: pairing finished after its code was no longer live; revoked slot \(key.slot)\n".utf8))
            }
            core.disconnect(slot: key.slot)
            _ = try? store.revoke(slot: key.slot)
        }
        if self.pairing === pairing { closePairing() }
    }

    /// A burned or unbindable window must stop advertising itself through `status`, or `pair`
    /// would keep showing a code that can no longer pair. Only if it is still this code's.
    private func closeWindow(code: PairingCode) {
        pairingLock.lock(); defer { pairingLock.unlock() }
        if window.current?.code == code.formatted { window.cancel() }
    }

    private func closePairing() {
        dispatchPrecondition(condition: .onQueue(queue))
        pairing?.stop()
        pairing = nil
        pairingBoundPort = nil
    }
}

enum DarwinHostError: Error {
    case didNotBind
}

/// A one-shot result handed from a Task to a thread that blocks on it: the admin handler is
/// synchronous by contract, and `PairingListener.start` is async.
private final class BlockingResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var result: Result<Value, Error>?

    func set(_ value: Result<Value, Error>) {
        lock.lock(); result = value; lock.unlock()
        ready.signal()
    }

    func wait(timeout: TimeInterval) -> Result<Value, Error>? {
        guard ready.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return result
    }
}
