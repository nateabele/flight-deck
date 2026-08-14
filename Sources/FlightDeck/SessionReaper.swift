// Sources/FlightDeck/SessionReaper.swift
import Darwin
import Foundation
import OSLog
import UserNotifications

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
    /// Deck itself. libghostty's child calls `setsid` immediately, so a session's own shell
    /// never actually shares our group in production; this check is defense in depth against
    /// a `pgid` argument that happens to equal ours anyway — a mis-derived value, a future
    /// call site, or (deliberately) a test proving the rail holds
    /// (`ReaperAcceptanceTests.testNeverSignalsTheTestRunnersOwnGroup`). It is *not* guarding
    /// against `Foundation.Process` sharing our group with a spawned child by default — on
    /// Darwin it does not; every `Process`-spawned child lands in a new group of its own (see
    /// that same test's doc comment for how that was confirmed). Upstream ghostty guards the
    /// same self-group window from the other side (`Exec.zig:1193-1205`).
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

/// Tells the user when a teardown did not finish. Silent on success by design: closing a tab
/// stays a one-click, no-dialog gesture, and the only things worth interrupting someone for
/// are a process that survived SIGKILL and an orphan sweep that found work to do.
///
/// Never construct this from a test — see the note on `ReapReporting`.
final class UserNotificationReapReporter: ReapReporting {
    private let fallback = LoggingReapReporter()

    /// A tab close and an in-flight quit reap the same session independently (see
    /// `SessionStore.reapSession`'s doc comment) and each calls `report` on its own — the
    /// actor serializes those calls but does not deduplicate them. If the identifier below
    /// included `context`, "tab close" and "app quit" would produce two distinct
    /// identifiers for the very same survivors and stack two notifications for one session.
    /// Scoping the identifier to the survivors' pids instead — the same precedent
    /// `SessionNotifier.notify` sets by keying on the session UUID
    /// (`SessionNotifier.swift:31-33`) — means a second report about the same processes
    /// replaces the first rather than adding to it. `context` still appears in the body, so
    /// the user still learns which teardown it was.
    ///
    /// This dedup is real but partial: the two racing reaps snapshot the process tree at
    /// different instants (see `SessionReaper.reap`'s "capture the tree FIRST" comment), so
    /// if a descendant dies between one report and the other, the survivor lists — and
    /// therefore the pid strings — differ, and the banners stack again. Closing that
    /// residual case for good needs a stable identity (a session id) threaded through
    /// `ReapReporting` itself, which is a protocol change out of scope here.
    func report(_ outcome: ReapOutcome, context: String) {
        fallback.report(outcome, context: context)
        guard case .survivors(let survivors) = outcome, !survivors.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = "Processes still running"
        let pids = survivors.map { String($0.pid) }.joined(separator: ", ")
        content.body = survivors.count == 1
            ? "One process (pid \(pids)) could not be terminated after \(context)."
            : "\(survivors.count) processes (pids \(pids)) could not be terminated after \(context)."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "reap.\(pids)", content: content, trigger: nil
            )
        )
    }

    func reportSweep(cleaned: Int) {
        fallback.reportSweep(cleaned: cleaned)

        let content = UNMutableNotificationContent()
        content.title = "Cleaned up after a previous session"
        content.body = cleaned == 1
            ? "One process left running by an earlier launch was terminated."
            : "\(cleaned) processes left running by an earlier launch were terminated."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "reap.sweep", content: content, trigger: nil)
        )
    }
}
