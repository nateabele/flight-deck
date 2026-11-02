import Foundation

/// What the code index daemon (`fdindex`, Packages/FlightIndex) reports about itself: the
/// fields of its `status` reply's `data` that Settings → Hosting shows. Every field is
/// optional, because the daemon is a separate binary that can be older or newer than the app,
/// and a missing field must cost that line, not the whole section.
struct IndexDaemonStatus: Decodable, Equatable {
    struct View: Decodable, Equatable {
        var worktree: String?
        var repo: String?
        var requests: UInt64?
        var idleSeconds: UInt64?
        var dirtyFiles: UInt64?

        enum CodingKeys: String, CodingKey {
            case worktree, repo, requests
            case idleSeconds = "idle_seconds"
            case dirtyFiles = "dirty_files"
        }
    }

    struct Build: Decodable, Equatable {
        var worktree: String?
        var phase: String?
        var done: UInt64?
        var total: UInt64?
    }

    struct Store: Decodable, Equatable {
        var repo: String?
        var bytes: UInt64?
    }

    /// The last request that failed on the daemon's side (`ERROR` or `VERSION_MISMATCH`); a
    /// caller's bad arguments are not kept (`Service::fail`).
    struct LastError: Decodable, Equatable {
        var state: String?
        var tool: String?
        var message: String?
        var secondsAgo: UInt64?

        enum CodingKeys: String, CodingKey {
            case state, tool, message
            case secondsAgo = "seconds_ago"
        }
    }

    var version: String?
    var pid: Int32?
    var uptimeSeconds: UInt64?
    var rssBytes: UInt64?
    /// 0 or absent: no target configured.
    var memoryTarget: UInt64?
    var requests: UInt64?
    var errors: UInt64?
    var views: [View]?
    var builds: [Build]?
    var stores: [Store]?
    var lastError: LastError?

    enum CodingKeys: String, CodingKey {
        case version, pid, requests, errors, views, builds, stores
        case uptimeSeconds = "uptime_seconds"
        case rssBytes = "rss_bytes"
        case memoryTarget = "memory_target"
        case lastError = "last_error"
    }

    /// The sum of every repository store file, as `fdindex status` prints it.
    var storeBytes: UInt64 { (stores ?? []).reduce(0) { $0 + ($1.bytes ?? 0) } }
}

enum IndexDaemonError: Error, Equatable {
    /// Nothing listens on the socket: never started, stopped, or a crashed daemon's leftover file.
    case notRunning
    case timedOut
    /// The reply was not a line of the daemon's protocol.
    case protocolError
    /// The daemon answered `ok: false`.
    case refused(state: String?, message: String)
    case system(String)
}

/// One request line over a Unix socket, one reply line back: the daemon's wire protocol
/// (`src/proto.rs`). A seam so the view model's tests answer from memory.
protocol IndexDaemonTransport: Sendable {
    func roundTrip(_ line: Data, socketPath: String, timeout: TimeInterval) throws -> Data
}

/// Reads the index daemon's `status` and asks it to `shutdown`. Blocking: every call does a
/// POSIX connect and read with a deadline, so callers run it off the main actor.
struct IndexDaemonClient: Sendable {
    let socketPath: String
    var transport: IndexDaemonTransport = UnixLineTransport()
    var timeout: TimeInterval = 3

    /// The socket the daemon listens on when nothing overrides it, as `Paths::new` computes it
    /// on macOS: `$FLIGHTDECK_INDEX_SOCKET`, else `<store>/fdindex.sock`, where the store is
    /// `$FLIGHTDECK_INDEX_DIR` or `~/Library/Application Support/FlightDeck/index`.
    static func defaultSocketPath(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: String = NSHomeDirectory()) -> String {
        if let socket = environment["FLIGHTDECK_INDEX_SOCKET"], !socket.isEmpty { return socket }
        let store = environment["FLIGHTDECK_INDEX_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (home as NSString).appendingPathComponent("Library/Application Support/FlightDeck/index")
        return (store as NSString).appendingPathComponent("fdindex.sock")
    }

    func status() throws -> IndexDaemonStatus {
        let reply = try call("status")
        guard let data = reply["data"] else { throw IndexDaemonError.protocolError }
        do {
            let bytes = try JSONSerialization.data(withJSONObject: data)
            return try JSONDecoder().decode(IndexDaemonStatus.self, from: bytes)
        } catch {
            throw IndexDaemonError.protocolError
        }
    }

    /// The daemon answers, removes its socket and exits cleanly. A clean exit is final for the
    /// launchd unit (it restarts only after a failure), so this stops the daemon until the next
    /// client starts it on demand.
    func shutdown() throws {
        _ = try call("shutdown")
    }

    /// No `v`: "whatever you speak", so a daemon newer than the app still answers `status`
    /// rather than `VERSION_MISMATCH`.
    private func call(_ tool: String) throws -> [String: Any] {
        let request = try JSONSerialization.data(withJSONObject: [
            "id": 1, "cwd": "", "seq": 0, "tool": tool, "args": [String: Any](),
        ] as [String: Any])
        let line = try transport.roundTrip(request, socketPath: socketPath, timeout: timeout)
        guard let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw IndexDaemonError.protocolError
        }
        guard reply["ok"] as? Bool == true else {
            throw IndexDaemonError.refused(state: reply["state"] as? String,
                                           message: reply["error"] as? String ?? "the index daemon refused the request")
        }
        return reply
    }
}

/// The real transport: a blocking `AF_UNIX` stream socket with send and receive deadlines.
struct UnixLineTransport: IndexDaemonTransport {
    /// A `status` reply lists every view and store; this caps what a broken peer can make us hold.
    static let maxReplyBytes = 8 << 20

    func roundTrip(_ line: Data, socketPath: String, timeout: TimeInterval) throws -> Data {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw IndexDaemonError.system("socket path is too long: \(socketPath)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IndexDaemonError.system(String(cString: strerror(errno))) }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            if errno == ENOENT || errno == ECONNREFUSED { throw IndexDaemonError.notRunning }
            if errno == EAGAIN || errno == ETIMEDOUT { throw IndexDaemonError.timedOut }
            throw IndexDaemonError.system(String(cString: strerror(errno)))
        }
        var out = [UInt8](line)
        out.append(UInt8(ascii: "\n"))
        var sent = 0
        while sent < out.count {
            let n = out[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw errno == EAGAIN ? IndexDaemonError.timedOut : IndexDaemonError.system(String(cString: strerror(errno)))
            }
            sent += n
        }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw errno == EAGAIN ? IndexDaemonError.timedOut : IndexDaemonError.system(String(cString: strerror(errno)))
            }
            if n == 0 { throw IndexDaemonError.protocolError }   // closed before a full line
            if let newline = chunk[..<n].firstIndex(of: UInt8(ascii: "\n")) {
                reply.append(contentsOf: chunk[..<newline])
                return reply
            }
            reply.append(contentsOf: chunk[..<n])
            if reply.count > Self.maxReplyBytes { throw IndexDaemonError.protocolError }
        }
    }
}
