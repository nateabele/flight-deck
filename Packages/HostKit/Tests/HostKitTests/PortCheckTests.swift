import XCTest
@testable import HostKit
#if canImport(Glibc)
import Glibc
#endif

/// The host's half of preflight step 5 (spec §7): is a remote port free, and if not, who holds
/// it. The parsers run on captured output so they are pinned on both platforms; the live tests
/// bind a real port, because a probe that passes on fixtures but misreads the kernel would
/// report "free" for the port a service is about to collide on.
final class PortCheckTests: XCTestCase {
    // MARK: lsof (macOS)

    /// Captured from `lsof -nP -iTCP:<p> -sTCP:LISTEN` on macOS 26.
    private let lsofCapture = """
    COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
    Python  62267 me    3u  IPv4 0x1998c7c81404b3f2      0t0  TCP 127.0.0.1:65076 (LISTEN)

    """

    func testLsofNamesTheFirstListener() {
        XCTAssertEqual(PortCheck.parseLsof(lsofCapture), .process(name: "Python", pid: 62267))
    }

    /// lsof escapes a space in a command name as `\x20`; splitting on whitespace is only safe
    /// because of that, and the name the user reads should have its space back.
    func testLsofUnescapesSpacesAndIgnoresAnEmptyAnswer() {
        let text = "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\nGoogle\\x20Ch 812 me 3u IPv4 0x1 0t0 TCP *:5432 (LISTEN)\n"
        XCTAssertEqual(PortCheck.parseLsof(text), .process(name: "Google Ch", pid: 812))
        XCTAssertNil(PortCheck.parseLsof(""))
        XCTAssertNil(PortCheck.parseLsof("COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n"))
    }

    // MARK: /proc (Linux)

    private let procNetTCP = """
      sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
       0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 4242 1 0000000000000000 100 0 0 10 0
       1: 0100007F:1F90 0100007F:D2F0 01 00000000:00000000 00:00000000 00000000     0        0 9999 1 0000000000000000 20 4 30 10 -1
       2: 00000000:1538 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 5150 1 0000000000000000 100 0 0 10 0

    """

    private let procNetTCP6 = """
      sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
       0: 00000000000000000000000000000000:1F90 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 6006 1 0000000000000000 100 0 0 10 0

    """

    /// Only LISTEN rows (st 0A) count: an established connection *to* 8080 shares the local
    /// port on the client side and would otherwise name the client as the holder.
    func testProcNetTCPYieldsOnlyListeningInodesForThePort() {
        XCTAssertEqual(PortCheck.listeningInodes(procNetTCP, port: 8080), [4242])
        XCTAssertEqual(PortCheck.listeningInodes(procNetTCP6, port: 8080), [6006])
        XCTAssertEqual(PortCheck.listeningInodes(procNetTCP, port: 5432), [5150])
        XCTAssertEqual(PortCheck.listeningInodes(procNetTCP, port: 22), [])
    }

    func testSocketInodeReadsOnlySocketLinks() {
        XCTAssertEqual(PortCheck.socketInode(link: "socket:[4242]"), 4242)
        XCTAssertNil(PortCheck.socketInode(link: "pipe:[4242]"))
        XCTAssertNil(PortCheck.socketInode(link: "/dev/null"))
    }

    /// The fd walk against a fake `/proc` tree, so it is exercised on macOS too.
    func testProcWalkFindsTheProcessOwningTheInode() throws {
        let root = try tempDir()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("net"), withIntermediateDirectories: true)
        try procNetTCP.write(to: root.appendingPathComponent("net/tcp"), atomically: true, encoding: .utf8)
        for (pid, comm, links) in [("17", "sshd", ["socket:[1]", "/dev/null"]), ("812", "postgres", ["pipe:[3]", "socket:[5150]"])] {
            let fd = root.appendingPathComponent("\(pid)/fd")
            try fm.createDirectory(at: fd, withIntermediateDirectories: true)
            try "\(comm)\n".write(to: root.appendingPathComponent("\(pid)/comm"), atomically: true, encoding: .utf8)
            for (i, link) in links.enumerated() {
                try fm.createSymbolicLink(atPath: fd.appendingPathComponent("\(i)").path, withDestinationPath: link)
            }
        }
        try fm.createDirectory(at: root.appendingPathComponent("self"), withIntermediateDirectories: true)
        let check = PortCheck(run: { _, _ in nil }, searchPath: [], procRoot: root)
        XCTAssertEqual(check.procHolder(of: 5432), .process(name: "postgres", pid: 812))
        XCTAssertNil(check.procHolder(of: 22))
    }

    // MARK: Docker

    /// Captured from `docker ps --format '{{.Names}}\t{{.Ports}}'` (OrbStack), plus a range
    /// and an unpublished port.
    private let dockerCapture = """
    duino-compile\t0.0.0.0:3030->3030/tcp, [::]:3030->3030/tcp
    f0-mongo\t127.0.0.1:27017->27017/tcp
    beacon-graph-ui-postgres-1\t0.0.0.0:5434->5432/tcp, [::]:5434->5432/tcp
    ranged\t0.0.0.0:8000-8002->8000-8002/tcp
    udp-only\t0.0.0.0:5353->5353/udp
    internal\t6379/tcp

    """

    /// The *published* (host) side is what holds the port: postgres-1 holds 5434, not 5432.
    func testDockerPSNamesTheContainerPublishingThePort() {
        XCTAssertEqual(PortCheck.parseDockerPS(dockerCapture, port: 5434), "beacon-graph-ui-postgres-1")
        XCTAssertNil(PortCheck.parseDockerPS(dockerCapture, port: 5432))
        XCTAssertEqual(PortCheck.parseDockerPS(dockerCapture, port: 27017), "f0-mongo")
        XCTAssertEqual(PortCheck.parseDockerPS(dockerCapture, port: 8001), "ranged")
        XCTAssertNil(PortCheck.parseDockerPS(dockerCapture, port: 5353))
        XCTAssertNil(PortCheck.parseDockerPS(dockerCapture, port: 6379))
    }

    /// Docker Desktop and OrbStack hold a published port in their own backend process, so
    /// lsof alone would say "OrbStack (pid 12191)" — true, and useless. The container is
    /// asked first. Run against a fake `docker` on the search path holding a real bound port.
    func testRemotePortHeldByContainerNamed() async throws {
        let listener = try LiveListener()
        defer { listener.close() }
        let bin = try tempDir()
        let docker = bin.appendingPathComponent("docker")
        try """
        #!/bin/sh
        [ "$1" = ps ] && [ "$2" = --format ] || exit 2
        printf 'other\\t0.0.0.0:1->1/tcp\\n'
        printf 'pg\\t0.0.0.0:\(listener.port)->5432/tcp, [::]:\(listener.port)->5432/tcp\\n'
        """.write(to: docker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)

        let check = PortCheck(searchPath: [bin.path])
        let holder = await check.holder(of: listener.port)
        XCTAssertEqual(holder, .container(name: "pg"))
        let statuses = await check.check([listener.port])
        XCTAssertEqual(statuses, [PortStatus(port: listener.port, holder: .container(name: "pg"))])
    }

    // MARK: Live

    /// One real bind per platform: the probe sees a held port, the holder lookup (lsof on
    /// macOS, /proc on Linux) names this very process, and the port reads free once closed.
    func testLiveHeldPortNamesThisProcessThenReadsFree() async throws {
        let listener = try LiveListener()
        let check = PortCheck(searchPath: [])
        XCTAssertFalse(PortCheck.isFree(listener.port))
        let holder = await check.holder(of: listener.port)
        guard case .process(let name, let pid) = holder else {
            return XCTFail("expected a process holder, got \(holder)")
        }
        XCTAssertEqual(pid, getpid())
        XCTAssertFalse(name.isEmpty)
        listener.close()
        XCTAssertTrue(PortCheck.isFree(listener.port))
        let after = await check.holder(of: listener.port)
        XCTAssertEqual(after, .free)
    }

    /// A listener on the wildcard address holds the port for loopback too; the probe must
    /// not bind beside it and call the port free.
    func testLiveWildcardListenerIsHeld() throws {
        let listener = try LiveListener(loopback: false)
        defer { listener.close() }
        XCTAssertFalse(PortCheck.isFree(listener.port))
    }

    // MARK: Suggestion

    /// The spec's own example: 5432 held, 15432 held too, so 15433.
    func testSuggestionStartsTenThousandUpAndSkipsHeldAndExcluded() {
        let held: Set<UInt16> = [5432, 15432]
        XCTAssertEqual(PortCheck.suggestFree(near: 5432, excluding: [], isFree: { !held.contains($0) }), 15433)
        XCTAssertEqual(PortCheck.suggestFree(near: 5432, excluding: [15433], isFree: { !held.contains($0) }), 15434)
        XCTAssertEqual(PortCheck.suggestFree(near: 60000, excluding: [], isFree: { _ in true }), 60001)
        XCTAssertNil(PortCheck.suggestFree(near: 5432, excluding: [], isFree: { _ in false }))
    }

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("portcheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// A real listening IPv4 socket on an OS-chosen port, standing in for "something else holds
/// this port".
final class LiveListener {
    let port: UInt16
    private var fd: Int32

    init(loopback: Bool = true) throws {
        #if os(Linux)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = loopback ? inet_addr("127.0.0.1") : 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, len) == 0 && listen(fd, 8) == 0 && getsockname(fd, sa, &len) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRINUSE) }
        self.fd = fd
        port = UInt16(bigEndian: addr.sin_port)
    }

    func close() {
        guard fd >= 0 else { return }
        #if os(Linux)
        _ = Glibc.close(fd)
        #else
        _ = Darwin.close(fd)
        #endif
        fd = -1
    }

    deinit { close() }
}
