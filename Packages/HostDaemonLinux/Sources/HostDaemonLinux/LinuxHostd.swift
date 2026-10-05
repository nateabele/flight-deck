import Foundation
import HostKit
import PairingCore

/// The defaults the CLI contract names (`hostd-install.sh` relies on both).
enum HostdPorts {
    static let serve = 47410
    static let pairing = 47411
}

/// Reported in `host.info`. Bumped by hand with the wire, not derived from git: the container
/// that builds this has no repository metadata to derive it from.
let hostdVersion = "0.1.0"

/// The machine's name as a controller shows it: the hostname without a trailing `.local`, the
/// same trim `HostInfoProbe` applies, so helloAck and host.info agree.
func localHostName() -> String {
    var name = ProcessInfo.processInfo.hostName
    if name.hasSuffix(".local") { name.removeLast(".local".count) }
    return name
}

/// One NIO connection as `HostServerCore` sees it.
///
/// `slot` is the PSK identity the TLS handshake authenticated — never anything the client
/// sends — because it is what revocation and naming are keyed on: a slot taken from a frame
/// would let one controller hello as another and survive the other's revoke.
final class NIOHostPeer: HostPeer, @unchecked Sendable {
    let slot: UUID
    let connection: PSKWebSocketServer.Connection
    /// The core's threading contract: serial per connection, and off the event loop, because
    /// `host.info` shells out and can take ~7 s — on the loop that would stall every other
    /// connection's TLS and pings with it.
    let queue: DispatchQueue

    init(slot: UUID, connection: PSKWebSocketServer.Connection) {
        self.slot = slot
        self.connection = connection
        queue = DispatchQueue(label: "hostd.peer.\(slot.uuidString)")
    }

    func send(text: String) { connection.send(text: text) }
    func close() { connection.close() }
}

/// `serve`: the host core, the controller store, the admin socket and the pairing window, on
/// the NIO TLS-PSK WebSocket listener and the SPAKE2 responder.
final class LinuxHostd: @unchecked Sendable {
    let root: URL
    let port: Int
    let hostName: String
    let store: ControllerStore
    let core: HostServerCore
    private let window = PairingWindow()
    private let avahi = AvahiPublisher()

    private let lock = NSLock()
    private var peers: [ObjectIdentifier: NIOHostPeer] = [:]
    /// The slots present at the last store change, so a change can name the ones that left.
    private var knownSlots: Set<UUID>
    private var responder: Task<Void, Never>?

    /// Held across a successful pairing's consume-then-add, and by `status`. Without it a
    /// `pair` poll landing between the two sees the window closed and the count unchanged, and
    /// reports "expired" for a controller that has just paired.
    private let pairingLock = NSLock()

    init(root: URL, port: Int, hostName: String) {
        self.root = root
        self.port = port
        self.hostName = hostName
        store = ControllerStore(root: root)
        core = HostServerCore(hostName: { hostName },
                              probe: HostInfoProbe(stateRoot: root, hostdVersion: hostdVersion))
        knownSlots = Set(store.all().map(\.slot))
    }

    /// Binds everything, prints `listening on <port>` once the admin socket also answers (so a
    /// `pair` run straight after it cannot find hostd missing), and serves until killed.
    func run() async throws {
        store.onChange = { [weak self] in self?.storeChanged() }
        // A newly paired controller is stored as "controller"; its first hello names it.
        core.onControllerName = { [weak self] slot, name in self?.rename(slot: slot, to: name) }

        let server = PSKWebSocketServer(
            host: "0.0.0.0", port: port,
            keys: { [store] in
                // Read on every handshake, so a pairing works with no restart and a revoked
                // key is refused on the very next connection. Upper-cased because that is the
                // identity Darwin's `UUID.uuidString` sends, and identities compare as strings.
                Dictionary(store.all().map { ($0.slot.uuidString.uppercased(), [UInt8]($0.secret)) },
                           uniquingKeysWith: { first, _ in first })
            },
            onText: { [weak self] connection, text in self?.received(text, on: connection) },
            onClose: { [weak self] connection in self?.closed(connection) }
        )
        let channel = try server.start()
        let admin = try AdminSocketServer(path: root.appendingPathComponent("admin.sock").path) {
            [weak self] request in self?.handle(request) ?? .failed("hostd is shutting down")
        }
        let advert = avahi.publish(AvahiPublisher.serviceArguments(hostName: hostName, port: port))
        let signals = Self.onTermination { [avahi] in
            avahi.stop(advert)
            admin.stop()
            exit(0)
        }
        FileHandle.standardOutput.write(Data("listening on \(port)\n".utf8))
        try await channel.closeFuture.get()
        withExtendedLifetime(signals) {}
        avahi.stop(advert)
        admin.stop()
    }

    /// SIGTERM/SIGINT run `body` instead of killing the process outright, so the admin socket
    /// file is unlinked and the avahi children (which would otherwise outlive hostd and keep
    /// advertising a dead port) are stopped.
    private static func onTermination(_ body: @escaping @Sendable () -> Void) -> [DispatchSourceSignal] {
        [SIGTERM, SIGINT].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler(handler: body)
            source.resume()
            return source
        }
    }

    // MARK: - Transport

    private func received(_ text: String, on connection: PSKWebSocketServer.Connection) {
        guard let peer = peer(for: connection) else { return connection.close() }
        peer.queue.async { [core] in core.receive(text: text, from: peer) }
    }

    private func closed(_ connection: PSKWebSocketServer.Connection) {
        lock.lock()
        let peer = peers.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
        // Behind any receive still queued for it, which is what "serially per connection" means.
        guard let peer else { return }
        peer.queue.async { [core] in core.peerClosed(peer) }
    }

    /// nil only for an identity that is not a UUID, which the key closure cannot have accepted.
    private func peer(for connection: PSKWebSocketServer.Connection) -> NIOHostPeer? {
        lock.lock(); defer { lock.unlock() }
        if let peer = peers[ObjectIdentifier(connection)] { return peer }
        guard let slot = UUID(uuidString: connection.identity) else { return nil }
        let peer = NIOHostPeer(slot: slot, connection: connection)
        peers[ObjectIdentifier(connection)] = peer
        return peer
    }

    // MARK: - Store

    /// Every slot that left the store is cut off now, not at its next handshake. The core closes
    /// the peers that said hello; the transport's own list also catches a connection of that
    /// slot that has not spoken yet, which the core has never heard of.
    private func storeChanged() {
        lock.lock()
        // Read under this lock, so two changes racing cannot leave `knownSlots` naming a slot
        // that an older read still saw.
        let now = Set(store.all().map(\.slot))
        let gone = knownSlots.subtracting(now)
        knownSlots = now
        let silent = peers.values.filter { gone.contains($0.slot) }
        lock.unlock()
        for slot in gone { core.disconnect(slot: slot) }
        for peer in silent { peer.close() }
    }

    private func rename(slot: UUID, to name: String) {
        // Every hello carries the name, and an unchanged one is not worth a write of the
        // secrets file on each reconnect.
        guard !name.isEmpty, store.all().first(where: { $0.slot == slot })?.name != name else { return }
        do { _ = try store.rename(slot: slot, to: name) } catch {
            FileHandle.standardError.write(Data("could not rename \(slot): \(error)\n".utf8))
        }
    }

    // MARK: - Admin

    func handle(_ request: AdminRequest) -> AdminReply {
        switch request {
        case .status:
            pairingLock.lock(); defer { pairingLock.unlock() }
            return .status(paired: store.all().count, armedUntil: window.current?.expiresAt,
                           listeningPort: port, hostName: hostName)
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
            lock.lock(); responder?.cancel(); lock.unlock()
            return .ok
        case .arm:
            return arm()
        }
    }

    /// A fresh code replaces any armed one (PairingWindow's rule), and the old responder is
    /// cancelled and awaited before the new one binds, because both want the pairing port.
    private func arm() -> AdminReply {
        let code = PairingCode.mint()
        pairingLock.lock()
        let expiresAt = window.arm(codeText: code.formatted)
        pairingLock.unlock()
        lock.lock()
        let previous = responder
        previous?.cancel()
        responder = Task { [self] in
            _ = await previous?.value
            await openWindow(code: code, expiresAt: expiresAt)
        }
        lock.unlock()
        return .armed(code: code.formatted, expiresAt: expiresAt)
    }

    private func openWindow(code: PairingCode, expiresAt: Date) async {
        let key = FleetDeviceKey.mint()
        let advert = avahi.publish(AvahiPublisher.pairingArguments(hostName: hostName,
                                                                   port: HostdPorts.pairing))
        defer { avahi.stop(advert) }
        do {
            try await NIOPairingResponder.run(
                code: code, key: key, hostName: hostName, port: HostdPorts.pairing,
                deadline: max(0, expiresAt.timeIntervalSinceNow))
        } catch is CancellationError {
            return   // re-armed or cancelled: the window already belongs to someone else
        } catch {
            FileHandle.standardError.write(Data("pairing window ended: \(error)\n".utf8))
            closeWindow(code: code)
            return
        }
        storePaired(key, code: code)
    }

    /// A burned or unbindable window must stop advertising itself through `status`, or `pair`
    /// would keep showing a code that can no longer pair. Only if it is still this code's.
    private func closeWindow(code: PairingCode) {
        pairingLock.lock(); defer { pairingLock.unlock() }
        if window.current?.code == code.formatted { window.cancel() }
    }

    private func storePaired(_ key: FleetDeviceKey, code: PairingCode) {
        pairingLock.lock(); defer { pairingLock.unlock() }
        // The window's own check, so a code that was superseded while its exchange was in
        // flight cannot add a controller behind the fresh code's back.
        guard window.consume(codeText: code.formatted) else {
            FileHandle.standardError.write(Data("pairing finished after its code was replaced; not stored\n".utf8))
            return
        }
        do {
            try store.add(PairedController(slot: key.slot, name: "controller",
                                           secret: key.secret, pairedAt: Date()))
            FileHandle.standardError.write(Data("paired controller in slot \(key.slot)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("paired, but could not store the controller: \(error)\n".utf8))
        }
    }
}
