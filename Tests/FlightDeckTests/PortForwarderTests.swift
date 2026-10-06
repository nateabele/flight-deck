import Foundation
import HostKit
import XCTest
@testable import FlightDeck

/// The Mac's half of service forwarding (spec §6.2) and preflight step 4 (§7), against real
/// loopback sockets: the guarantees here are about what the kernel lets bind, which a fake
/// listener cannot show.
final class PortForwarderTests: XCTestCase {
    /// Review Focus 3. A requested local port is already taken: delegation fails at step 4,
    /// before sync and before any remote check; the error names the holder and a free port;
    /// and the port it *had* bound for the other mapping is free again the moment it returns.
    func testHeldPortFailsBeforeSyncAndReleasesAll() async throws {
        let squatter = try Squatter()
        defer { squatter.close() }
        let free = try Squatter.freePort()
        let forwarder = PortForwarder()
        let checks = Steps(plan: PreflightPlan(host: "mini",
                                               ports: [PortMapping(local: .fixed(free), remote: 3000),
                                                       PortMapping(local: .fixed(squatter.port), remote: 5432)],
                                               screen: false, service: true, sync: true),
                           forwarder: forwarder)
        var synced = false
        do {
            _ = try await Preflight.run(checks)
            synced = true   // where sync would begin
            XCTFail("expected the held port to fail preflight")
        } catch let error as DelegationError {
            XCTAssertEqual(error.code, "local_port_held")
            XCTAssertTrue(error.message.hasPrefix("localhost:\(squatter.port) is held by "), error.message)
            XCTAssertTrue(error.message.contains("(pid \(getpid()))"), "names this process via lsof: \(error.message)")
            XCTAssertNotNil(error.message.range(of: #" — try --port \d+:5432 or --port auto:5432$"#, options: .regularExpression),
                            error.message)
        }
        XCTAssertFalse(synced)
        XCTAssertEqual(checks.calls, ["resolve", "host", "paths", "localPorts"])
        XCTAssertTrue(Squatter.canBind(free), "the port bound before the conflict was released")
        XCTAssertNil(forwarder.session(holding: free))
    }

    /// Flight Deck's own forward is named by its session, not as "Flight Deck (pid …)".
    func testOwnForwardIsNamedBySession() async throws {
        let forwarder = PortForwarder()
        let port = try Squatter.freePort()
        let held = try await forwarder.reserve([PortMapping(local: .fixed(port), remote: 5432)], session: "api")
        defer { held.release() }
        do {
            _ = try await forwarder.reserve([PortMapping(local: .fixed(port), remote: 5432)], session: "web")
            XCTFail("expected a conflict")
        } catch let error as DelegationError {
            XCTAssertTrue(error.message.hasPrefix(#"localhost:\#(port) is held by Flight Deck session "api" — try --port "#),
                          error.message)
        }
    }

    /// The reservation really holds the port from preflight until release: nothing else can
    /// bind it in between, on loopback or the wildcard, and it is bindable straight after.
    func testSecondBindFailsWhileHeldAndSucceedsAfterRelease() async throws {
        let port = try Squatter.freePort()
        let held = try await PortForwarder().reserve([PortMapping(local: .fixed(port), remote: 80)], session: "s")
        XCTAssertEqual(held.forwards, [PortForward(local: port, remote: 80)])
        XCTAssertFalse(Squatter.canBind(port))
        XCTAssertFalse(Squatter.canBind(port, loopback: false))
        XCTAssertFalse(PortCheck.isFree(port))
        held.release()
        await held.released()
        XCTAssertTrue(Squatter.canBind(port))
    }

    func testAutoPicksFreePort() async throws {
        let held = try await PortForwarder().reserve([PortMapping(local: .auto, remote: 3000),
                                                      PortMapping(local: .auto, remote: 3001)], session: "s")
        let locals = held.forwards.map(\.local)
        XCTAssertEqual(held.forwards.map(\.remote), [3000, 3001])
        XCTAssertEqual(Set(locals).count, 2)
        XCTAssertFalse(locals.contains(0))
        for port in locals { XCTAssertFalse(Squatter.canBind(port), "auto port \(port) is held") }
        held.release()
        await held.released()
        for port in locals { XCTAssertTrue(Squatter.canBind(port)) }
    }

    /// Bytes go both ways through an in-memory channel, including a client that connected
    /// *before* forwarding started (held in the backlog, not refused), and a half-close: the
    /// client shuts its write side and still reads the whole reply.
    func testForwarderPipesBytesBothWays() async throws {
        let held = try await PortForwarder().reserve([PortMapping(local: .auto, remote: 5432)], session: "s")
        defer { held.release() }
        let port = held.forwards[0].local
        let reply = Task.detached { try Client(port: port).exchange(Data("ping".utf8)) }

        let opener = MemoryOpener()
        held.startForwarding { remote in
            opener.remotes.append(remote)
            return opener
        }
        let host = try await opener.nextHostEnd()
        var received = Data()
        while let chunk = try await host.read() { received.append(chunk) }
        XCTAssertEqual(String(decoding: received, as: UTF8.self), "ping")
        try await host.write(Data("PONG ".utf8))
        try await host.write(Data(repeating: 0x2A, count: 200_000))
        await host.finish()

        let got = try await reply.value
        XCTAssertEqual(got.count, 5 + 200_000)
        XCTAssertEqual(got.prefix(5), Data("PONG ".utf8))
        XCTAssertEqual(opener.remotes, [5432])
    }

    /// Connections come and go for the life of a service; the bookkeeping for each must go
    /// with it. Before the fix every served connection's task stayed in `tasks` forever.
    func testConnectionChurnLeavesNothingBehind() async throws {
        let held = try await PortForwarder().reserve([PortMapping(local: .auto, remote: 80)], session: "s")
        defer { held.release() }
        let port = held.forwards[0].local
        let opener = MemoryOpener()
        held.startForwarding { _ in opener }
        let echo = Task {
            for await host in opener.hostEnds {
                Task {
                    while let chunk = try await host.read() { try await host.write(chunk) }
                    await host.finish()
                }
            }
        }
        defer { echo.cancel() }
        for i in 0..<200 {
            let got = try await Task.detached { try Client(port: port).exchange(Data("\(i)".utf8)) }.value
            XCTAssertEqual(String(decoding: got, as: UTF8.self), "\(i)")
        }
        let deadline = Date().addingTimeInterval(10)
        while held.bookkeeping != (0, 0), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(held.bookkeeping == (0, 0), "live/tasks left: \(held.bookkeeping)")
    }

    /// The host side hangs up first (its service closed the connection): the client reads the
    /// reply and EOF, and can still send, which the host reads before its own EOF.
    func testServerSideHalfClose() async throws {
        let held = try await PortForwarder().reserve([PortMapping(local: .auto, remote: 80)], session: "s")
        defer { held.release() }
        let opener = MemoryOpener()
        held.startForwarding { _ in opener }
        let client = try Client(port: held.forwards[0].local)
        let host = try await opener.nextHostEnd()
        try await host.write(Data("hi".utf8))
        await host.finish()
        let first = try await Task.detached { try client.readToEOF() }.value
        XCTAssertEqual(String(decoding: first, as: UTF8.self), "hi")
        client.send(Data("after".utf8))
        client.shutdownWrite()
        var received = Data()
        while let chunk = try await host.read() { received.append(chunk) }
        XCTAssertEqual(String(decoding: received, as: UTF8.self), "after")
        client.close()
    }

    /// A slow host backs up the client instead of the Mac buffering without bound: while the
    /// host reads nothing, the forwarder holds at most one channel window plus one chunk.
    func testSlowHostAppliesBackpressure() async throws {
        let held = try await PortForwarder().reserve([PortMapping(local: .auto, remote: 80)], session: "s")
        defer { held.release() }
        let window = 64 * 1024
        let opener = MemoryOpener(capacity: window)
        held.startForwarding { _ in opener }
        let total = 8 * 1024 * 1024
        let port = held.forwards[0].local
        let sender = Task.detached {
            let c = try Client(port: port)
            c.send(Data(repeating: 7, count: total))
            c.shutdownWrite()
            return c
        }
        let host = try await opener.nextHostEnd()
        // The bound only means something once the forwarder has had the bytes to exceed it:
        // first the window fills (the sender is running and the forwarder is reading), then,
        // with the host still reading nothing, it must stay put.
        let deadline = Date().addingTimeInterval(10)
        while host.accepted < window, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThanOrEqual(host.accepted, window, "the forwarder never filled the window")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertLessThanOrEqual(host.accepted, window + 64 * 1024, "the forwarder kept reading a host that was not")
        var received = 0
        while let chunk = try await host.read() { received += chunk.count }
        XCTAssertEqual(received, total)
        try await sender.value.close()
    }

    /// `down` then `up` on the same port straight after a connection the forwarder closed
    /// first. The connection's TIME_WAIT blocks a plain bind, but not our own rebind: Network
    /// framework's sockets carry the reuse flags their TIME_WAIT inherits (measured).
    func testDownUpAfterAConnectionRebinds() async throws {
        let forwarder = PortForwarder(timeWaitRetries: 0, retryInterval: .zero)
        let port = try await Self.servedAndDowned(forwarder)
        XCTAssertFalse(Squatter.canBind(port), "precondition: the connection left the port in TIME_WAIT")
        let again = try await forwarder.reserve([PortMapping(local: .fixed(port), remote: 80)], session: "s")
        XCTAssertEqual(again.forwards, [PortForward(local: port, remote: 80)])
        again.release()
    }

    /// A TIME_WAIT another program left (a local dev server the user just stopped) does block
    /// Network framework's bind (measured). Nothing listens, so the reservation waits it out
    /// rather than reporting a conflict nobody holds. Takes up to the kernel's ~30 s.
    func testForeignTimeWaitIsRetriedUntilItClears() async throws {
        let port = try Squatter.timeWaitPort()
        XCTAssertFalse(Squatter.canBind(port), "precondition: the port is in TIME_WAIT")
        XCTAssertTrue(PortCheck.isFree(port), "precondition: nothing listens")
        let forwarder = PortForwarder(timeWaitRetries: 40, retryInterval: .seconds(1))
        let held = try await forwarder.reserve([PortMapping(local: .fixed(port), remote: 80)], session: "s")
        XCTAssertEqual(held.forwards, [PortForward(local: port, remote: 80)])
        held.release()
    }

    func testTimeWaitThatOutlastsTheRetriesSaysSo() async throws {
        let port = try Squatter.timeWaitPort()
        let forwarder = PortForwarder(timeWaitRetries: 1, retryInterval: .milliseconds(50))
        do {
            let r = try await forwarder.reserve([PortMapping(local: .fixed(port), remote: 80)], session: "s")
            r.release()
            XCTFail("expected TIME_WAIT to outlast one 50 ms retry")
        } catch let error as DelegationError {
            XCTAssertEqual(error.code, "local_port_held")
            XCTAssertEqual(error.message, "localhost:\(port) was just released and is still in TIME_WAIT — retry shortly or use --port auto:80")
        }
    }

    /// Serves one connection the host closes first, then `down`s.
    private static func servedAndDowned(_ forwarder: PortForwarder) async throws -> UInt16 {
        let port = try Squatter.freePort()
        let held = try await forwarder.reserve([PortMapping(local: .fixed(port), remote: 80)], session: "s")
        let opener = MemoryOpener()
        held.startForwarding { _ in opener }
        let client = try Client(port: port)
        let host = try await opener.nextHostEnd()
        try await host.write(Data("bye".utf8))
        await host.finish()
        _ = try await Task.detached { try client.readToEOF() }.value
        client.shutdownWrite()
        while try await host.read() != nil {}
        client.close()
        let deadline = Date().addingTimeInterval(5)
        while held.bookkeeping != (0, 0), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        held.release()
        await held.released()
        return port
    }

    func testReleaseIsIdempotent() async throws {
        let forwarder = PortForwarder()
        let port = try Squatter.freePort()
        let held = try await forwarder.reserve([PortMapping(local: .fixed(port), remote: 80)], session: "s")
        XCTAssertEqual(forwarder.session(holding: port), "s")
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { held.release() } }
        }
        held.release()
        await held.released()
        XCTAssertNil(forwarder.session(holding: port))
        // The port can be reserved again, by anyone...
        let again = try await forwarder.reserve([PortMapping(local: .fixed(port), remote: 80)], session: "t")
        again.release()
        await again.released()
        // ...and a released forward accepts nothing. Probed last: a connect racing the
        // listener's teardown once left the port unbindable for 30 s (1 run in 25).
        XCTAssertFalse(Squatter.connects(port), "a released forward accepts nothing")
    }
}

// MARK: - Fakes

/// Preflight steps with a real `PortForwarder` at step 4 and passing fakes elsewhere.
private final class Steps: PreflightChecks, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    let plan: PreflightPlan
    let forwarder: PortForwarder

    init(plan: PreflightPlan, forwarder: PortForwarder) {
        self.plan = plan
        self.forwarder = forwarder
    }

    var calls: [String] { lock.withLock { _calls } }
    private func record(_ s: String) { lock.withLock { _calls.append(s) } }

    func resolve() async throws -> PreflightPlan { record("resolve"); return plan }
    func hostCapabilities(_ host: String) async throws -> Set<HostCapability>? {
        record("host"); return [.hostInfo, .run, .sync, .service, .screen]
    }
    func checkLocalPaths(_ plan: PreflightPlan) async throws { record("paths") }
    func reserveLocalPorts(_ ports: [PortMapping], host: String) async throws -> any PortReservation {
        record("localPorts")
        return try await forwarder.reserve(ports, session: "tab")
    }
    func remotePorts(_ ports: [UInt16], host: String) async throws -> [PortStatus] {
        record("remotePorts"); return ports.map { PortStatus(port: $0, holder: .free) }
    }
    func screenStatus(_ host: String) async throws -> ScreenStatus {
        record("screen"); return ScreenStatus(supported: true, consoleUser: true, locked: false, holder: nil, queued: 0)
    }
    func checkLFS(_ plan: PreflightPlan) async throws { record("lfs") }
}

/// Opens in-memory channel pairs; the test plays the host on the far end.
private final class MemoryOpener: ChannelOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var _remotes: [UInt16] = []
    let hostEnds: AsyncStream<MemoryChannel>
    private let hostEndsIn: AsyncStream<MemoryChannel>.Continuation
    private var nextID: ChannelID = 1
    private let capacity: Int?

    /// `capacity`: the bytes one direction buffers before `write` suspends, like the mux's
    /// credit window; nil buffers without bound.
    init(capacity: Int? = nil) {
        self.capacity = capacity
        (hostEnds, hostEndsIn) = AsyncStream.makeStream()
    }

    var remotes: [UInt16] {
        get { lock.withLock { _remotes } }
        set { lock.withLock { _remotes = newValue } }
    }

    func open() async throws -> any ByteChannel {
        let id: ChannelID = lock.withLock { defer { nextID += 2 }; return nextID }
        let toHost = MemoryPipe(capacity: capacity), toMac = MemoryPipe(capacity: capacity)
        hostEndsIn.yield(MemoryChannel(id: id, inbox: toHost, outbox: toMac))
        return MemoryChannel(id: id, inbox: toMac, outbox: toHost)
    }

    func nextHostEnd() async throws -> MemoryChannel {
        var it = hostEnds.makeAsyncIterator()
        guard let end = await it.next() else { throw CancellationError() }
        return end
    }
}

/// One direction of a channel: a byte queue whose writer suspends at `capacity`.
private final class MemoryPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var buffered = 0
    private var finished = false
    private var reader: CheckedContinuation<Data?, Never>?
    private var writers: [CheckedContinuation<Void, Never>] = []
    private let capacity: Int?
    private(set) var accepted = 0

    init(capacity: Int?) { self.capacity = capacity }

    private var hasRoom: Bool { capacity.map { buffered < $0 } ?? true }

    func write(_ data: Data) async {
        while true {
            let wrote: Bool = lock.withLock {
                guard hasRoom else { return false }
                accepted += data.count
                if let reader {
                    self.reader = nil
                    reader.resume(returning: data)
                } else {
                    chunks.append(data)
                    buffered += data.count
                }
                return true
            }
            if wrote { return }
            await withCheckedContinuation { cont in
                lock.withLock { if hasRoom || finished { cont.resume() } else { writers.append(cont) } }
            }
        }
    }

    func read() async -> Data? {
        await withCheckedContinuation { cont in
            let waking: [CheckedContinuation<Void, Never>] = lock.withLock {
                if !chunks.isEmpty {
                    let d = chunks.removeFirst()
                    buffered -= d.count
                    cont.resume(returning: d)
                    defer { writers = [] }
                    return writers
                }
                if finished { cont.resume(returning: nil) } else { reader = cont }
                return []
            }
            waking.forEach { $0.resume() }
        }
    }

    func finish() {
        let (r, w): (CheckedContinuation<Data?, Never>?, [CheckedContinuation<Void, Never>]) = lock.withLock {
            finished = true
            defer { reader = nil; writers = [] }
            return (chunks.isEmpty ? reader : nil, writers)
        }
        r?.resume(returning: nil)
        w.forEach { $0.resume() }
    }
}

private final class MemoryChannel: ByteChannel, @unchecked Sendable {
    let id: ChannelID
    private let inbox: MemoryPipe
    private let outbox: MemoryPipe

    init(id: ChannelID, inbox: MemoryPipe, outbox: MemoryPipe) {
        self.id = id
        self.inbox = inbox
        self.outbox = outbox
    }

    /// Bytes the peer has written into this end so far.
    var accepted: Int { inbox.accepted }

    func write(_ data: Data) async throws { await outbox.write(data) }
    func read() async throws -> Data? { await inbox.read() }
    func finish() async { outbox.finish() }
    func cancel() { outbox.finish(); inbox.finish() }
}

/// A blocking TCP client on loopback; tests drive it from detached tasks.
private final class Client: @unchecked Sendable {
    private var fd: Int32

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard Squatter.withAddr(port, { connect(fd, $0, $1) }) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.ECONNREFUSED)
        }
    }

    func send(_ data: Data) {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.send(fd, raw.baseAddress! + off, raw.count - off, 0)
                if n <= 0 { return }
                off += n
            }
        }
    }

    func shutdownWrite() { shutdown(fd, SHUT_WR) }

    /// Reads to EOF; throws on the 10 s receive timeout.
    func readToEOF() throws -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n < 0 { throw POSIXError(.ETIMEDOUT) }
            if n == 0 { return out }
            out.append(buf, count: n)
        }
    }

    /// Send, half-close, read the reply to EOF, close.
    func exchange(_ payload: Data) throws -> Data {
        defer { close() }
        send(payload)
        shutdownWrite()
        return try readToEOF()
    }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    deinit { close() }
}

/// Plain BSD sockets, standing in for "some other program" on the Mac.
private final class Squatter {
    let port: UInt16
    private(set) var fd: Int32

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = Self.loopback(0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && listen(fd, 8) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard ok else { Darwin.close(fd); throw POSIXError(.EADDRINUSE) }
        self.fd = fd
        port = UInt16(bigEndian: addr.sin_port)
    }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    deinit { close() }

    static func freePort() throws -> UInt16 {
        let s = try Squatter()
        defer { s.close() }
        return s.port
    }

    private static func loopback(_ port: UInt16, any: Bool = false) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = any ? 0 : inet_addr("127.0.0.1")
        return addr
    }

    static func withAddr<T>(_ port: UInt16, any: Bool = false, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var addr = loopback(port, any: any)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }

    /// A plain bind, no options: fails on a listener and on TIME_WAIT alike.
    static func canBind(_ port: UInt16, loopback: Bool = true) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        return withAddr(port, any: !loopback) { bind(fd, $0, $1) == 0 }
    }

    /// A port in TIME_WAIT left by another program: a plain-socket server that closed its
    /// connection first, then stopped listening.
    static func timeWaitPort() throws -> UInt16 {
        let listener = try Squatter()
        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(client) }
        guard withAddr(listener.port, { connect(client, $0, $1) }) == 0 else { throw POSIXError(.ECONNREFUSED) }
        let server = accept(listener.fd, nil, nil)
        Darwin.close(server)              // the server closes first, so the TIME_WAIT is on its port
        var byte: UInt8 = 0
        _ = recv(client, &byte, 1, 0)
        listener.close()
        return listener.port
    }

    static func connects(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        return withAddr(port) { connect(fd, $0, $1) == 0 }
    }
}
