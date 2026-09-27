// Sources/FlightDeck/Intake/IntakeRunnerController.swift
import Foundation
import IntakeKit

/// Spawns a detached `flightdeck intake run <id> --root <dir>` under `fd-abduco` — the same
/// detach mechanism `SessionDaemon`/`DaemonControlling` give a terminal session, applied to a
/// headless round engine so it keeps shaping an intake across an app quit or crash. Deliberately
/// its own small seam rather than reusing `SessionDaemon` directly: a session id names a
/// terminal tab, an intake id names a shaping run, and the two must never collide in the same
/// socket directory (see `socketPath(for:)`'s `intake-` prefix).
protocol RunnerSpawning {
    func spawn(executable: String, arguments: [String], environment: [String: String]) throws
}

/// The real `RunnerSpawning`: launches `fd-abduco -n <sock> <executable> <arguments…>` and
/// waits for the LAUNCHER to exit, not the daemon it detaches — `fd-abduco -n` forks, the
/// child execs the daemon proper and re-parents to launchd, and the original process (this
/// one) returns almost immediately. Waiting for it is what makes `spawn` synchronous without
/// blocking for however long the runner itself takes to finish shaping the intake.
struct FdAbducoRunnerSpawner: RunnerSpawning {
    enum SpawnError: Error, CustomStringConvertible {
        case launcherFailed(Int32)
        /// The launcher never exited within `launcherTimeout` — surfaced as its own case
        /// (not folded into `launcherFailed`) so its `description` reads as a hang, not a
        /// clean nonzero exit.
        case timedOut
        var description: String {
            switch self {
            case .launcherFailed(let status):
                return "fd-abduco launcher exited \(status)"
            case .timedOut:
                return "launcher did not exit"
            }
        }
    }

    /// How long to wait for the `-n` launcher to exit before giving up on it — Review Focus 2:
    /// bounds a wedged launcher to a failed spawn instead of hanging whatever called this.
    private static let launcherTimeout: TimeInterval = 5

    func spawn(executable: String, arguments: [String], environment: [String: String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        // NEVER `waitUntilExit()`: it spins the CALLING thread's run loop waiting for
        // Foundation's exit notification, and `IntakeRunnerController` calls this on the main
        // actor — the exact setup that just wedged `SystemCommandRunner` under concurrent load
        // (fixed in f703040) by missing that notification and blocking forever with the child
        // long gone. Worse here: a spin on the main run loop lets SwiftUI service a re-entrant
        // `ensureRunning` (a timer tick, a user action) before this one has returned, which is
        // its own path to the double-spawn Review Focus 1 found. `terminationHandler` is
        // installed before `run()` so an instant exit can't slip past it, and waiting on a
        // semaphore (not the run loop) blocks only this call, not the app.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try process.run()
        guard exited.wait(timeout: .now() + Self.launcherTimeout) == .success else {
            throw SpawnError.timedOut
        }
        guard process.terminationStatus == 0 else {
            throw SpawnError.launcherFailed(process.terminationStatus)
        }
    }
}

/// Why `ensureRunning` refused to start a runner.
enum RunnerStartError: Error, Equatable {
    /// `flightdeckPath()` returned `nil` — this build has no bundled `flightdeck` CLI to hand
    /// `fd-abduco` (a plain `swift test` host, or a bundle built without the CLI phase).
    case noBundledCLI
    /// `SessionDaemon.resolvedBinaryPath()` threw — either this build has no bundled
    /// `fd-abduco` binary to link to at all (`SessionDaemon.PathError.binaryNotBundled`), or
    /// creating/verifying the symlink to it failed for some other reason (e.g. permissions).
    /// Either way there is no `fd-abduco` path this call can hand to `RunnerSpawning`.
    case noFdAbduco
    /// The launcher process itself failed to start or exited non-zero; `String` is
    /// `RunnerSpawning`'s error, described for a log line, not parsed by any caller.
    case spawnFailed(String)
}

/// Adopts, spawns and reaps the one detached runner process an intake's round engine needs —
/// the app-side half of Tasks 7-9's `flightdeck intake run`. Never wired into
/// `IntakeService`/`SessionStore` here (Task 11's job); this only owns the process lifecycle.
@MainActor
final class IntakeRunnerController {
    private let daemon: SessionDaemon
    private let control: DaemonControlling
    private let spawner: RunnerSpawning
    private let flightdeckPath: () -> String?
    private let intakesRoot: URL
    private let environment: () -> [String: String]
    /// Injected so `isRunning`'s heartbeat-freshness check is deterministic under test —
    /// see the doc comment there for why a live socket alone isn't enough.
    private let now: () -> Date
    /// How long a just-spawned runner is trusted as running before its own tape has to prove
    /// it — see `spawnedAt`'s doc comment. Injectable so tests don't have to sleep for it.
    private let spawnGrace: TimeInterval

    /// How long a heartbeat may stay stale, WITH the daemon pid still provably alive, before
    /// `isRunning` gives up on it — fix round 2, Review Focus 1: right after the Mac wakes from
    /// sleep, every runner's heartbeat is exactly as old as the sleep, so a bare age check would
    /// reap and respawn a perfectly healthy runner mid-round the instant `ensureRunning` next
    /// ran. Deliberately 2× `heartbeatFreshness`, not derived from it, per the review, so the
    /// two can be tuned independently. Injectable so tests don't have to sleep for it.
    private let staleGrace: TimeInterval

    /// How long a `Tape.heartbeat` may age before a live socket is no longer trusted as "still
    /// running" — see `isRunning`'s doc comment. Checked regardless of `tape.status` (Review
    /// Focus 3, fix round 1): the runner writes both from inside its own process on its own
    /// schedule, and a crash mid-round can leave `status == .running` behind forever with no
    /// heartbeat to say otherwise.
    private static let heartbeatFreshness: TimeInterval = 10

    /// How long a socket may stay live with no readable pidfile ever appearing before `reap`
    /// tries to recover its daemon's real pid straight from the kernel — fix round 2, Review
    /// Focus 4: without a time bound here, a launcher that bound the socket and then crashed
    /// (or was killed) before its daemon forked and wrote `<socket>.pid` left that socket
    /// "live, no pidfile" forever, and the fix round 1 rule (never terminate without a readable
    /// pidfile) made that permanent — nothing could ever reap it. Injectable so tests don't
    /// have to sleep for it.
    private let orphanGrace: TimeInterval

    /// This process's own record of when it last told `fd-abduco` to spawn a runner for a
    /// given intake — never persisted, because it only needs to cover one in-process race.
    ///
    /// **Review Focus 1 (critical, fix round 1): the double-spawn.** `fd-abduco` binds and
    /// listens on the socket in its `-n` launcher *before* it forks, so `control.isLive(
    /// socketPath:)` can go true well before the runner underneath has written anything —
    /// including its first heartbeat, or even flipped `tape.status` off `.idle`. Without this,
    /// a SECOND `ensureRunning` landing in that window would see a live socket backed by a
    /// tape that looks exactly like "nothing is running", call `reap` on a runner that is very
    /// much alive, and then spawn a second one racing the same tape. Treating anything spawned
    /// within `spawnGrace` as running — and `reap` as a no-op for it — closes that window
    /// without needing the runner to have caught up yet.
    private var spawnedAt: [UUID: Date] = [:]

    /// The first moment `isRunning` saw a given intake's heartbeat go stale while its daemon
    /// pid was still provably alive — cleared the moment either stops being true (a fresh
    /// heartbeat arrives, or the pid dies), so only a heartbeat that is STILL stale `staleGrace`
    /// after the FIRST sighting reads as genuinely crashed, not merely asleep. See
    /// `staleGrace`'s doc comment.
    private var firstSeenStale: [UUID: Date] = [:]

    /// The first moment `reap` saw a given intake's socket live with no readable pidfile —
    /// cleared the moment that stops being true (a pidfile appears, or the socket itself goes
    /// away), so a single crossing of `orphanGrace` is what triggers the kernel-pid recovery,
    /// not every call after that. See `orphanGrace`'s doc comment.
    private var firstSeenOrphaned: [UUID: Date] = [:]

    init(
        daemon: SessionDaemon,
        control: DaemonControlling,
        spawner: RunnerSpawning,
        flightdeckPath: @escaping () -> String? = {
            Bundle.main.url(forAuxiliaryExecutable: "flightdeck")?.path
        },
        intakesRoot: URL,
        // `nil` (the default) computes the recipe the brief names — repaired PATH, this tab's
        // Claude identity stripped, `FLIGHT_DECK_STATE_DIR` pointed at the intakes root's
        // parent — at CALL time, not at init time: default *parameter* expressions in Swift
        // cannot reference a sibling parameter (`intakesRoot`), so the computation has to live
        // in the initializer body instead of the signature.
        environment: (() -> [String: String])? = nil,
        spawnGrace: TimeInterval = 15,
        staleGrace: TimeInterval = 2 * heartbeatFreshness,
        orphanGrace: TimeInterval = 30,
        now: @escaping () -> Date = Date.init
    ) {
        self.daemon = daemon
        self.control = control
        self.spawner = spawner
        self.flightdeckPath = flightdeckPath
        self.intakesRoot = intakesRoot
        self.spawnGrace = spawnGrace
        self.staleGrace = staleGrace
        self.orphanGrace = orphanGrace
        self.now = now
        if let environment {
            self.environment = environment
        } else {
            let stateDir = intakesRoot.deletingLastPathComponent().path
            self.environment = {
                var env = LoginShellPath.repairing(ProcessInfo.processInfo.environment)
                // The runner is not this tab's Claude session and must never be mistaken for
                // a nested one — same hazard `AGENTS.md` warns every agent about.
                env.removeValue(forKey: "CLAUDE_CODE_CHILD_SESSION")
                env.removeValue(forKey: "CLAUDECODE")
                env["FLIGHT_DECK_STATE_DIR"] = stateDir
                return env
            }
        }
    }

    /// `<daemon.directory>/intake-<uuid>.sock` — sharing `SessionDaemon`'s socket directory
    /// (fd-abduco's own control-socket bookkeeping is directory-wide) but never its bare
    /// `<uuid>.sock` naming: `SessionDaemon.liveSessionIDs()` walks that directory to find
    /// daemons whose *session* did not come back at launch, and a runner socket that parsed as
    /// a bare UUID would make that reconcile try to adopt or reap a tab that never existed.
    /// The `intake-` prefix means `UUID(uuidString:)` on the stem always fails, which is what
    /// keeps it invisible to that walk.
    func socketPath(for id: UUID) -> String {
        daemon.directory.appendingPathComponent("intake-\(id.uuidString.lowercased()).sock").path
    }

    /// Whether an intake already has a live runner behind its socket — the check `ensureRunning`
    /// uses to decide "adopt" vs. "spawn", and `reap` uses (inverted) to decide "leave alone" vs.
    /// "tear down".
    ///
    /// **Why liveness alone isn't enough.** `fd-abduco`'s socket answers `isLive` for as long as
    /// the daemon process exists, which outlives the runner it was hosting — the daemon keeps
    /// running its `select()` loop waiting for a re-attach even after the runner underneath has
    /// finished. So a live socket alone does not mean the run is still going; it means there is
    /// a live daemon that is either running a runner or waiting to be `reap`ed.
    ///
    /// **Why `tape.status` is never consulted here (fix round 1, Review Focus 3).** The runner
    /// writes `status` and `heartbeat` from inside its own process, on its own schedule — a
    /// crash between "wrote `.running`" and the next heartbeat would read as running forever if
    /// `status == .running` were trusted on its own, adopting a dead runner instead of reaping
    /// and respawning it. A heartbeat younger than `heartbeatFreshness` is the only signal this
    /// trusts for "genuinely still working"; **interface requirement for Task 8's runner: it
    /// must write a fresh `heartbeat` every poll interval, including mid-round on a long round,
    /// not just at round boundaries**, and — fix round 2, Review Focus 3 — **the runner's very
    /// FIRST tape write at startup must be a heartbeat**, before anything else it does, so a
    /// runner that dies before finishing its first poll still leaves one behind for this check
    /// to find. Contract for the same runner, the other direction: its FINAL write before
    /// exiting for any reason (`.stopped`, `.failed`, `.reachedReview`, …) must be its terminal
    /// `status` — so once the socket goes dark, whatever `tape.status` says at that moment is
    /// trustworthy again.
    ///
    /// **Why a fresh spawn is trusted without a heartbeat at all.** See `spawnedAt`'s doc
    /// comment: fd-abduco can make the socket live before the runner has written anything.
    ///
    /// **Why a stale heartbeat alone doesn't reap it (fix round 2, Review Focus 1).** After the
    /// Mac sleeps, a perfectly healthy runner's heartbeat is exactly as old as the sleep the
    /// instant it wakes — reaping on that reading alone would kill a runner mid-round for doing
    /// nothing wrong. If the daemon pid is still provably alive, this gives it `staleGrace`
    /// from the FIRST stale sighting before treating it as crashed; a fresh heartbeat in the
    /// meantime clears that grace entirely. A dead pid (or no pid at all) skips the grace and
    /// reads as not running immediately — there is nothing left to wait on.
    func isRunning(_ id: UUID) -> Bool {
        let socket = socketPath(for: id)
        guard control.isLive(socketPath: socket) else {
            firstSeenStale.removeValue(forKey: id)
            return false
        }
        if let spawnedAt = spawnedAt[id], now().timeIntervalSince(spawnedAt) < spawnGrace {
            return true
        }
        let tape = TapeStore(intakeDirectory: IntakeStore(root: intakesRoot).directory(for: id)).loadTape()
        // No heartbeat at all — as opposed to a STALE one — means this runner never got past
        // its first poll (Task 8's contract makes a heartbeat the very first tape write) or is
        // a genuinely finished one whose tape predates heartbeats entirely; either way there is
        // nothing to give a sleep-survival grace to, so this reads as not running immediately.
        guard let heartbeat = tape.heartbeat else {
            firstSeenStale.removeValue(forKey: id)
            return false
        }
        if now().timeIntervalSince(heartbeat) < Self.heartbeatFreshness {
            firstSeenStale.removeValue(forKey: id)
            return true
        }
        guard control.daemonPID(socketPath: socket) != nil else {
            firstSeenStale.removeValue(forKey: id)
            return false
        }
        let firstStale = firstSeenStale[id] ?? now()
        firstSeenStale[id] = firstStale
        return now().timeIntervalSince(firstStale) < staleGrace
    }

    /// Starts a runner for `id` unless one is already live (Review Focus 5: never stack two
    /// runners racing the same tape). Adopts a genuinely running one in place rather than
    /// respawning it, and clears a finished one's leftover daemon first so the fresh spawn can
    /// bind the same socket path.
    func ensureRunning(_ id: UUID) -> Result<Void, RunnerStartError> {
        if isRunning(id) { return .success(()) }
        reap(id)

        guard let flightdeckPath = flightdeckPath() else { return .failure(.noBundledCLI) }

        let fdAbducoPath: String
        do {
            fdAbducoPath = try daemon.resolvedBinaryPath()
        } catch {
            return .failure(.noFdAbduco)
        }

        let arguments = [
            "-n", socketPath(for: id), flightdeckPath, "intake", "run", id.uuidString.lowercased(),
            "--root", intakesRoot.path,
        ]
        // Set BEFORE calling spawn (fix round 2, Review Focus 2): `fd-abduco` binds the socket
        // inside `spawner.spawn` itself, before that call even returns, so recording the grace
        // only on success left the exact window Review Focus 1 closed open again — a re-entrant
        // `ensureRunning` landing between a real spawn and this line returning would see a live
        // socket with no grace recorded yet. Removed only once the launcher is KNOWN to have
        // never started; kept on `.timedOut`, since the launcher may still be alive and about to
        // bind the socket even though this call gave up waiting on it.
        spawnedAt[id] = now()
        do {
            try spawner.spawn(executable: fdAbducoPath, arguments: arguments, environment: environment())
            return .success(())
        } catch let error as FdAbducoRunnerSpawner.SpawnError {
            if case .launcherFailed = error {
                spawnedAt.removeValue(forKey: id)
            }
            return .failure(.spawnFailed(String(describing: error)))
        } catch {
            spawnedAt.removeValue(forKey: id)
            return .failure(.spawnFailed(String(describing: error)))
        }
    }

    /// Collects a finished runner's daemon: no-op while `isRunning` still says yes (there is
    /// nothing finished to collect — this also covers the spawn-grace window, since `isRunning`
    /// does), otherwise tears down whatever `fd-abduco` is still holding the socket open — see
    /// `isRunning`'s doc comment for why a live socket can outlive its runner. Also a no-op when
    /// the socket was never live at all, so calling this speculatively (as `ensureRunning` does
    /// before every spawn) never errors.
    ///
    /// **Requires a readable pidfile before it ever tears anything down (fix round 1, Review
    /// Focus 1).** `fd-abduco` binds and listens on the socket in its launcher before the
    /// daemon proper has forked and written `<socket>.pid` — so a socket can be live with no
    /// pidfile yet. `terminate(socketPath:)`'s cleanup unconditionally unlinks the socket even
    /// when it finds no pid to signal; calling it in that window would silently delete a live
    /// daemon's socket out from under it (orphaning it) rather than kill it, and that orphan's
    /// own `atexit` unlink would later delete the NEXT spawn's socket instead. Checking
    /// `daemonPID(socketPath:)` first — which itself requires a readable pidfile naming a pid
    /// that is actually alive — is what stops that.
    ///
    /// **Past `orphanGrace` with STILL no pidfile (fix round 2, Review Focus 4).** The rule
    /// above otherwise leaves a socket like that stuck forever — nothing ever gets a pidfile
    /// to read, so nothing ever passes the guard. Once `orphanGrace` has elapsed since `reap`
    /// FIRST saw this socket in that state, it falls back to recovering the daemon's real pid
    /// straight from the kernel — `getsockopt(SOL_LOCAL, LOCAL_PEERPID)` on a connected AF_UNIX
    /// socket answers with the pid on the other end, pidfile or not (Darwin only; proven live
    /// against a real peer process before writing this) — and terminates by that pid directly.
    func reap(_ id: UUID) {
        let socket = socketPath(for: id)
        guard control.isLive(socketPath: socket) else {
            firstSeenOrphaned.removeValue(forKey: id)
            return
        }
        guard !isRunning(id) else { return }

        if control.daemonPID(socketPath: socket) != nil {
            firstSeenOrphaned.removeValue(forKey: id)
            control.terminate(socketPath: socket)
            return
        }

        let firstOrphaned = firstSeenOrphaned[id] ?? now()
        firstSeenOrphaned[id] = firstOrphaned
        guard now().timeIntervalSince(firstOrphaned) >= orphanGrace else { return }

        // Past grace with no pidfile ever appearing: recover the real pid from the kernel.
        // `nil` here means even that failed (the process died between `isLive` and this
        // `connect()`) — nothing more to signal, so leave it for the next `reap` to retry.
        if let peerPID = control.peerPID(socketPath: socket) {
            control.terminate(pid: peerPID, socketPath: socket)
        }
        firstSeenOrphaned.removeValue(forKey: id)
    }
}
