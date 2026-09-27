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

    /// Same probe as `isLive(_:)`, keyed directly on a socket path rather than a session
    /// `UUID` — what `IntakeRunnerController` needs, since an intake runner's daemon has no
    /// `SessionDaemon`-assigned session id to look one up from. `isLive(_:)` is defined in
    /// terms of this one, not the other way around, so both keep the exact same connect()
    /// semantics.
    func isLive(socketPath: String) -> Bool

    /// The daemon's own pid, from its pidfile — but only if that pid is still alive. `nil`
    /// covers both "never ran" and "pidfile is stale", so a caller never has to `kill(pid, 0)`
    /// this a second time itself.
    func daemonPID(_ id: UUID) -> pid_t?

    /// Same lookup as `daemonPID(_:)`, keyed on a socket path — what `IntakeRunnerController`'s
    /// `reap` uses to require a genuinely readable pidfile before it ever tears a socket down.
    /// fd-abduco binds and listens on the socket in its launcher before it forks, so a runner's
    /// socket can answer `isLive` well before its pidfile exists; `terminate(socketPath:)` would
    /// otherwise still unlink that live socket in its unconditional cleanup (having found no pid
    /// to signal), orphaning the daemon underneath it. Checking this first is what stops that.
    func daemonPID(socketPath: String) -> pid_t?

    /// Tears the daemon down: `SIGTERM`, wait, `SIGKILL` if it did not listen, then remove its
    /// socket and pidfile regardless of how far that got. No-throw — this runs from teardown
    /// paths that cannot fail the operation they are cleaning up after; problems are logged.
    func terminate(_ id: UUID)

    /// Same teardown as `terminate(_:)`, keyed on a socket path — see `isLive(socketPath:)`
    /// for why a path-based twin exists at all. The pidfile is derived the same way
    /// `SessionDaemon.pidfilePath` derives it from a socket path: `<socketPath>.pid`.
    func terminate(socketPath: String)

    /// Recovers a live socket's peer pid straight from the kernel (`SOL_LOCAL`/`LOCAL_PEERPID`,
    /// Darwin) rather than reading it from a pidfile — `IntakeRunnerController.reap`'s recovery
    /// path for a socket that has been live past its orphan grace with no pidfile ever having
    /// appeared (the launcher bound the socket but the daemon crashed, or was killed, before it
    /// forked and wrote one). `nil` if the socket isn't connectable or the kernel can't answer.
    func peerPID(socketPath: String) -> pid_t?

    /// Same teardown ladder as `terminate(socketPath:)`, but for a pid already known — recovered
    /// via `peerPID(socketPath:)`, not read from a pidfile — for the one case that has no
    /// pidfile to read it from.
    func terminate(pid: pid_t, socketPath: String)

    /// Freezes the idle agent's process group (`kill(-agentPGID, SIGSTOP)`) — the agent, not the
    /// daemon: the daemon must keep running its `select()` loop so a later re-attach still has
    /// something to connect to. Silent no-op if the daemon pid is missing/dead or no agent group
    /// resolves — signaling nothing is always the safe failure mode here.
    func stop(_ id: UUID)

    /// Resumes the process group a prior `stop` froze (`kill(-agentPGID, SIGCONT)`). Same no-op
    /// rules as `stop`.
    func cont(_ id: UUID)
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

    /// How `stop`/`cont` find the agent's pgid to signal — injected so tests can substitute a
    /// fixed pgid instead of walking real `proc_listchildpids` state.
    private let agentGroupResolver: AgentGroupResolving

    /// The actual signal delivery `stop`/`cont` use — injected so tests can spy on calls instead
    /// of sending real `SIGSTOP`/`SIGCONT`. Defaults to the real `Darwin.kill`.
    private let signal: (pid_t, Int32) -> Int32

    init(
        daemon: SessionDaemon = SessionDaemon(),
        agentGroupResolver: AgentGroupResolving = PosixAgentGroupResolver(),
        signal: @escaping (pid_t, Int32) -> Int32 = { Darwin.kill($0, $1) }
    ) {
        self.daemon = daemon
        self.agentGroupResolver = agentGroupResolver
        self.signal = signal
    }

    func isLive(_ id: UUID) -> Bool {
        isLive(socketPath: daemon.socketPath(for: id))
    }

    func isLive(socketPath path: String) -> Bool {
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
            unlinkStale(socketPath: path, pidfilePath: path + ".pid")
            return false
        default:
            return false
        }
    }

    func daemonPID(_ id: UUID) -> pid_t? {
        daemonPID(socketPath: daemon.socketPath(for: id))
    }

    func daemonPID(socketPath path: String) -> pid_t? {
        guard let pid = readPID(pidfilePath: path + ".pid"), kill(pid, 0) == 0 else { return nil }
        return pid
    }

    func terminate(_ id: UUID) {
        terminateCore(socketPath: daemon.socketPath(for: id), pidfilePath: daemon.pidfilePath(for: id))
    }

    func terminate(socketPath path: String) {
        terminateCore(socketPath: path, pidfilePath: path + ".pid")
    }

    func peerPID(socketPath path: String) -> pid_t? {
        guard path.utf8.count <= Self.maxPathLength else { return nil }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: Self.maxPathLength + 1) {
                _ = strlcpy($0, path, Self.maxPathLength + 1)
            }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        // `SOL_LOCAL`/`LOCAL_PEERPID` (Darwin) reads the pid of whoever is on the other end of
        // an AF_UNIX socket straight from the kernel — the one way `reap`'s orphan recovery can
        // find a daemon's real pid when its launcher crashed before ever writing a pidfile.
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    func terminate(pid: pid_t, socketPath path: String) {
        terminateCore(pid: pid, socketPath: path, pidfilePath: path + ".pid")
    }

    private func terminateCore(socketPath: String, pidfilePath: String) {
        terminateCore(pid: readPID(pidfilePath: pidfilePath), socketPath: socketPath, pidfilePath: pidfilePath)
    }

    /// Shared by every `terminate` overload — `pid` is either read from a pidfile (the normal
    /// case) or already known (`terminate(pid:socketPath:)`'s recovered `peerPID`); either way
    /// the signal ladder and cleanup below are identical.
    private func terminateCore(pid maybePID: pid_t?, socketPath: String, pidfilePath: String) {
        // Unconditional, however far the signaling below gets: a daemon that was already dead
        // (or never existed) can still have left a socket or pidfile behind, and a daemon that
        // survives even `SIGKILL` still needs its bookkeeping cleared so a next attempt does
        // not immediately see it as live.
        defer { unlinkStale(socketPath: socketPath, pidfilePath: pidfilePath) }

        guard let pid = maybePID, kill(pid, 0) == 0 else { return }

        // A SIGSTOP'd agent can't act on the daemon's SIGTERM below — it can't process signals
        // or exit while stopped — so wake it first. Unconditional and safe: SIGCONT to an
        // already-running agent group is a harmless no-op, and `signalAgentGroup` is itself a
        // no-op if no agent group resolves.
        signalAgentGroup(daemonPID: pid, SIGCONT)

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

    func stop(_ id: UUID) {
        guard let pid = daemonPID(id) else { return }
        signalAgentGroup(daemonPID: pid, SIGSTOP)
    }

    func cont(_ id: UUID) {
        guard let pid = daemonPID(id) else { return }
        signalAgentGroup(daemonPID: pid, SIGCONT)
    }

    // MARK: - Helpers

    /// Resolves the agent pgid from the (validated, live) daemon pid and signals the NEGATIVE
    /// pgid, so the whole agent tree (claude + any node/MCP children) is hit — but never the
    /// daemon itself. `daemonPID > 0` mirrors `readPID`'s own guard as belt-and-suspenders, and
    /// `pgid > 0` is the same non-negotiable rail: `kill(-0, …)` broadcasts to this app's own
    /// process group and would freeze/resume Flight Deck itself, and `kill(-1, …)` broadcasts
    /// system-wide. Neither target is ever signaled. Takes the daemon pid directly (not a
    /// session id) so `terminate(socketPath:)` — which has no session id to resolve one from —
    /// can share this with `stop`/`cont`.
    private func signalAgentGroup(daemonPID: pid_t, _ sig: Int32) {
        guard daemonPID > 0 else { return }
        guard let pgid = agentGroupResolver.agentProcessGroup(daemonPID: daemonPID), pgid > 0 else {
            return
        }
        _ = signal(-pgid, sig)
    }

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

    private func readPID(pidfilePath: String) -> pid_t? {
        guard
            let contents = try? String(contentsOfFile: pidfilePath, encoding: .utf8)
        else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        // `> 0`, not just "parses as an Int32": `kill(pid, 0)` treats 0 and negative pids as
        // group/broadcast targets, not per-process liveness checks, and "succeeds" for them
        // regardless of what is actually running. A pidfile of "0" would otherwise make
        // `terminate` deliver `SIGTERM`/`SIGKILL` to pid 0 — Flight Deck's own process group,
        // taking down every ghostty surface and sibling daemon with it — and "-1" would
        // broadcast to every process this user can signal. fd-abduco only ever writes its own
        // positive `getpid()`, but a corrupted, truncated, or tampered pidfile must not be
        // catastrophic.
        guard let value = Int32(trimmed), value > 0 else { return nil }
        return pid_t(value)
    }

    private func unlinkStale(socketPath: String, pidfilePath pidPath: String) {
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
