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
            XCTAssertEqual(error.code, "port_held")
            XCTAssertTrue(error.message.hasPrefix("localhost:\(squatter.port) is held by "), error.message)
            XCTAssertTrue(error.message.contains("(pid \(getpid()))"), "names this process via lsof: \(error.message)")
            XCTAssertNotNil(error.message.range(of: #"; try --port \d+:5432 or --port auto:5432$"#, options: .regularExpression),
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
            XCTAssertTrue(error.message.hasPrefix(#"localhost:\#(port) is held by Flight Deck session "api"; try --port "#),
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
        for port in locals { XCTAssertTrue(Squatter.canBind(port)) }
    }

    /// Bytes go both ways through an in-memory channel, including a client that connected
    /// *before* forwarding started (held in the backlog, not refused), and a half-close: the
    /// client shuts its write side and still reads the whole reply.
    func testForwarderPipesBytesBothWays() async throws {
        let held = try await PortForwarder().reserve([PortMapping(local: .auto, remote: 5432)], session: "s")
        defer { held.release() }
        let port = held.forwards[0].local
        let reply = Task.detached { try Squatter.exchange(port: port, send: Data("ping".utf8)) }

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

    func testReleaseIsIdempotent() async throws {
        let forwarder = PortForwarder()
        let port = try Squatter.freePort()
        let held = try await forwarder.reserve([PortMapping(local: .fixed(port), remote: 80)], session: "s")
        XCTAssertEqual(forwarder.session(holding: port), "s")
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { held.release() } }
        }
        held.release()
        XCTAssertNil(forwarder.session(holding: port))
        XCTAssertFalse(Squatter.connects(port), "a released forward accepts nothing")
        // And the port can be reserved again, by anyone.
        let again = try await forwarder.reserve([PortMapping(local: .fixed(port), remote: 80)], session: "t")
        again.release()
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
    private let hostEnds: AsyncStream<MemoryChannel>
    private let hostEndsIn: AsyncStream<MemoryChannel>.Continuation
    private var nextID: ChannelID = 1

    init() { (hostEnds, hostEndsIn) = AsyncStream.makeStream() }

    var remotes: [UInt16] {
        get { lock.withLock { _remotes } }
        set { lock.withLock { _remotes = newValue } }
    }

    func open() async throws -> any ByteChannel {
        let id: ChannelID = lock.withLock { defer { nextID += 2 }; return nextID }
        let (mine, theirs) = MemoryChannel.pair(id: id)
        hostEndsIn.yield(theirs)
        return mine
    }

    func nextHostEnd() async throws -> MemoryChannel {
        var it = hostEnds.makeAsyncIterator()
        guard let end = await it.next() else { throw CancellationError() }
        return end
    }
}

private final class MemoryChannel: ByteChannel, @unchecked Sendable {
    let id: ChannelID
    private var inbox: AsyncStream<Data>.Iterator
    private let outbox: AsyncStream<Data>.Continuation

    private init(id: ChannelID, inbox: AsyncStream<Data>, outbox: AsyncStream<Data>.Continuation) {
        self.id = id
        self.inbox = inbox.makeAsyncIterator()
        self.outbox = outbox
    }

    static func pair(id: ChannelID) -> (MemoryChannel, MemoryChannel) {
        let (aToB, aToBIn) = AsyncStream<Data>.makeStream()
        let (bToA, bToAIn) = AsyncStream<Data>.makeStream()
        return (MemoryChannel(id: id, inbox: bToA, outbox: aToBIn), MemoryChannel(id: id, inbox: aToB, outbox: bToAIn))
    }

    func write(_ data: Data) async throws { outbox.yield(data) }
    func read() async throws -> Data? { await inbox.next() }
    func finish() async { outbox.finish() }
    func cancel() { outbox.finish() }
}

/// Plain BSD sockets, standing in for "some other program" on the Mac.
private final class Squatter {
    let port: UInt16
    private var fd: Int32

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

    private static func withAddr<T>(_ port: UInt16, any: Bool = false, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var addr = loopback(port, any: any)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }

    static func canBind(_ port: UInt16, loopback: Bool = true) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        return withAddr(port, any: !loopback) { bind(fd, $0, $1) == 0 }
    }

    static func connects(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        return withAddr(port) { connect(fd, $0, $1) == 0 }
    }

    /// Connects, sends, half-closes, and reads to EOF (10 s receive timeout).
    static func exchange(port: UInt16, send payload: Data) throws -> Data {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard withAddr(port, { connect(fd, $0, $1) }) == 0 else { throw POSIXError(.ECONNREFUSED) }
        _ = payload.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        shutdown(fd, SHUT_WR)
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n < 0 { throw POSIXError(.ETIMEDOUT) }
            if n == 0 { return out }
            out.append(buf, count: n)
        }
    }
}
