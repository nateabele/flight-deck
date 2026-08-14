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
actor SessionReaper {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.flightdeck.FlightDeck",
        category: "SessionReaper"
    )

    /// Signal, and how long to wait for it to work before escalating. Total 5 s.
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
    func reap(shell: ProcessIdentity, pgid: pid_t) async -> ReapOutcome {
        guard inspector.isAlive(shell) else { return .clean }

        // Capture the tree FIRST. Once the shell dies its children are reparented to launchd
        // and this walk returns nothing, so a snapshot taken after the kill is always empty
        // and would report success while escapees kept running.
        let tree = inspector.descendants(of: shell.pid)

        await escalate(on: shell, pgid: pgid)

        var survivors: [ProcessIdentity] = []
        if inspector.isAlive(shell) { survivors.append(shell) }

        // Anything still alive left the process group (setsid), so killpg never reached it.
        for escapee in tree where inspector.isAlive(escapee) {
            await escalate(on: escapee, pgid: nil)
            if inspector.isAlive(escapee) { survivors.append(escapee) }
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

            var waited = 0.0
            while waited < rung.budget {
                await sleeper.sleep(seconds: Self.pollInterval)
                waited += Self.pollInterval
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
