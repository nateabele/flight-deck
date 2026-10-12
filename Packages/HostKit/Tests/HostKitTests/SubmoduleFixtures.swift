import Foundation
import XCTest

/// A gate a test closes on a dispatch thread (inside a git step, through a test seam) and opens
/// from the test. Blocking happens off the cooperative pool, as the real git does.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var holders = 0
    private let opened = DispatchSemaphore(value: 0)

    /// Blocks the calling thread until `open()`. Returns at once once opened.
    func hold() {
        let wait: Bool = lock.withLock {
            guard !isOpen else { return false }
            holders += 1
            return true
        }
        if wait { opened.wait() }
    }

    func open() {
        let n: Int = lock.withLock {
            guard !isOpen else { return 0 }
            isOpen = true
            return holders
        }
        for _ in 0..<n { opened.signal() }
    }

    var held: Int { lock.withLock { holders } }

    /// Suspends until at least one thread is held, or fails after `seconds`.
    func waitUntilHeld(seconds: Double = 20, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while held == 0 {
            if Date() > deadline { XCTFail("nothing reached the gate", file: file, line: line); throw CancellationError() }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// A flag set by one task and polled, with a deadline, by another: a task blocked inside a
/// lock cannot be cancelled, so a test that awaited it directly would hang instead of failing.
final class Done: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }

    func wait(seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !isSet && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        return isSet
    }
}

/// Fixtures cross into the tasks a concurrency test starts; each is used by one task at a time.
extension TempRepo: @unchecked Sendable {}

/// A free TCP port on the loopback, by binding port 0 and letting it go.
func freeLoopbackPort() throws -> UInt16 {
    let stub = try TCPStub(.close)
    defer { stub.stop() }
    return stub.port
}

/// A `git daemon` serving every repository under `base` read-only, on the loopback: a real
/// network transport (unlike a path, which git fetches through a local shortcut), so the
/// shallow-fetch and fallback paths run as they do against a server.
final class GitDaemon: @unchecked Sendable {
    let port: UInt16
    private var pid: pid_t = 0

    /// Started with `posix_spawn`, stdio on /dev/null and every other descriptor closed, not
    /// through `Process`. Measured: Foundation on Linux never sees a `Process` exit while a
    /// descendant it left running (the daemon) still holds a descriptor inherited from that
    /// spawn, so `waitUntilExit` on `git daemon --detach` hung forever, and so did the reaping
    /// of gits run after a `Process`-started daemon.
    init(base: URL) throws {
        port = UInt16.random(in: 20000...40000)
        let argv = ["/usr/bin/env", "git", "daemon", "--reuseaddr", "--export-all", "--listen=127.0.0.1",
                    "--port=\(port)", "--base-path=\(base.path)", base.path]
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        pid = try Self.spawn(argv, env: env.map { "\($0.key)=\($0.value)" })
        let deadline = Date().addingTimeInterval(10)
        while !TCPStub.accepts(port: port) {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid { pid = 0; throw XCTSkip("git daemon is not available here") }
            guard Date() < deadline else { stop(); throw XCTSkip("git daemon did not start") }
            usleep(50_000)
        }
    }

    func url(_ name: String) -> String { "git://127.0.0.1:\(port)/\(name)" }

    /// The daemon and the children it forked for connections (its own process group).
    func stop() {
        guard pid > 0 else { return }
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        pid = 0
    }

    deinit { stop() }

    private static func spawn(_ argv: [String], env: [String]) throws -> pid_t {
        #if canImport(Glibc)
        var actions = posix_spawn_file_actions_t()
        var attr = posix_spawnattr_t()
        #else
        var actions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attr)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attr)
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setpgroup(&attr, 0)
        var flags = Int32(POSIX_SPAWN_SETSIGMASK) | Int32(POSIX_SPAWN_SETPGROUP)
        #if canImport(Glibc)
        posix_spawn_file_actions_addclosefrom_np(&actions, 3)
        #else
        flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #endif
        posix_spawnattr_setflags(&attr, Int16(flags))
        var cargs = argv.map { strdup($0) } + [nil]
        var cenv = env.map { strdup($0) } + [nil]
        defer { (cargs + cenv).forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &actions, &attr, &cargs, &cenv)
        guard rc == 0 else { throw XCTSkip("could not start git daemon: errno \(rc)") }
        return pid
    }
}

/// A TCP listener on the loopback that either drops every connection at once (a server that
/// is down or refuses us) or accepts it and never answers (a hung server). It counts
/// connections, and notices when a client goes away: proof the client process died.
final class TCPStub: @unchecked Sendable {
    enum Mode { case close, hang }

    let port: UInt16
    private let mode: Mode
    private let listener: Int32
    private let lock = NSLock()
    private var accepted = 0
    private var gone = 0
    private var clients: [Int32] = []
    private var stopped = false

    init(_ mode: Mode) throws {
        self.mode = mode
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = Self.loopback(port: 0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        listener = fd
        port = UInt16(bigEndian: addr.sin_port)
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    var connections: Int { lock.withLock { accepted } }
    var disconnected: Int { lock.withLock { gone } }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 { return }
            let keep: Bool = lock.withLock {
                accepted += 1
                if stopped || mode == .close { return false }
                clients.append(client)
                return true
            }
            guard keep else { close(client); continue }
            Thread.detachNewThread { [self] in
                var buffer = [UInt8](repeating: 0, count: 4096)
                while read(client, &buffer, buffer.count) > 0 {}
                lock.withLock { gone += 1 }
            }
        }
    }

    /// Closes the listener and every connection, which also unblocks a client still waiting.
    func stop() {
        let open: [Int32] = lock.withLock {
            guard !stopped else { return [] }
            stopped = true
            return clients
        }
        for fd in open { shutdown(fd, Int32(SHUT_RDWR)) }
        shutdown(listener, Int32(SHUT_RDWR))
        close(listener)
    }

    deinit { stop() }

    static func loopback(port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return addr
    }

    /// Whether something listens on `port` (a connect that succeeds, then closed).
    static func accepts(port: UInt16) -> Bool {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = loopback(port: port)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }
}
