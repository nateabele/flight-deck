import Foundation

/// One connected controller, as the core sees it. The transport (socket, SSH, test fake)
/// implements this; the core never knows which.
public protocol HostPeer: AnyObject, Sendable {
    var slot: UUID { get }
    func send(text: String)
    /// One binary WebSocket message: a `ChannelFrame`. A protocol requirement, not just an
    /// extension method, so a conformer's real implementation is what a `HostPeer` call reaches.
    func send(binary: Data)
    func close()
}

extension HostPeer {
    /// Drops the data. Only so every conformer from before channels (1.0 transports, test
    /// fakes) still compiles; track C1 implements it for real in both hostds. Nothing sends a
    /// channel frame to a peer until a request has named a channel, so the drop is unreachable
    /// for a controller that checked the host's capabilities first.
    public func send(binary: Data) {}
}

/// Transport-agnostic protocol logic: the hello gate, request dispatch and error replies.
///
/// Threading contract: the transport must call `receive` and `peerClosed` serially per
/// connection, and off its event loop, because `host.info` is answered synchronously and
/// shells out (up to ~7s if docker wedges). Different connections may run concurrently.
/// `receive(binary:from:)` is the exception: the transport calls it straight from its delivery
/// thread, in arrival order, never through that serial queue (see there).
///
/// With a `delegation` router, nothing a request does holds the serial queue: delegation
/// requests are answered from tasks of their own, and `host.info` from a global queue. A
/// `sync.push` queued behind a 7 s `host.info` would otherwise leave its bundle's bytes piling
/// up in the mux, and the controller's writes stalled on credit, until the probe finished.
public final class HostServerCore: @unchecked Sendable {
    private let hostName: @Sendable () -> String
    private let probe: HostInfoProbe
    /// Serves every op but `host.info`. Nil (the 1.0 host, and tests of the core alone)
    /// answers them `not_implemented` and advertises only `host.info`.
    private let delegation: DelegationHost?
    /// This host's own `host:port` addresses for `helloAck`, asked on every hello: a host's
    /// addresses change under it (a laptop host joining the tailnet), and a list read once at
    /// launch would keep advertising the network it booted on.
    private let endpoints: @Sendable () -> [String]
    /// `host.info`'s `idleSince`. Nil (the macOS hostd, tests of the core alone) reports none.
    private let idle: IdleTracker?
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
                endpoints: @escaping @Sendable () -> [String] = { [] }, delegation: DelegationHost? = nil,
                idle: IdleTracker? = nil) {
        self.hostName = hostName
        self.probe = probe
        self.endpoints = endpoints
        self.delegation = delegation
        self.idle = idle
    }

    /// Replies are sent before this returns; see the type's threading contract.
    public func receive(text: String, from peer: HostPeer) {
        let key = ObjectIdentifier(peer)
        // Before decoding, and for every frame: a revoked controller that upgraded but stayed
        // silent was never in `peers`, so the revoke could not close it, and its next frame
        // would otherwise earn a `no_hello` or `malformed` reply — telling a revoked key that
        // it still reaches a live host. It gets a close and nothing else.
        if isRevoked(peer.slot) {
            forget(peer)
            peer.close()
            return
        }
        let frame: HostClientFrame
        do {
            frame = try HostWire.decode(HostClientFrame.self, from: text)
        } catch {
            replyToUndecodable(text, from: peer, key: key)
            return
        }
        switch frame {
        case .hello(let version, _, let name):
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
            // The mux exists before the ack leaves: a controller may open a channel the moment
            // it reads the ack, and a frame for a connection with no mux is dropped.
            delegation?.connected(peer)
            send(.helloAck(protocolVersion: .current, capabilities: [.hostInfo] + (delegation?.capabilities ?? []),
                           hostName: hostName(), endpoints: endpoints()), to: peer)
            notify?(peer.slot, name)
        case .request(let id, let req):
            guard isHelloed(key) else { return refuseNoHello(id: id, peer: peer) }
            switch req {
            case .hostInfo:
                guard delegation != nil else { return answerHostInfo(id, to: peer) }
                // Off the serial queue, for the type comment's reason.
                DispatchQueue.global(qos: .userInitiated).async { [self] in answerHostInfo(id, to: peer) }
            case .delegation(let request):
                guard let delegation else {
                    // A 1.0-style host. Answered by id rather than dropped, so a controller
                    // that sends one anyway fails at once instead of waiting out its request
                    // timeout; helloAck did not advertise it, so a correct controller never asks.
                    return send(.error(id: id, code: "not_implemented",
                                       message: "delegation is not implemented on this host yet"), to: peer)
                }
                delegation.handle(id: id, request, from: peer)
            }
        }
    }

    /// `slot` was revoked: its connections close, and the router stops its runs and services
    /// at once, connected or not. A revoked key's work must not run on for the orphan timeout.
    public func disconnect(slot: UUID) {
        lock.lock()
        revokedSlots.insert(slot)
        let doomed = peers.values.map(\.peer).filter { $0.slot == slot }
        for p in doomed { peers[ObjectIdentifier(p)] = nil }
        lock.unlock()
        for p in doomed {
            delegation?.disconnected(p)
            p.close()
        }
        delegation?.revoked(slot)
    }

    public func peerClosed(_ peer: HostPeer) { forget(peer) }

    /// One binary WebSocket message (a `ChannelMux` frame). Called by the transport straight
    /// from its delivery thread, in arrival order, and never through the per-connection serial
    /// queue: a request on that queue may be waiting for these very bytes. Dropped for a peer
    /// that has no mux (no hello yet, or already closed).
    public func receive(binary data: Data, from peer: HostPeer) {
        delegation?.receive(binary: data, from: peer)
    }

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

    private func isRevoked(_ slot: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return revokedSlots.contains(slot)
    }

    private func isHelloed(_ key: ObjectIdentifier) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return peers[key]?.helloed ?? false
    }

    /// Also ends the peer's delegation state (its mux and event subscriptions), on every
    /// path that drops it: closed, refused, revoked.
    private func forget(_ peer: HostPeer) {
        lock.lock(); peers[ObjectIdentifier(peer)] = nil; lock.unlock()
        delegation?.disconnected(peer)
    }

    /// The core's name wins over the probe's: the controller must see the same name in
    /// helloAck and host.info, or one host shows up under two names.
    ///
    /// `host.info` itself never touches the idle tracker: the controller's reaper polls it, and
    /// a poll that counted as use would keep every box it watches from ever going idle.
    private func answerHostInfo(_ id: Int, to peer: HostPeer) {
        var info = probe.gather()
        info.hostName = hostName()
        info.idleSince = idle?.idleSince
        send(.reply(id: id, .hostInfo(info)), to: peer)
    }

    private func send(_ frame: HostServerFrame, to peer: HostPeer) {
        guard let text = try? HostWire.encode(frame) else { return }
        peer.send(text: text)
    }
}
