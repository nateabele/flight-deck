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
        var description: String {
            switch self {
            case .launcherFailed(let status):
                return "fd-abduco launcher exited \(status)"
            }
        }
    }

    func spawn(executable: String, arguments: [String], environment: [String: String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        try process.run()
        process.waitUntilExit()
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
    /// `SessionDaemon.resolvedBinaryPath()` couldn't produce a runnable `fd-abduco` symlink.
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

    /// How long a `Tape.heartbeat` may age before a live socket with a stale `status` is no
    /// longer trusted as "still running" — see `isRunning`'s doc comment.
    private static let heartbeatFreshness: TimeInterval = 10

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
        now: @escaping () -> Date = Date.init
    ) {
        self.daemon = daemon
        self.control = control
        self.spawner = spawner
        self.flightdeckPath = flightdeckPath
        self.intakesRoot = intakesRoot
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
    /// finished. So a live socket backing a tape whose `status` says the run is over (anything
    /// but `.running`) does not mean the run is still going; it means there is a finished
    /// daemon to `reap`.
    ///
    /// **Why status alone isn't enough either.** The runner updates `tape.status` and
    /// `tape.heartbeat` from inside its own process, on its own schedule — a crash between
    /// "wrote `.running`" and "the next heartbeat" would otherwise read as running forever. A
    /// heartbeat younger than `heartbeatFreshness` is trusted as a second, independent signal
    /// the same way `status == .running` is.
    func isRunning(_ id: UUID) -> Bool {
        guard control.isLive(socketPath: socketPath(for: id)) else { return false }
        let tape = TapeStore(intakeDirectory: IntakeStore(root: intakesRoot).directory(for: id)).loadTape()
        if tape.status == .running { return true }
        guard let heartbeat = tape.heartbeat else { return false }
        return now().timeIntervalSince(heartbeat) < Self.heartbeatFreshness
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
        do {
            try spawner.spawn(executable: fdAbducoPath, arguments: arguments, environment: environment())
            return .success(())
        } catch {
            return .failure(.spawnFailed(String(describing: error)))
        }
    }

    /// Collects a finished runner's daemon: no-op while `isRunning` still says yes (there is
    /// nothing finished to collect), otherwise tears down whatever `fd-abduco` is still holding
    /// the socket open — see `isRunning`'s doc comment for why a live socket can outlive its
    /// runner. Also a no-op when the socket was never live at all, so calling this
    /// speculatively (as `ensureRunning` does before every spawn) never errors.
    func reap(_ id: UUID) {
        let socket = socketPath(for: id)
        guard control.isLive(socketPath: socket), !isRunning(id) else { return }
        control.terminate(socketPath: socket)
    }
}
