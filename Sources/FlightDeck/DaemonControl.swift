// Sources/FlightDeck/DaemonControl.swift
import Darwin
import Foundation
import OSLog

/// Whether a session's `fd-abduco` daemon is up, and how to bring it down.
///
/// A protocol so the sessions that own a `DaemonControl` (Tasks 5-7) can be exercised without a
/// real fork — `SessionDaemon` itself stays a pure path calculator (see its doc comment) and
/// this is deliberately its only stateful neighbor, not folded into it.
protocol DaemonControlling {
    /// Is the daemon actually answering on its socket right now? This is the ground truth a
    /// pidfile alone cannot give: a daemon can crash and leave a stale socket file behind (or,
    /// less often, a stale pidfile naming a pid the OS has since recycled for something else).
    func isLive(_ id: UUID) -> Bool

    /// The daemon's own pid, from its pidfile — but only if that pid is still alive. `nil`
    /// covers both "never ran" and "pidfile is stale", so a caller never has to `kill(pid, 0)`
    /// this a second time itself.
    func daemonPID(_ id: UUID) -> pid_t?

    /// Tears the daemon down: `SIGTERM`, wait, `SIGKILL` if it did not listen, then remove its
    /// socket and pidfile regardless of how far that got. No-throw — this runs from teardown
    /// paths that cannot fail the operation they are cleaning up after; problems are logged.
    func terminate(_ id: UUID)
}

/// The real `DaemonControlling`, talking to `fd-abduco` over its `AF_UNIX` control socket and
/// its `<socket>.pid` sidecar (see Phase 1's `server_write_pidfile`/`server_remove_pidfile` in
/// `vendor/fd-abduco/server.c`).
struct PosixDaemonControl: DaemonControlling {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.flightdeck.FlightDeck",
        category: "DaemonControl"
    )

    /// `sockaddr_un.sun_path` is 104 bytes on Darwin and holds a NUL-terminated path, so 103
    /// bytes is every path a unix socket can have — same limit `AnswerTriggerSocket` checks,
    /// kept as its own constant here because the two types are otherwise unrelated.
    private static let maxPathLength = 103

    /// How long to wait after `SIGTERM` before escalating to `SIGKILL`, and how often to poll
    /// in between: 20 × 50 ms ≈ 1 s, matching the budget in the brief. Counted in polls rather
    /// than accumulated seconds for the reason `SurfaceProcessRegistry.pollBudget` is: an
    /// integer count cannot drift.
    private static let terminatePollInterval: useconds_t = 50_000
    private static let terminatePollBudget = 20

    let daemon: SessionDaemon

    init(daemon: SessionDaemon = SessionDaemon()) {
        self.daemon = daemon
    }

    func isLive(_ id: UUID) -> Bool {
        let path = daemon.socketPath(for: id)
        guard path.utf8.count <= Self.maxPathLength else {
            Self.logger.error(
                "socket path too long for sun_path (\(path.utf8.count, privacy: .public) bytes): \(path, privacy: .public)"
            )
            return false
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: Self.maxPathLength + 1) {
                _ = strlcpy($0, path, Self.maxPathLength + 1)
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return true }

        switch errno {
        case EISCONN:
            return true
        case EINPROGRESS:
            // A nonblocking connect to a local AF_UNIX socket resolves synchronously in
            // practice — there is no handshake to wait for — so this branch is only reachable
            // in principle. Handled anyway, per the spec: poll for writability on a short
            // deadline, then confirm there is no pending socket error behind it.
            return waitUntilWritable(fd)
        case ENOENT:
            // No socket file at all: nothing was ever running, or a previous `terminate`
            // already cleaned up. Nothing stale to remove either way.
            return false
        case ECONNREFUSED:
            // A socket file with nothing listening behind it: the daemon died without
            // unlinking (or something else raced the unlink). Leaving it behind would make
            // every future `isLive` pay this same failed connect, so clear it now.
            unlinkStale(id)
            return false
        default:
            return false
        }
    }

    func daemonPID(_ id: UUID) -> pid_t? {
        guard let pid = readPID(id), kill(pid, 0) == 0 else { return nil }
        return pid
    }

    func terminate(_ id: UUID) {
        // Unconditional, however far the signaling below gets: a daemon that was already dead
        // (or never existed) can still have left a socket or pidfile behind, and a daemon that
        // survives even `SIGKILL` still needs its bookkeeping cleared so a next attempt does
        // not immediately see it as live.
        defer { unlinkStale(id) }

        guard let pid = readPID(id), kill(pid, 0) == 0 else { return }

        if kill(pid, SIGTERM) != 0 {
            let reason = String(cString: strerror(errno))
            Self.logger.error(
                "SIGTERM failed for daemon pid \(pid, privacy: .public): \(reason, privacy: .public)"
            )
        }

        for _ in 0..<Self.terminatePollBudget {
            if kill(pid, 0) != 0 { return }
            usleep(Self.terminatePollInterval)
        }

        guard kill(pid, 0) == 0 else { return }
        if kill(pid, SIGKILL) != 0 {
            let reason = String(cString: strerror(errno))
            Self.logger.error(
                "SIGKILL failed for daemon pid \(pid, privacy: .public): \(reason, privacy: .public)"
            )
        }
    }

    // MARK: - Helpers

    private func waitUntilWritable(_ fd: Int32) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, 200) > 0, pfd.revents & Int16(POLLOUT) != 0 else { return false }

        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
            return false
        }
        return socketError == 0
    }

    private func readPID(_ id: UUID) -> pid_t? {
        guard
            let contents = try? String(
                contentsOfFile: daemon.pidfilePath(for: id), encoding: .utf8
            )
        else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int32(trimmed) else { return nil }
        return pid_t(value)
    }

    private func unlinkStale(_ id: UUID) {
        let socketPath = daemon.socketPath(for: id)
        let pidPath = daemon.pidfilePath(for: id)
        if unlink(socketPath) != 0 && errno != ENOENT {
            let reason = String(cString: strerror(errno))
            Self.logger.debug(
                "failed to unlink stale socket \(socketPath, privacy: .public): \(reason, privacy: .public)"
            )
        }
        if unlink(pidPath) != 0 && errno != ENOENT {
            let reason = String(cString: strerror(errno))
            Self.logger.debug(
                "failed to unlink stale pidfile \(pidPath, privacy: .public): \(reason, privacy: .public)"
            )
        }
    }
}
