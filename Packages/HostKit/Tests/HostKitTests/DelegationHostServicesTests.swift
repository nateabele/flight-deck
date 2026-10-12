import Foundation
import XCTest
@testable import HostKit
#if canImport(Glibc)
import Glibc
#endif

/// The host's services half of the delegation router (C8 W2): `service.*`, `port.*`,
/// `screen.status`, and the orphan timeout. Ports run against real loopback sockets and the
/// channel against a real in-memory mux pair, because the bugs worth catching here (a reply
/// cut by a close frame, a half-close that tears down the other direction) live in exactly
/// the seam a fake would paper over.
final class DelegationHostServicesTests: XCTestCase {
    private let controller = UUID()
    private let stranger = UUID()

    // MARK: - Routing

    /// W1 routes everything else; a services object that answered one of W1's ops would
    /// shadow the real handler.
    func testOpsOutsideServicesAreLeftForTheRouter() async throws {
        let services = makeServices(runner: FakeRunner())
        let ref = SnapshotRef(repoRoot: "r", wtKey: "w", worktreeName: "n", commit: "c", tree: "t")
        let others: [DelegationRequest] = [
            .syncTips(repoRoot: "r", wtKey: "w"), .syncPush(ref: ref, channel: 1),
            .runAttach(runID: "r1", offset: 0), .runSignal(runID: "r1", signal: 2), .runCancel(runID: "r1"),
            .runResult(runID: "r1", channel: 1), .runArtifacts(runID: "r1", globs: [], channel: 1),
            .workspaceUsage, .workspacePrune(repoRoot: nil),
        ]
        for request in others {
            let reply = try await services.handle(request, controller: controller, accept: { _ in throw CancellationError() })
            XCTAssertNil(reply, "\(request)")
        }
    }

    func testPortCheckNamesEachPortsHolder() async throws {
        let ports = FakePorts(held: [5432: .process(name: "postgres", pid: 812)])
        let services = makeServices(runner: FakeRunner(), ports: ports)
        let reply = try await services.handle(.portCheck(ports: [5432, 6379]), controller: controller, accept: noChannel)
        XCTAssertEqual(reply, .portCheck([PortStatus(port: 5432, holder: .process(name: "postgres", pid: 812)),
                                          PortStatus(port: 6379, holder: .free)]))
    }

    /// The real runner's console probe, not a guess: the controller refuses a screen run
    /// from this answer (§7 step 6), and HostKit's own default probe says "unsupported".
    func testScreenStatusReportsTheConsoleAndTheLease() async throws {
        let screen = ScreenLease()
        let runner = Runner(runsRoot: try tempDir("runs"), shell: "/bin/sh", hostEnvironment: hostEnv,
                            console: FixedConsole(state: ConsoleSession(supported: true, consoleUser: true, locked: false)),
                            screen: screen)
        _ = screen.request("r9", holder: LeaseHolder(runID: "r9", session: "UI tests")) {}
        _ = screen.request("r10", holder: LeaseHolder(runID: "r10", session: "Other")) {}
        let services = makeServices(runner: runner, screen: screen)

        let reply = try await services.handle(.screenStatus, controller: controller, accept: noChannel)

        XCTAssertEqual(reply, .screenStatus(ScreenStatus(supported: true, consoleUser: true, locked: false,
                                                         holder: LeaseHolder(runID: "r9", session: "UI tests"), queued: 1)))
    }

    // MARK: - Scoping

    /// Another controller's service is answered exactly as a run that does not exist, and the
    /// channel its request named is cancelled rather than left buffering (A6).
    func testAnotherControllersServiceIsUnknown() async throws {
        let runner = FakeRunner()
        runner.owners["r1"] = LeaseHolderOwner(controller: controller, session: "A")
        let services = makeServices(runner: runner)
        let pair = MuxPair()
        let channel = try await pair.controller.open()
        let ref = SnapshotRef(repoRoot: "r", wtKey: "w", worktreeName: "n", commit: "c", tree: "t")

        for request: DelegationRequest in [.serviceDown(service: "r1"), .serviceSync(service: "r1", ref: ref),
                                           .portOpen(service: "r1", remote: 1, channel: channel.id)] {
            do {
                _ = try await services.handle(request, controller: stranger, accept: { try await pair.host.accept($0) })
                XCTFail("\(request) answered another controller")
            } catch let error as DelegationError {
                XCTAssertEqual(error.code, "unknown_run", "\(request)")
            }
        }
        XCTAssertEqual(runner.downs, [])
        do { _ = try await channel.read(); XCTFail("the named channel stayed open") } catch {}
    }

    // MARK: - service.down / service.sync

    /// `down` stops the service and only then runs the recipe's `down` command, in the same
    /// checkout, before the request is answered: the CLI's "down" means "the containers are
    /// gone", not "we asked".
    func testDownRunsTheDownCommandBeforeAnswering() async throws {
        let checkout = try tempDir("checkout")
        let runner = Runner(runsRoot: try tempDir("runs"), shell: "/bin/sh", hostEnvironment: hostEnv)
        let services = makeServices(runner: runner)
        let lease = CheckoutLease(id: UUID(), path: checkout, slot: 0,
                                  ref: SnapshotRef(repoRoot: "r", wtKey: "w", worktreeName: "n", commit: "c", tree: "t"))
        let spec = RunSpec(command: "exec sleep 30", subdir: "", env: [:], pty: false, screen: false, service: true,
                           downCommand: "echo stopped > down.txt", ports: [])
        let id = services.startService(spec, owner: LeaseHolderOwner(controller: controller, session: "A"),
                                       acquire: { lease })
        try await waitUntilStarted(runner, id)

        let reply = try await services.handle(.serviceDown(service: id), controller: controller, accept: noChannel)

        XCTAssertEqual(reply, .serviceDown)
        XCTAssertEqual(try String(contentsOf: checkout.appendingPathComponent("down.txt"), encoding: .utf8), "stopped\n")
        XCTAssertEqual(runner.phase(runID: id), .exited(.signal(SIGTERM)))
    }

    /// `flightdeck sync` re-applies into the service's own pinned slot. A plain `run` of a
    /// newer snapshot sits in another slot of the same worktree, applied more recently; the
    /// "most recent checkout" (`existingCheckout`) would be that one, and the service would
    /// keep serving stale code while the run's tree changed under it.
    func testSyncReappliesIntoTheServicesOwnSlot() async throws {
        let repo = try TempRepo()
        repo.write("a.txt", "v1\n")
        try repo.commitAll()
        let store = Workspace(root: TempRepo.scratch())
        let runner = Runner(runsRoot: try tempDir("runs"), shell: "/bin/sh", hostEnvironment: hostEnv,
                            lifecycle: .workspace(store))
        let services = makeServices(runner: runner, workspace: store)

        let s1 = try await push(repo, to: store)
        let spec = RunSpec(command: "exec sleep 30", subdir: "", env: [:], pty: false, screen: false, service: true,
                           downCommand: nil, ports: [])
        let controller = controller
        let id = services.startService(spec, owner: LeaseHolderOwner(controller: controller, session: "A"),
                                       acquire: { try await store.checkout(controller: controller, ref: s1, pin: true) })
        try await waitUntilStarted(runner, id)

        repo.write("a.txt", "v2\n")
        let s2 = try await push(repo, to: store)
        let otherRun = try await store.checkout(controller: controller, ref: s2, pin: false)
        repo.write("a.txt", "v3\n")
        let s3 = try await push(repo, to: store)

        let reply = try await services.handle(.serviceSync(service: id, ref: s3), controller: controller, accept: noChannel)

        XCTAssertEqual(reply, .serviceSync)
        let serviceSlot = try XCTUnwrap(services.serviceLease(id))
        XCTAssertNotEqual(serviceSlot.slot, otherRun.slot)
        XCTAssertEqual(serviceSlot.ref, s3)
        XCTAssertEqual(try String(contentsOf: serviceSlot.path.appendingPathComponent("a.txt"), encoding: .utf8), "v3\n")
        XCTAssertEqual(try String(contentsOf: otherRun.path.appendingPathComponent("a.txt"), encoding: .utf8), "v2\n")
        try await runner.down(runID: id)
        await store.release(otherRun)
    }

    // MARK: - Orphan timeout

    /// A controller gone for the whole timeout has its services downed; each service's own
    /// `orphanTimeout` beats the host default.
    func testOrphanedServicesAreDownedAfterTheTimeout() async throws {
        let runner = FakeRunner()
        let clock = ManualClock()
        let connected = Connected()
        let services = makeServices(runner: runner, clock: clock, isConnected: connected.check, orphanTimeout: 1800)
        let a = services.startService(serviceSpec(), owner: LeaseHolderOwner(controller: controller, session: "A"),
                                      acquire: { throw CancellationError() })
        var short = serviceSpec()
        short.orphanTimeout = 60
        let b = services.startService(short, owner: LeaseHolderOwner(controller: controller, session: "A"),
                                      acquire: { throw CancellationError() })
        let theirs = services.startService(serviceSpec(), owner: LeaseHolderOwner(controller: stranger, session: "B"),
                                           acquire: { throw CancellationError() })

        services.controllerDisconnected(controller)
        try await clock.advance()
        try await clock.advance()
        try await waitFor { runner.downs.count == 2 }

        XCTAssertEqual(Set(runner.downs), [a, b])
        XCTAssertFalse(runner.downs.contains(theirs))
        XCTAssertEqual(Set(clock.requested), [1800, 60])
    }

    /// Reconnecting inside the timeout cancels it: a laptop that slept through lunch must find
    /// its database still up.
    func testReconnectCancelsTheOrphanTimeout() async throws {
        let runner = FakeRunner()
        let clock = ManualClock()
        let connected = Connected()
        let services = makeServices(runner: runner, clock: clock, isConnected: connected.check)
        _ = services.startService(serviceSpec(), owner: LeaseHolderOwner(controller: controller, session: "A"),
                                  acquire: { throw CancellationError() })

        services.controllerDisconnected(controller)
        connected.set(controller, true)
        services.controllerConnected(controller)
        try await clock.advance()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(runner.downs, [])
    }

    /// A drop and a reconnect and a second drop: the first drop's timer must not fire on the
    /// second drop's account, or a flapping link would down services early.
    func testAStaleTimerDoesNotFireAfterASecondDrop() async throws {
        let runner = FakeRunner()
        let clock = ManualClock()
        let connected = Connected()
        let services = makeServices(runner: runner, clock: clock, isConnected: connected.check)
        let id = services.startService(serviceSpec(), owner: LeaseHolderOwner(controller: controller, session: "A"),
                                       acquire: { throw CancellationError() })

        services.controllerDisconnected(controller)
        // The first drop's timer must be the clock's first sleeper, or `advance` below could
        // wake the second's: the two timer tasks otherwise start in either order (seen once in
        // a loaded Linux run).
        try await waitFor { clock.requested.count == 1 }
        services.controllerConnected(controller)
        services.controllerDisconnected(controller)
        try await clock.advance()   // the first drop's sleeper
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(runner.downs, [])

        try await clock.advance()   // the second's
        try await waitFor { runner.downs == [id] }
    }

    /// A revoked controller's services go down now, `down` command and all, not after the
    /// orphan timeout: the key is no longer trusted, so nothing it started keeps a port. The
    /// timer its disconnect started must not down them a second time.
    func testRevokedDownsTheSlotsServicesAtOnce() async throws {
        let runner = FakeRunner()
        let clock = ManualClock()
        let services = makeServices(runner: runner, clock: clock)
        let mine = services.startService(serviceSpec(), owner: LeaseHolderOwner(controller: controller, session: "A"),
                                         acquire: { throw CancellationError() })
        let theirs = services.startService(serviceSpec(), owner: LeaseHolderOwner(controller: stranger, session: "B"),
                                           acquire: { throw CancellationError() })

        services.controllerDisconnected(controller)
        let downed = await services.revoked(controller)
        XCTAssertEqual(downed, [mine])
        XCTAssertEqual(runner.downs, [mine])
        try await clock.advance()   // the disconnect's orphan timer
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(runner.downs, [mine], "downed once")
        XCTAssertFalse(runner.downs.contains(theirs))
    }

    // MARK: - port.open

    func testPortOpenRoundTripsThroughAnEchoServer() async throws {
        let server = try TCPServer { fd in
            while let chunk = TCPServer.readChunk(fd) { TCPServer.writeAll(fd, chunk) }
        }
        let (services, pair) = try forwardFixture()
        let channel = try await pair.controller.open()

        let reply = try await services.handle(.portOpen(service: "r1", remote: server.port, channel: channel.id),
                                              controller: controller, accept: { try await pair.host.accept($0) })
        XCTAssertEqual(reply, .portOpen)

        let payload = Data((0..<300_000).map { UInt8($0 % 251) })   // past the 256 KiB window
        async let echoed = readAll(channel, count: payload.count)
        try await channel.write(payload)
        let back = try await echoed
        XCTAssertEqual(back, payload)

        await channel.finish()
        let end = try await channel.read()
        XCTAssertNil(end, "the echo server's close reaches the controller as EOF")
        try await waitFor { services.liveForwards == 0 }
    }

    /// The service answers and closes at once. Its last bytes and its close are one result:
    /// the controller reads every byte and then EOF even when it writes after the service has
    /// gone, and the host's send toward the closed socket fails. Cancelling the channel at that
    /// error would put a close frame behind the reply, and the controller's mux drops whatever
    /// it has not read yet on close. The reply fits the window, so all of it is sitting unread
    /// on the controller when that happens.
    func testServerSideCloseDeliversTheWholeReply() async throws {
        let reply = Data((0..<100_000).map { UInt8($0 % 253) })
        let closed = Flag()
        let server = try TCPServer { fd in
            TCPServer.writeAll(fd, reply)
            shutdown(fd, Int32(SHUT_RDWR))   // closed both ways; `TCPServer` closes the fd after
            closed.set()
        }
        let (services, pair) = try forwardFixture()
        let channel = try await pair.controller.open()
        _ = try await services.handle(.portOpen(service: "r1", remote: server.port, channel: channel.id),
                                      controller: controller, accept: { try await pair.host.accept($0) })
        try await waitFor { closed.isSet }
        try await Task.sleep(nanoseconds: 200_000_000)   // the host reads the reply and its EOF

        // Toward a socket the service has closed: the first send draws an RST, the rest EPIPE.
        for _ in 0..<20 {
            try await channel.write(Data(repeating: 0x78, count: 4096))
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        var received = Data()
        while let chunk = try await channel.read() { received.append(chunk) }
        XCTAssertEqual(received, reply)

        await channel.finish()
        try await waitFor { services.liveForwards == 0 }
    }

    /// The client half-closes after its request, and the service replies only once it sees
    /// EOF (`nc -N`, an HTTP/1.0 client): the host must pass the EOF on with `shutdown(SHUT_WR)`
    /// and keep reading, not close the socket.
    func testClientSideHalfCloseStillGetsTheReply() async throws {
        let server = try TCPServer { fd in
            var total = 0
            while let chunk = TCPServer.readChunk(fd) { total += chunk.count }
            TCPServer.writeAll(fd, Data("got \(total)\n".utf8))
        }
        let (services, pair) = try forwardFixture()
        let channel = try await pair.controller.open()
        _ = try await services.handle(.portOpen(service: "r1", remote: server.port, channel: channel.id),
                                      controller: controller, accept: { try await pair.host.accept($0) })

        try await channel.write(Data(repeating: 1, count: 70_000))
        await channel.finish()

        var received = Data()
        while let chunk = try await channel.read() { received.append(chunk) }
        XCTAssertEqual(String(decoding: received, as: UTF8.self), "got 70000\n")
        try await waitFor { services.liveForwards == 0 }
    }

    /// The controller cancels: the host closes its socket too, so the service sees the
    /// connection end rather than hold it open forever.
    func testControllerCancelClosesTheServiceConnection() async throws {
        let sawEnd = Flag()
        let server = try TCPServer { fd in
            while TCPServer.readChunk(fd) != nil {}
            sawEnd.set()
        }
        let (services, pair) = try forwardFixture()
        let channel = try await pair.controller.open()
        _ = try await services.handle(.portOpen(service: "r1", remote: server.port, channel: channel.id),
                                      controller: controller, accept: { try await pair.host.accept($0) })
        try await channel.write(Data("hi".utf8))

        channel.cancel()

        try await waitFor { sawEnd.isSet }
        try await waitFor { services.liveForwards == 0 }
    }

    /// Nothing listens on the remote port: `dial_failed`, and the channel is cancelled at both
    /// ends (A6) rather than left half-open.
    func testDialFailureIsReportedAndCancelsTheChannel() async throws {
        let port = try TCPServer.unusedPort()
        let (services, pair) = try forwardFixture()
        let channel = try await pair.controller.open()

        do {
            _ = try await services.handle(.portOpen(service: "r1", remote: port, channel: channel.id),
                                          controller: controller, accept: { try await pair.host.accept($0) })
            XCTFail("dialled a closed port")
        } catch let error as DelegationError {
            XCTAssertEqual(error.code, "dial_failed")
            XCTAssertTrue(error.message.contains("\(port)"), error.message)
        }
        do { _ = try await channel.read(); XCTFail("the channel stayed open") } catch {}
        XCTAssertEqual(services.liveForwards, 0)
    }

    // MARK: - Fixtures

    private let hostEnv: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSTemporaryDirectory()]
    private let noChannel: @Sendable (ChannelID) async throws -> any ByteChannel = { _ in throw CancellationError() }

    private func makeServices(runner: any RunControlling, workspace: (any WorkspaceStore)? = nil,
                              ports: any PortChecking = FakePorts(held: [:]), screen: ScreenLease = ScreenLease(),
                              clock: any RunClock = SystemRunClock(),
                              isConnected: @escaping @Sendable (UUID) -> Bool = { _ in false },
                              orphanTimeout: TimeInterval = 1800) -> DelegationHostServices {
        let context = DelegationHostContext(runner: runner, workspace: workspace ?? Workspace(root: TempRepo.scratch()),
                                            portCheck: ports, screen: screen, isConnected: isConnected)
        return DelegationHostServices(context: context, clock: clock, orphanTimeout: orphanTimeout)
    }

    /// A services object whose run `r1` belongs to `controller`, plus a mux pair to forward over.
    private func forwardFixture() throws -> (DelegationHostServices, MuxPair) {
        let runner = FakeRunner()
        runner.owners["r1"] = LeaseHolderOwner(controller: controller, session: "A")
        return (makeServices(runner: runner), MuxPair())
    }

    private func serviceSpec() -> RunSpec {
        RunSpec(command: "serve", subdir: "", env: [:], pty: false, screen: false, service: true,
                downCommand: nil, ports: [])
    }

    private func tempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    @discardableResult
    private func push(_ repo: TempRepo, to store: Workspace) async throws -> SnapshotRef {
        let ref = try await Snapshotter().snapshot(worktree: repo.url, host: "mini", include: [])
        let tips = try await store.tips(controller: controller, repoRoot: ref.repoRoot, wtKey: ref.wtKey)
        let bundle = try await BundleMaker().bundle(worktree: repo.url, snapshot: ref, haves: tips)
        try await store.receive(controller: controller, bundle: bundle, ref: ref)
        return ref
    }

    private func waitUntilStarted(_ runner: Runner, _ id: String) async throws {
        try await waitFor { runner.phase(runID: id) == .running }
    }

    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 10,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("condition never held", file: file, line: line) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// Reads until `count` bytes have arrived or the channel ends.
private func readAll(_ channel: any ByteChannel, count: Int) async throws -> Data {
    var out = Data()
    while out.count < count, let chunk = try await channel.read() { out.append(chunk) }
    return out
}

// MARK: - Fakes

private final class FakeRunner: RunControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _owners: [String: LeaseHolderOwner] = [:]
    private var _downs: [String] = []
    private var next = 1

    var owners: [String: LeaseHolderOwner] {
        get { lock.withLock { _owners } }
        set { lock.withLock { _owners = newValue } }
    }
    var downs: [String] { lock.withLock { _downs } }

    func start(_ spec: RunSpec, owner: LeaseHolderOwner, acquire: @escaping @Sendable () async throws -> CheckoutLease) -> String {
        lock.withLock {
            defer { next += 1 }
            _owners["r\(next)"] = owner
            return "r\(next)"
        }
    }
    func events(runID: String, from offset: Int64) -> AsyncThrowingStream<RunEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func signal(runID: String, _ sig: Int32) throws {}
    func cancel(runID: String) {}
    func down(runID: String) async throws { lock.withLock { _downs.append(runID) } }
    func owner(runID: String) -> LeaseHolderOwner? { lock.withLock { _owners[runID] } }
    func liveRuns(controller: UUID) -> [String] {
        lock.withLock { _owners.filter { $0.value.controller == controller && !_downs.contains($0.key) }.map(\.key).sorted() }
    }
    func phase(runID: String) -> RunPhase? { nil }
    func shutdown(grace: Double, deadline: Double) async {}
}

private struct FakePorts: PortChecking {
    let held: [UInt16: PortHolder]
    func holder(of port: UInt16) async -> PortHolder { held[port] ?? .free }
}

private struct FixedConsole: ConsoleSessionProbing {
    let state: ConsoleSession
    func current() -> ConsoleSession { state }
}

private final class Connected: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: Set<UUID> = []
    func set(_ slot: UUID, _ on: Bool) { lock.withLock { if on { slots.insert(slot) } else { slots.remove(slot) } } }
    var check: @Sendable (UUID) -> Bool { { [self] slot in lock.withLock { slots.contains(slot) } } }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func set() { lock.withLock { raised = true } }
    var isSet: Bool { lock.withLock { raised } }
}

/// Sleeps suspend until the test wakes them, oldest first, so a 30-minute timeout costs nothing.
private final class ManualClock: RunClock, @unchecked Sendable {
    private let lock = NSLock()
    private var sleepers: [CheckedContinuation<Void, Never>] = []
    private var asked: [Double] = []

    func sleep(seconds: Double) async {
        await withCheckedContinuation { cont in
            lock.withLock {
                asked.append(seconds)
                sleepers.append(cont)
            }
        }
    }

    var requested: [Double] { lock.withLock { asked } }

    func advance(file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let next: CheckedContinuation<Void, Never>? = lock.withLock { sleepers.isEmpty ? nil : sleepers.removeFirst() }
            if let next { next.resume(); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("nothing was sleeping on the clock", file: file, line: line)
    }
}

/// Two muxes cross-wired in memory, as a real connection would carry their binary frames.
private final class MuxPair: @unchecked Sendable {
    private var _controller: ChannelMux!
    private var _host: ChannelMux!
    var controller: ChannelMux { _controller }
    var host: ChannelMux { _host }

    init() {
        _controller = ChannelMux(role: .controller) { [unowned self] in self._host.receive(binary: $0) }
        _host = ChannelMux(role: .host) { [unowned self] in self._controller.receive(binary: $0) }
    }
}

/// A blocking loopback TCP server: one thread per connection runs `serve`, then closes.
private final class TCPServer: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32

    init(serve: @escaping @Sendable (Int32) -> Void) throws {
        (fd, port) = try Self.listen()
        let fd = self.fd
        Thread.detachNewThread {
            while true {
                let conn = accept(fd, nil, nil)
                if conn < 0 { return }
                Thread.detachNewThread {
                    serve(conn)
                    close(conn)
                }
            }
        }
    }

    // Never closed: closing a listener another thread is blocked in `accept` on lets the fd
    // number be reused by a later test's socket, and that thread would then steal its
    // connections. A few leaked fds in a test process cost nothing.

    /// A port nothing listens on: bound once, then released.
    static func unusedPort() throws -> UInt16 {
        let (fd, port) = try listen()
        close(fd)
        return port
    }

    private static func listen() throws -> (Int32, UInt16) {
        #if os(Linux)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { p -> Bool in
                bind(fd, p, len) == 0 && startListening(fd) && getsockname(fd, p, &len) == 0
            }
        }
        guard fd >= 0, bound else { throw POSIXError(.EADDRNOTAVAIL) }
        return (fd, UInt16(bigEndian: addr.sin_port))
    }

    static func readChunk(_ fd: Int32) -> Data? {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        return n > 0 ? Data(buf[0..<n]) : nil
    }

    static func writeAll(_ fd: Int32, _ data: Data) {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { send(fd, $0.baseAddress! + offset, data.count - offset, 0) }
            if n <= 0 { return }
            offset += n
        }
    }
}

/// The libc `listen`, from outside `TCPServer`, whose own `listen()` shadows it.
private func startListening(_ fd: Int32) -> Bool {
    listen(fd, 16) == 0
}
