import Foundation
#if canImport(Glibc)
import Glibc
#endif

// The host's services half of the delegation router (spec §6.2, §6.3, §7): `service.down`,
// `service.sync`, `port.check`, `port.open` and `screen.status`, plus the orphan timeout that
// downs a service whose controller has been gone too long. The run path (`sync.*`, `run.*`,
// `workspace.*`) is `DelegationHost`'s; `handle` answers nil for those so the router can tell
// "not mine" from "done".
//
// One `DelegationHostServices` per hostd process, shared by every connection: a service
// outlives the connection that started it, and its orphan clock is per controller, not per
// connection. The channel acceptor is the one thing that is per connection, so it comes in
// with each request (`handle(_:controller:accept:)`) rather than living in the context.

/// What the services need from the host. Built once by the hostd beside the router.
public struct DelegationHostContext: Sendable {
    public let runner: any RunControlling
    public let workspace: any WorkspaceStore
    public let portCheck: any PortChecking
    public let screen: ScreenLease
    /// True while controller `slot` has at least one live connection.
    public let isConnected: @Sendable (UUID) -> Bool

    public init(runner: any RunControlling, workspace: any WorkspaceStore, portCheck: any PortChecking,
                screen: ScreenLease, isConnected: @escaping @Sendable (UUID) -> Bool) {
        self.runner = runner
        self.workspace = workspace
        self.portCheck = portCheck
        self.screen = screen
        self.isConnected = isConnected
    }
}

/// A runner that can answer `screen.status` from its own console probe. `Runner` is one; the
/// fallback for any other runner reports the lease with an unsupported console, because
/// HostKit alone cannot see a Mac's console (that probe is HostKitDarwin's).
protocol ScreenStatusReporting {
    func screenStatus() -> ScreenStatus
}

extension Runner: ScreenStatusReporting {}

public final class DelegationHostServices: @unchecked Sendable {
    /// §6.2's default: half an hour with no controller connected before a service is downed.
    public static let defaultOrphanTimeout: TimeInterval = 1800

    /// One service this host started, and what `service.sync` and the orphan clock need of it.
    private final class Service: @unchecked Sendable {
        let controller: UUID
        let orphanTimeout: TimeInterval
        /// The pinned slot the service runs in, once `acquire` has handed it over. Guarded by
        /// the services lock. Kept here because the runner holds it privately, and the
        /// worktree's "most recent checkout" is not necessarily this slot (a later `run` of the
        /// same worktree applies into another one).
        var lease: CheckoutLease?

        init(controller: UUID, orphanTimeout: TimeInterval) {
            self.controller = controller
            self.orphanTimeout = orphanTimeout
        }
    }

    private let context: DelegationHostContext
    private let clock: any RunClock
    private let orphanTimeout: TimeInterval

    private let lock = NSLock()
    private var services: [String: Service] = [:]
    /// Bumped on every connect and disconnect of a controller. A timer fires only if the
    /// generation it was started under is still current, so a drop, reconnect and second drop
    /// can never let the first drop's timer down services early.
    private var generations: [UUID: Int] = [:]
    private var orphanTimers: [UUID: [Task<Void, Never>]] = [:]
    private var forwards = 0

    public init(context: DelegationHostContext, clock: any RunClock = SystemRunClock(),
                orphanTimeout: TimeInterval = DelegationHostServices.defaultOrphanTimeout) {
        self.context = context
        self.clock = clock
        self.orphanTimeout = orphanTimeout
    }

    /// `port.open` connections currently being piped; both directions ended means zero.
    var liveForwards: Int { lock.withLock { forwards } }

    /// The lease `runID`'s service currently runs in, if it has one yet.
    func serviceLease(_ runID: String) -> CheckoutLease? {
        lock.withLock { services[runID]?.lease }
    }

    // MARK: - Starting a service

    /// Starts a service run (`spec.service`) through the runner, and remembers it: the router
    /// calls this for a service's `run.start` instead of `runner.start`. Without it the host
    /// cannot find the service's pinned slot for `service.sync`, nor the services a
    /// controller left behind when its orphan timeout runs out.
    public func startService(_ spec: RunSpec, owner: LeaseHolderOwner,
                             acquire: @escaping @Sendable () async throws -> CheckoutLease) -> String {
        let service = Service(controller: owner.controller,
                              orphanTimeout: spec.orphanTimeout.map(TimeInterval.init) ?? orphanTimeout)
        // The lease is recorded on the object, not under the run id: the runner may call
        // `acquire` before `start` has even returned the id.
        let id = context.runner.start(spec, owner: owner) { [weak self] in
            let lease = try await acquire()
            self?.lock.withLock { service.lease = lease }
            return lease
        }
        let runner = context.runner
        lock.withLock {
            // Forget services the runner has already retired, so the table stays bounded by
            // what the runner itself remembers.
            services = services.filter { runner.owner(runID: $0.key) != nil }
            services[id] = service
        }
        return id
    }

    // MARK: - Requests

    /// Answers `service.*`, `port.*` and `screen.status`; nil for every other op, which is the
    /// router's. `controller` is the paired slot of the connection the request came in on,
    /// never a field of the request. `accept` claims a channel on that same connection.
    public func handle(_ request: DelegationRequest, controller: UUID,
                       accept: @escaping @Sendable (ChannelID) async throws -> any ByteChannel) async throws -> DelegationReply? {
        switch request {
        case .portCheck(let ports):
            return .portCheck(await check(ports))
        case .portOpen(let service, let remote, let channel):
            try await open(service, remote: remote, channel: channel, controller: controller, accept: accept)
            return .portOpen
        case .serviceDown(let service):
            try requireOwned(service, by: controller)
            try await context.runner.down(runID: service)
            _ = lock.withLock { services.removeValue(forKey: service) }
            return .serviceDown
        case .serviceSync(let service, let ref):
            try await sync(service, to: ref, controller: controller)
            return .serviceSync
        case .screenStatus:
            return .screenStatus(screenStatus())
        // Listed rather than `default`, so a new op has to be placed on one side or the other.
        case .syncTips, .syncPush, .runStart, .runAttach, .runSignal, .runCancel, .runResult, .runArtifacts, .runAck,
             .workspaceUsage, .workspacePrune:
            return nil
        }
    }

    /// `unknown_run` for a run that does not exist and for another controller's alike: the
    /// host never confirms that someone else's service exists (A2).
    private func requireOwned(_ runID: String, by controller: UUID) throws {
        guard context.runner.owner(runID: runID)?.controller == controller else {
            throw DelegationError(code: "unknown_run", message: "no service \(runID) on this host")
        }
    }

    private func check(_ ports: [UInt16]) async -> [PortStatus] {
        // `PortCheck` names holders in one batch, so a five-port recipe pays for `docker ps`
        // once rather than five times.
        if let batch = context.portCheck as? PortCheck { return await batch.check(ports) }
        var out: [PortStatus] = []
        for port in ports { out.append(PortStatus(port: port, holder: await context.portCheck.holder(of: port))) }
        return out
    }

    private func screenStatus() -> ScreenStatus {
        if let reporting = context.runner as? any ScreenStatusReporting { return reporting.screenStatus() }
        return ScreenStatus(supported: false, consoleUser: false, locked: false,
                            holder: context.screen.holder, queued: context.screen.queued)
    }

    /// `flightdeck sync <service>`: re-applies `ref` in place to the service's own pinned
    /// slot (§6.2). A recipe with `restart_on_sync` never reaches here: the controller downs
    /// and restarts the service itself, because only it knows the recipe.
    private func sync(_ runID: String, to ref: SnapshotRef, controller: UUID) async throws {
        try requireOwned(runID, by: controller)
        guard let lease = lock.withLock({ services[runID]?.lease }) else {
            throw DelegationError(code: "no_checkout", message: "service \(runID) has no checkout yet; it is still queued")
        }
        // A ref from another worktree would apply that worktree's tree into this service's
        // slot; the store only checks the commit exists in the repo's object store.
        guard ref.repoRoot == lease.ref.repoRoot, ref.wtKey == lease.ref.wtKey else {
            throw DelegationError(code: "no_checkout", message: "service \(runID) runs from a different worktree")
        }
        let updated = try await context.workspace.reapply(lease, ref: ref)
        lock.withLock { services[runID]?.lease = updated }
    }

    /// The services `controller` started that the host still tracks.
    func serviceIDs(controller: UUID) -> Set<String> {
        lock.withLock { Set(services.filter { $0.value.controller == controller }.keys) }
    }

    /// `slot`'s pairing was revoked: downs each of its services now, `down` command and all,
    /// rather than after the orphan timeout, and returns their ids once they are down. The
    /// generation bump makes the timer its disconnect started a no-op, so nothing is downed
    /// twice.
    @discardableResult
    public func revoked(_ slot: UUID) async -> [String] {
        let (mine, timers): ([String], [Task<Void, Never>]) = lock.withLock {
            _ = bump(slot)
            let mine = services.filter { $0.value.controller == slot }.map(\.key).sorted()
            for id in mine { services[id] = nil }
            return (mine, orphanTimers.removeValue(forKey: slot) ?? [])
        }
        timers.forEach { $0.cancel() }
        let runner = context.runner
        await withTaskGroup(of: Void.self) { group in
            for id in mine { group.addTask { try? await runner.down(runID: id) } }
        }
        return mine
    }

    // MARK: - Orphan timeout

    /// The router calls this when `slot`'s last connection drops. Each of its services gets
    /// its own timer (its `orphanTimeout`, else the host default); one that runs out with the
    /// controller still away downs that service, `down` command and all.
    public func controllerDisconnected(_ slot: UUID) {
        let stale: [Task<Void, Never>] = lock.withLock {
            let generation = bump(slot)
            let mine = services.filter { $0.value.controller == slot }
            defer {
                orphanTimers[slot] = mine.map { id, service in
                    Task { [weak self, clock] in
                        await clock.sleep(seconds: service.orphanTimeout)
                        await self?.orphanTimeoutExpired(id, slot: slot, generation: generation)
                    }
                }
            }
            return orphanTimers[slot] ?? []
        }
        stale.forEach { $0.cancel() }
    }

    /// The router calls this when `slot` connects. Cancels its pending orphan timers.
    public func controllerConnected(_ slot: UUID) {
        let timers: [Task<Void, Never>] = lock.withLock {
            _ = bump(slot)
            return orphanTimers.removeValue(forKey: slot) ?? []
        }
        timers.forEach { $0.cancel() }
    }

    /// Under `lock`. Cancelling a timer only ends its sleep early (`SystemRunClock` swallows
    /// the cancellation and returns), so the generation check, not cancellation, is what keeps
    /// a stale timer from acting.
    private func bump(_ slot: UUID) -> Int {
        generations[slot, default: 0] += 1
        return generations[slot]!
    }

    private func orphanTimeoutExpired(_ runID: String, slot: UUID, generation: Int) async {
        guard lock.withLock({ generations[slot] == generation }), !context.isConnected(slot) else { return }
        try? await context.runner.down(runID: runID)
        _ = lock.withLock { services.removeValue(forKey: runID) }
    }

    // MARK: - port.open

    /// Claims the channel, dials `127.0.0.1:remote`, and pipes the two in the background. The
    /// reply goes out once the dial has succeeded, so a dead service is the controller's
    /// `dial_failed`, not a connection that opens and closes at once. Any failure cancels the
    /// channel (A6): the controller would otherwise keep a forward half-open.
    private func open(_ runID: String, remote: UInt16, channel id: ChannelID, controller: UUID,
                      accept: @Sendable (ChannelID) async throws -> any ByteChannel) async throws {
        let channel = try await accept(id)
        let socket: LoopbackSocket
        do {
            try requireOwned(runID, by: controller)
            socket = try await LoopbackSocket.dial(remote)
        } catch {
            channel.cancel()
            if let refused = error as? LoopbackSocket.DialError {
                throw DelegationError(code: "dial_failed",
                                      message: "nothing accepts connections on the host's port \(remote) (\(refused)) — is service \(runID) listening on 127.0.0.1:\(remote)?")
            }
            throw error
        }
        lock.withLock { forwards += 1 }
        Task { [weak self] in
            await Self.pipe(socket, channel)
            self?.lock.withLock { self?.forwards -= 1 }
        }
    }

    /// Pipes until both directions have ended, with backpressure both ways: the next read on
    /// either side waits until the last chunk has been written to the other.
    ///
    /// The half-close rules (the controller's port forwarder's, applied host side):
    ///   - EOF in one direction half-closes the other side (`finish`, `shutdown(SHUT_WR)`) and
    ///     leaves the other direction running, so a client that half-closes after its request
    ///     still reads the reply.
    ///   - The service's last bytes and its close are one result. Once they have all been
    ///     written to the channel and finished, a failed write *toward* the service (it closed
    ///     its whole socket; the controller was still sending) does not cancel the channel:
    ///     a close frame behind the data makes the controller's mux drop whatever it has not
    ///     read yet. The rest of the controller's bytes are read and discarded until its EOF,
    ///     as the service's kernel would have discarded them.
    ///   - Any other error tears down both sides.
    static func pipe(_ socket: LoopbackSocket, _ channel: any ByteChannel) async {
        let replied = Latch()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    while let chunk = try await socket.receive() { try await channel.write(chunk) }
                    await channel.finish()
                    replied.set()
                } catch {
                    channel.cancel()
                    socket.abort()
                }
            }
            group.addTask {
                do {
                    while let chunk = try await channel.read() {
                        do {
                            try await socket.send(chunk)
                        } catch where replied.isSet {
                            while try await channel.read() != nil {}
                            return
                        }
                    }
                    socket.finishWriting()
                } catch {
                    channel.cancel()
                    socket.abort()
                }
            }
        }
        socket.closeWhenIdle()
    }
}

private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func set() { lock.withLock { raised = true } }
    var isSet: Bool { lock.withLock { raised } }
}

/// A non-blocking loopback TCP connection with async reads and writes. POSIX rather than
/// Network framework, because HostKit builds for the Linux hostd too. Waits for readiness on a
/// one-shot dispatch source instead of blocking a thread: a browser keeps half a dozen idle
/// keep-alive connections per forward, and a blocked thread each would exhaust the pool.
final class LoopbackSocket: @unchecked Sendable {
    struct DialError: Error, CustomStringConvertible {
        let errno: Int32
        var description: String { String(cString: strerror(errno)) }
    }

    struct IOError: Error {
        let errno: Int32
    }

    private let fd: Int32
    private let queue = DispatchQueue(label: "dev.flightdeck.hostd.port-forward")
    /// Entered per readiness source, left in its cancel handler. The fd is closed only once
    /// this drains: dispatch forbids closing a descriptor a live source still watches.
    private let sources = DispatchGroup()

    private init(fd: Int32) {
        self.fd = fd
    }

    /// Connects to `127.0.0.1:port`, then `[::1]:port`: a dev server that binds "localhost"
    /// often lands on the IPv6 loopback alone, and the forward should reach it either way.
    /// Off the cooperative pool, since `connect` blocks (briefly, on loopback).
    static func dial(_ port: UInt16) async throws -> LoopbackSocket {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                var lastError = ECONNREFUSED
                for v6 in [false, true] {
                    switch connect(port, v6: v6) {
                    case .success(let fd): return cont.resume(returning: LoopbackSocket(fd: fd))
                    case .failure(let e): lastError = e.errno
                    }
                }
                cont.resume(throwing: DialError(errno: lastError))
            }
        }
    }

    private static func connect(_ port: UInt16, v6: Bool) -> Result<Int32, DialError> {
        // CLOEXEC: the runner spawns commands from this process, and a forward's socket leaking
        // into one would hold the service's connection open after we closed it.
        #if os(Linux)
        let fd = socket(v6 ? AF_INET6 : AF_INET, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        #else
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { return .failure(DialError(errno: errno)) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        #if !os(Linux)
        // A write to a socket the service has closed must fail with EPIPE, not kill hostd.
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        let result: Int32
        if v6 {
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            addr.sin6_addr = in6addr_loopback
            result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { libcConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { libcConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        guard result == 0 else {
            let e = errno
            close(fd)
            return .failure(DialError(errno: e))
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return .success(fd)
    }

    /// The next bytes, at most one channel frame's worth; nil at EOF.
    func receive() async throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: ChannelFrame.maxPayload)
        while true {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n > 0 { return Data(buffer[0..<n]) }
            if n == 0 { return nil }
            let e = errno
            if e == EINTR { continue }
            guard e == EAGAIN || e == EWOULDBLOCK else { throw IOError(errno: e) }
            await ready(write: false)
        }
    }

    /// Writes all of `data`, waiting for buffer space as needed.
    func send(_ data: Data) async throws {
        #if os(Linux)
        let flags = Int32(MSG_NOSIGNAL)
        #else
        let flags: Int32 = 0
        #endif
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { libcSend(fd, $0.baseAddress! + offset, data.count - offset, flags) }
            if n > 0 { offset += n; continue }
            let e = errno
            if n < 0, e == EINTR { continue }
            guard n < 0, e == EAGAIN || e == EWOULDBLOCK else { throw IOError(errno: n == 0 ? EPIPE : e) }
            await ready(write: true)
        }
    }

    /// Half-close: the service reads EOF and may still reply.
    func finishWriting() {
        _ = shutdown(fd, Int32(SHUT_WR))
    }

    /// Ends both directions now. Wakes a read or write waiting for readiness: a shut-down
    /// socket is readable (EOF) and writable (EPIPE).
    func abort() {
        _ = shutdown(fd, Int32(SHUT_RDWR))
    }

    /// Closes the descriptor once no readiness source watches it any more. Call once, after
    /// both directions are done.
    func closeWhenIdle() {
        let fd = fd
        sources.notify(queue: queue) { close(fd) }
    }

    /// Suspends until the socket is readable (or writable), on a one-shot source.
    private func ready(write: Bool) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let source: any DispatchSourceProtocol
            if write {
                source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            } else {
                source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            }
            sources.enter()
            source.setEventHandler { source.cancel() }
            source.setCancelHandler { [sources] in
                sources.leave()
                cont.resume()
            }
            source.resume()
        }
    }
}

// The libc calls, reachable from inside `LoopbackSocket`, whose own `connect` and `send`
// shadow them.
private func libcConnect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
    connect(fd, addr, len)
}

private func libcSend(_ fd: Int32, _ buf: UnsafeRawPointer, _ len: Int, _ flags: Int32) -> Int {
    send(fd, buf, len, flags)
}
