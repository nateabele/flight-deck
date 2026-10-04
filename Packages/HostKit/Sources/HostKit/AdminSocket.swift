import Foundation
#if canImport(Glibc)
import Glibc
#endif

public enum AdminSocketError: Error, Equatable {
    case notRunning
    case timedOut
    case protocolError
}

/// `sockaddr_un.sun_path` is 104 bytes on Darwin (108 on Linux) and holds a NUL-terminated path,
/// so 103 bytes is every path a unix socket can portably have — same limit
/// `DaemonControl.maxPathLength` uses. A longer path would be silently truncated by memcpy and
/// bind to the wrong place, so it throws instead.
private let maxPathLength = 103

/// Glibc imports SOCK_STREAM as an enum, Darwin as an Int32.
#if canImport(Glibc)
let sockStream = Int32(SOCK_STREAM.rawValue)
#else
let sockStream = SOCK_STREAM
#endif

/// Request and reply are each one `\n`-terminated line, capped so a rogue peer cannot make the
/// daemon buffer without bound.
private let maxLineBytes = 64 * 1024

private func posixError(_ code: Int32 = errno) -> Error {
    POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
}

private func makeAddress(_ path: String) throws -> sockaddr_un {
    guard path.utf8.count <= maxPathLength else { throw posixError(ENAMETOOLONG) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        path.withCString { _ = memcpy(buf.baseAddress!, $0, strlen($0) + 1) }
    }
    return addr
}

private func setTimeout(_ fd: Int32, _ option: Int32, _ seconds: TimeInterval) {
    // Fields assigned, not passed to the initializer: tv_usec is Int32 on Darwin and Int on Linux.
    var tv = timeval()
    tv.tv_sec = Int(seconds)
    tv.tv_usec = .init((seconds - seconds.rounded(.down)) * 1_000_000)
    setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
}

/// A write to a peer that already hung up raises SIGPIPE, which would kill hostd. Darwin turns
/// it off per socket; Linux per send.
private func disableSigpipe(_ fd: Int32) {
    #if !canImport(Glibc)
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    #endif
}

private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var off = 0
    while off < bytes.count {
        let n = bytes.withUnsafeBytes { buf -> Int in
            let p = buf.baseAddress! + off, len = bytes.count - off
            #if canImport(Glibc)
            return send(fd, p, len, Int32(MSG_NOSIGNAL))
            #else
            return write(fd, p, len)
            #endif
        }
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return false }
        off += n
    }
    return true
}

/// Reads up to `\n` (exclusive). nil on EOF before a newline, timeout, error or overflow;
/// `timedOut` distinguishes the receive timeout.
private func readLine(_ fd: Int32, timedOut: inout Bool) -> String? {
    var data = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while data.count <= maxLineBytes {
        let n = read(fd, &chunk, chunk.count)
        if n < 0 {
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { timedOut = true }
            return nil
        }
        if n == 0 { return nil }
        if let nl = chunk[0..<n].firstIndex(of: 0x0A) {
            data.append(contentsOf: chunk[0..<nl])
            return data.count <= maxLineBytes ? String(decoding: data, as: UTF8.self) : nil
        }
        data.append(contentsOf: chunk[0..<n])
    }
    return nil
}

private func setCloexec(_ fd: Int32) {
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
}

/// The user-only control channel to a running hostd. Both the Hosting tab and
/// `flightdeck-hostd pair` run as the same user, so a `0600` unix socket in a directory only
/// that user can write is the trust boundary.
///
/// Lifetime: the accept thread retains the server, so `deinit` cannot run while it is live;
/// call `stop()` to release it. `stop()` must not be called from inside the handler, which runs
/// on the accept thread and would wait on itself (checked by a precondition).
public final class AdminSocketServer: @unchecked Sendable {
    private let path: String
    private let handle: @Sendable (AdminRequest) -> AdminReply
    private let listenFd: Int32
    private let lock = NSLock()
    private var stopped = false
    private let finished = DispatchSemaphore(value: 0)
    private var acceptThread: Thread?
    /// The file this server bound, so stop() never unlinks a successor's socket.
    private var boundDev: dev_t = 0
    private var boundIno: ino_t = 0

    /// A silent client gets this long before it is dropped: connections are served one at a
    /// time, so without it one idle connect would wedge every later pair/status call.
    private static let clientReadTimeout: TimeInterval = 2

    public init(path: String, handle: @escaping @Sendable (AdminRequest) -> AdminReply) throws {
        self.path = path
        self.handle = handle
        var addr = try makeAddress(path)
        try Self.requirePrivateParent(of: path)
        try Self.clearStaleFile(at: path)

        let fd = socket(AF_UNIX, sockStream, 0)
        guard fd >= 0 else { throw posixError() }
        // A leaked listening fd in a spawned agent would keep the path answering after hostd
        // dies (this repo has been bitten by exactly that with control.sock).
        setCloexec(fd)
        // Bind creates the file with the umask's mode, so tighten it immediately. The window
        // is harmless only because requirePrivateParent proved nobody else can reach the
        // directory.
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { let e = posixError(); close(fd); throw e }
        guard chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            let e = posixError(); close(fd); unlink(path); throw e
        }
        var st = stat()
        if lstat(path, &st) == 0 { boundDev = st.st_dev; boundIno = st.st_ino }
        listenFd = fd
        let t = Thread { [self] in acceptLoop() }
        t.name = "hostkit.admin-socket"
        acceptThread = t
        t.start()
    }

    /// The trust boundary is the directory, not the socket's mode: anyone who can write the
    /// parent could swap in their own socket, or remove ours. Refuse a parent that another
    /// user owns or that group/other can write.
    private static func requirePrivateParent(of path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        var st = stat()
        guard stat(parent.isEmpty ? "." : parent, &st) == 0 else { throw posixError() }
        guard st.st_uid == geteuid(), st.st_mode & 0o022 == 0 else {
            throw POSIXError(.EPERM, userInfo: [NSLocalizedDescriptionKey:
                "admin socket directory \(parent) must be owned by the current user and not group- or other-writable"])
        }
    }

    /// A crashed hostd leaves its socket file behind and bind(2) refuses an existing path.
    /// Remove only a socket or plain leftover, judged by `lstat` so a symlink is never followed:
    /// otherwise a planted link would make hostd unlink whatever it points at. A socket that
    /// still accepts belongs to a live hostd and is never taken over (EADDRINUSE).
    private static func clearStaleFile(at path: String) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            if errno == ENOENT { return }
            throw posixError()
        }
        let type = st.st_mode & S_IFMT
        guard type == S_IFSOCK || type == S_IFREG else { throw posixError(EEXIST) }
        if type == S_IFSOCK { try requireDead(socketAt: path) }
        guard unlink(path) == 0 || errno == ENOENT else { throw posixError() }
    }

    /// Probe-connects. ECONNREFUSED twice, 100 ms apart, means the owner is gone (the retry
    /// covers an owner between bind and listen); a successful connect means it is alive.
    private static func requireDead(socketAt path: String) throws {
        let addr = try makeAddress(path)
        for attempt in 0..<2 {
            let fd = socket(AF_UNIX, sockStream, 0)
            guard fd >= 0 else { throw posixError() }
            defer { close(fd) }
            var a = addr
            let rc = withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if rc == 0 { throw posixError(EADDRINUSE) }
            if errno == ENOENT { return }
            guard errno == ECONNREFUSED else { throw posixError() }
            if attempt == 0 { usleep(100_000) }
        }
        guard unlink(path) == 0 || errno == ENOENT else { throw posixError() }
    }

    /// Polls with a short timeout rather than blocking in accept(2), because closing or shutting
    /// down a listening fd does not reliably wake a blocked accept on Darwin.
    private func acceptLoop() {
        defer { finished.signal() }
        while !isStopped {
            var p = pollfd(fd: listenFd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 200) > 0 else { continue }
            let client = accept(listenFd, nil, nil)
            guard client >= 0 else { continue }
            setCloexec(client)
            serve(client)
            close(client)
        }
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func serve(_ fd: Int32) {
        disableSigpipe(fd)
        setTimeout(fd, SO_RCVTIMEO, Self.clientReadTimeout)
        setTimeout(fd, SO_SNDTIMEO, Self.clientReadTimeout)
        var timedOut = false
        guard let line = readLine(fd, timedOut: &timedOut) else { return }
        let reply: AdminReply
        if let req = try? HostWire.decode(AdminRequest.self, from: line) {
            reply = handle(req)
        } else {
            reply = .failed("bad request")
        }
        guard let text = try? HostWire.encode(reply) else { return }
        _ = writeAll(fd, Array((text + "\n").utf8))
    }

    public func stop() {
        precondition(Thread.current !== acceptThread, "AdminSocketServer.stop() called from its own handler")
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        lock.unlock()
        finished.wait()
        close(listenFd)
        var st = stat()
        if lstat(path, &st) == 0, st.st_dev == boundDev, st.st_ino == boundIno { unlink(path) }
    }
}

public enum AdminSocketClient {
    public static func send(_ r: AdminRequest, path: String, timeout: TimeInterval = 5) throws -> AdminReply {
        var addr = try makeAddress(path)
        let fd = socket(AF_UNIX, sockStream, 0)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        disableSigpipe(fd)
        setTimeout(fd, SO_RCVTIMEO, timeout)
        setTimeout(fd, SO_SNDTIMEO, timeout)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            // ENOENT: never started or cleanly stopped; ECONNREFUSED: a crashed hostd's leftover file.
            if errno == ENOENT || errno == ECONNREFUSED { throw AdminSocketError.notRunning }
            // A full backlog on a unix socket makes a blocking connect fail with EAGAIN.
            if errno == EAGAIN { throw AdminSocketError.timedOut }
            throw posixError()
        }
        guard writeAll(fd, Array((try HostWire.encode(r) + "\n").utf8)) else {
            throw errno == EAGAIN ? AdminSocketError.timedOut : posixError()
        }
        var timedOut = false
        guard let line = readLine(fd, timedOut: &timedOut) else {
            throw timedOut ? AdminSocketError.timedOut : AdminSocketError.protocolError
        }
        guard let reply = try? HostWire.decode(AdminReply.self, from: line) else {
            throw AdminSocketError.protocolError
        }
        return reply
    }
}
