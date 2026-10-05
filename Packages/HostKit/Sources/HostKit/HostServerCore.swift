import Foundation

/// One connected controller, as the core sees it. The transport (socket, SSH, test fake)
/// implements this; the core never knows which.
public protocol HostPeer: AnyObject, Sendable {
    var slot: UUID { get }
    func send(text: String)
    func close()
}

/// Transport-agnostic protocol logic: the hello gate, request dispatch and error replies.
///
/// Threading contract: the transport must call `receive` and `peerClosed` serially per
/// connection, and off its event loop, because `host.info` is answered synchronously and
/// shells out (up to ~7s if docker wedges). Different connections may run concurrently.
public final class HostServerCore: @unchecked Sendable {
    private let hostName: @Sendable () -> String
    private let probe: HostInfoProbe
    /// This host's own `host:port` addresses for `helloAck`, asked on every hello: a host's
    /// addresses change under it (a laptop host joining the tailnet), and a list read once at
    /// launch would keep advertising the network it booted on.
    private let endpoints: @Sendable () -> [String]
    private let lock = NSLock()
    private var peers: [ObjectIdentifier: (peer: HostPeer, helloed: Bool)] = [:]
    /// Slots revoked via `disconnect`. `peers` only knows peers that have said hello, so
    /// without this a revoked controller that was silent (or mid-hello) could hello afterwards.
    /// Re-pairing mints a new slot UUID, so a revoked slot never needs to come back.
    private var revokedSlots: Set<UUID> = []
    private var _onControllerName: (@Sendable (UUID, String) -> Void)?

    /// Fired on each accepted hello so the host can refresh a stored controller's display name.
    public var onControllerName: (@Sendable (UUID, String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onControllerName }
        set { lock.lock(); defer { lock.unlock() }; _onControllerName = newValue }
    }

    /// `endpoints` defaults to none, which a controller reads as "nothing to learn"; both
    /// hostds pass their real interface list.
    public init(hostName: @escaping @Sendable () -> String, probe: HostInfoProbe,
                endpoints: @escaping @Sendable () -> [String] = { [] }) {
        self.hostName = hostName
        self.probe = probe
        self.endpoints = endpoints
    }

    /// Replies are sent before this returns; see the type's threading contract.
    public func receive(text: String, from peer: HostPeer) {
        let key = ObjectIdentifier(peer)
        let frame: HostClientFrame
        do {
            frame = try HostWire.decode(HostClientFrame.self, from: text)
        } catch {
            replyToUndecodable(text, from: peer, key: key)
            return
        }
        switch frame {
        case .hello(let version, _, let name):
            lock.lock()
            let revoked = revokedSlots.contains(peer.slot)
            lock.unlock()
            if revoked {
                forget(peer)
                peer.close()
                return
            }
            guard version.major == ProtocolVersion.current.major else {
                send(.refused(reason: .majorVersionMismatch(host: .current)), to: peer)
                forget(peer)
                peer.close()
                return
            }
            // Re-checked under the same lock that registers the peer, so a disconnect racing
            // this hello either lands first (we refuse) or after (it finds the peer).
            lock.lock()
            if revokedSlots.contains(peer.slot) {
                lock.unlock()
                peer.close()
                return
            }
            peers[key] = (peer, true)
            let notify = _onControllerName
            lock.unlock()
            send(.helloAck(protocolVersion: .current, capabilities: [.hostInfo], hostName: hostName(),
                           endpoints: endpoints()), to: peer)
            notify?(peer.slot, name)
        case .request(let id, let req):
            guard isHelloed(key) else { return refuseNoHello(id: id, peer: peer) }
            switch req {
            case .hostInfo:
                // The core's name wins over the probe's: the controller must see the same
                // name in helloAck and host.info, or one host shows up under two names.
                var info = probe.gather()
                info.hostName = hostName()
                send(.reply(id: id, .hostInfo(info)), to: peer)
            }
        }
    }

    public func disconnect(slot: UUID) {
        lock.lock()
        revokedSlots.insert(slot)
        let doomed = peers.values.map(\.peer).filter { $0.slot == slot }
        for p in doomed { peers[ObjectIdentifier(p)] = nil }
        lock.unlock()
        for p in doomed { p.close() }
    }

    public func peerClosed(_ peer: HostPeer) { forget(peer) }

    // MARK: - Private

    /// A frame that will not decode as a whole may still be a well-formed request from a newer
    /// controller whose `op` this build lacks. Salvage its `id` so the controller gets an
    /// answer instead of waiting forever; the connection stays open for its other requests.
    private func replyToUndecodable(_ text: String, from peer: HostPeer, key: ObjectIdentifier) {
        let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        if let obj, obj["t"] as? String == "req", let id = obj["id"] as? Int {
            guard isHelloed(key) else { return refuseNoHello(id: id, peer: peer) }
            send(.error(id: id, code: "unsupported", message: "unknown request"), to: peer)
        } else {
            send(.error(id: 0, code: "malformed", message: "unreadable frame"), to: peer)
        }
    }

    private func refuseNoHello(id: Int, peer: HostPeer) {
        send(.error(id: id, code: "no_hello", message: "send hello first"), to: peer)
        forget(peer)
        peer.close()
    }

    private func isHelloed(_ key: ObjectIdentifier) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return peers[key]?.helloed ?? false
    }

    private func forget(_ peer: HostPeer) {
        lock.lock(); peers[ObjectIdentifier(peer)] = nil; lock.unlock()
    }

    private func send(_ frame: HostServerFrame, to peer: HostPeer) {
        guard let text = try? HostWire.encode(frame) else { return }
        peer.send(text: text)
    }
}
