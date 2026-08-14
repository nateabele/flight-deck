// Sources/FlightDeck/SessionReaper.swift
import Darwin
import Foundation
import OSLog

/// Signal delivery, behind a protocol so the ladder can be asserted without real processes.
protocol SignalSending: Sendable {
    func send(_ signal: Int32, toGroup pgid: pid_t) -> Bool
    func send(_ signal: Int32, toProcess pid: pid_t) -> Bool
    func ownProcessGroup() -> pid_t
}

struct PosixSignals: SignalSending {
    func send(_ signal: Int32, toGroup pgid: pid_t) -> Bool { killpg(pgid, signal) == 0 }
    func send(_ signal: Int32, toProcess pid: pid_t) -> Bool { kill(pid, signal) == 0 }
    func ownProcessGroup() -> pid_t { getpgid(0) }
}

protocol ReaperSleeping: Sendable {
    func sleep(seconds: Double) async
}

struct RealSleeper: ReaperSleeping {
    func sleep(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

enum ReapOutcome: Equatable {
    case clean
    case survivors([ProcessIdentity])
}

/// Terminates a session's process tree on a bounded deadline.
///
/// **Why this exists.** libghostty sends SIGHUP and only SIGHUP when a surface is freed
/// (`vendor/ghostty/src/termio/Exec.zig:1152-1185`), then spins waiting for the direct child
/// to be reaped — on the main actor, inside `ghostty_surface_free`. A process that ignores
/// SIGHUP therefore survives a tab close *and* wedges the UI. This type escalates properly
/// and does it off the main actor.
///
/// **Why an actor rather than `@MainActor`.** Nothing here may block the UI, and the ladder
/// deliberately sleeps between rungs.
///
/// **The actual bound.** Each ladder (see `ladder` below) is capped at 5 s. `reap` runs one
/// ladder for the shell's process group, then — if anything escaped that group — one more
/// *concurrent* batch covering every escapee, rather than one ladder per escapee run back to
/// back. So the overall bound is roughly two ladders' worth of time (~10 s worst case), not
/// `5 s × (1 + escapee count)`.
actor SessionReaper {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.flightdeck.FlightDeck",
        category: "SessionReaper"
    )

    /// Signal, and how long to wait for it to work before escalating. Total 5 s per target —
    /// see the type doc for why that is not the same as `reap`'s total budget.
    static let ladder: [(signal: Int32, budget: Double)] = [
        (SIGHUP, 2.0), (SIGTERM, 2.0), (SIGKILL, 1.0),
    ]
    /// How often to check whether the target died, inside a rung's budget. A shell that dies
    /// on the first SIGHUP — the overwhelming majority — finishes in one interval, not 2 s.
    static let pollInterval = 0.05

    private let inspector: ProcessInspecting
    private let signals: SignalSending
    private let sleeper: ReaperSleeping

    init(inspector: ProcessInspecting, signals: SignalSending, sleeper: ReaperSleeping) {
        self.inspector = inspector
        self.signals = signals
        self.sleeper = sleeper
    }

    /// Escalate against the shell's process group, then against anything that escaped it.
    /// `pgid` is `nil` when the caller could not establish a group to trust (see
    /// `SessionStore.sweepOrphans`); `escalate`/`deliver` already treat a missing group as
    /// "signal the pid directly" rather than guessing, so this stays an `Optional` end to
    /// end instead of being encoded as a sentinel value at the call site.
    func reap(shell: ProcessIdentity, pgid: pid_t?) async -> ReapOutcome {
        guard inspector.isAlive(shell) else { return .clean }

        // Capture the tree FIRST. Once the shell dies its children are reparented to launchd
        // and this walk returns nothing, so a snapshot taken after the kill is always empty
        // and would report success while escapees kept running.
        let tree = inspector.descendants(of: shell.pid)

        await escalate(on: shell, pgid: pgid)

        var survivors: [ProcessIdentity] = []
        if inspector.isAlive(shell) { survivors.append(shell) }

        // Anything still alive left the process group (setsid), so killpg never reached it.
        // These run concurrently, not one after another: they are independent of each other,
        // and the actor gives up its exclusivity at every `await sleeper.sleep` inside
        // `escalate`, so a `TaskGroup` of escapee ladders overlaps in wall time the same way
        // real concurrent processes would, instead of paying a fresh 5 s ladder per escapee.
        let escapees = tree.filter { inspector.isAlive($0) }
        if !escapees.isEmpty {
            await withTaskGroup(of: Void.self) { group in
                for escapee in escapees {
                    group.addTask { await self.escalate(on: escapee, pgid: nil) }
                }
            }
            survivors.append(contentsOf: escapees.filter { inspector.isAlive($0) })
        }

        if !survivors.isEmpty {
            Self.logger.error("reap incomplete, \(survivors.count) process(es) survived SIGKILL")
        }
        return survivors.isEmpty ? .clean : .survivors(survivors)
    }

    /// One target through the whole ladder, stopping the moment it dies.
    private func escalate(on target: ProcessIdentity, pgid: pid_t?) async {
        for rung in Self.ladder {
            guard inspector.isAlive(target) else { return }
            deliver(rung.signal, to: target, pgid: pgid)

            // Poll on an integer count rather than accumulating `Double` seconds, so the
            // budget cannot drift from float error. Checking `Task.isCancelled` and
            // *returning* — never escalating — after every poll is load-bearing:
            // `RealSleeper.sleep` swallows `CancellationError` via `try?` and returns
            // immediately once the task is cancelled, so without this check a cancelled reap
            // would spin through every remaining poll in microseconds and fire SIGHUP,
            // SIGTERM and SIGKILL back to back — turning a graceful shutdown into an instant
            // kill for a process that would have exited cleanly on the signal already sent.
            // Being cancelled is not a reason to escalate further, so this stops in place.
            let polls = Int((rung.budget / Self.pollInterval).rounded())
            for _ in 0..<polls {
                await sleeper.sleep(seconds: Self.pollInterval)
                if Task.isCancelled { return }
                if !inspector.isAlive(target) { return }
            }
        }
    }

    /// Group-first where we can, per-pid where we must.
    ///
    /// The self-group rail is load-bearing: `killpg` against our own group would kill Flight
    /// Deck itself. libghostty's child calls `setsid` immediately so this never fires in the
    /// app, but anything spawned without `setsid` — a `Foundation.Process` in the test bundle,
    /// for instance — shares our group, and upstream ghostty guards the same window from the
    /// other side (`Exec.zig:1193-1205`).
    private func deliver(_ signal: Int32, to target: ProcessIdentity, pgid: pid_t?) {
        if let pgid, pgid > 0, pgid != signals.ownProcessGroup() {
            _ = signals.send(signal, toGroup: pgid)
        } else {
            _ = signals.send(signal, toProcess: target.pid)
        }
    }
}

/// Where reap outcomes go.
///
/// A protocol rather than a direct call for the reason `Notifying` documents
/// (`SessionNotifier.swift:12-16`): the real reporter posts a user notification, and
/// `UNUserNotificationCenter.current()` traps when the calling binary is not a signed
/// bundle — exactly the case inside the unit-test bundle. Nothing a test can reach may
/// touch it.
protocol ReapReporting: AnyObject {
    func report(_ outcome: ReapOutcome, context: String)
    /// A launch-time sweep found and killed orphans from a previous run. Separate from
    /// `report` because this one is worth telling the user about on *success* — it is the
    /// only evidence they get that a previous run leaked, whereas a clean tab close is
    /// deliberately silent.
    func reportSweep(cleaned: Int)
}

/// The default: the log and nothing else. Task 7 adds the user-facing reporter.
final class LoggingReapReporter: ReapReporting {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.flightdeck.FlightDeck",
        category: "ReapReporter"
    )

    func report(_ outcome: ReapOutcome, context: String) {
        switch outcome {
        case .clean:
            Self.logger.debug("\(context): process tree terminated")
        case .survivors(let survivors):
            let pids = survivors.map { String($0.pid) }.joined(separator: ", ")
            Self.logger.error("\(context): survived SIGKILL: \(pids)")
        }
    }

    func reportSweep(cleaned: Int) {
        Self.logger.info("orphan sweep cleaned \(cleaned) process tree(s) from a previous run")
    }
}
