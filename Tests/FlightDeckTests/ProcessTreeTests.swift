// Tests/FlightDeckTests/ProcessTreeTests.swift
import XCTest
@testable import FlightDeck

final class ProcessTreeTests: XCTestCase {
    /// Spawns `/bin/sh -c "sleep 30 & wait"` as a child of this test process and returns it.
    /// The `& wait` forces `sh` to fork a real `sleep` child instead of exec-optimizing itself
    /// away, so the process tree is genuinely two deep.
    ///
    /// Cleanup is registered here rather than left to the caller, and it sweeps the *whole*
    /// tree. Terminating only the `sh` orphans its backgrounded `sleep 30`, which then runs for
    /// its full half minute after the test that spawned it has passed — a test suite for a
    /// process reaper leaking processes. The descendants are captured now, while `sh` is still
    /// alive, for the reason `ReaperAcceptanceTests` documents at length: once the parent dies
    /// its children are reparented, and a walk keyed on the dead parent's pid finds nothing.
    private func spawnSleeper() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 30 & wait"]
        try p.run()

        // Long enough for `sh` to have forked `sleep`; the descendant assertions below rely on
        // the same pause.
        Thread.sleep(forTimeInterval: 0.3)
        let tree = ProcessTree()
        let doomed = tree.descendants(of: p.processIdentifier)
        addTeardownBlock {
            for descendant in doomed where tree.isAlive(descendant) {
                kill(descendant.pid, SIGKILL)
            }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        return p
    }

    func testChildrenIncludesASpawnedChild() throws {
        let child = try spawnSleeper()

        let kids = ProcessTree().children(of: getpid())

        XCTAssertTrue(kids.contains(child.processIdentifier))
    }

    func testDescendantsIncludesAGrandchild() throws {
        // `sh` stays alive while its own `sleep` child runs, so the tree is two deep.
        // `spawnSleeper` has already waited for that fork.
        let child = try spawnSleeper()

        let tree = ProcessTree().descendants(of: getpid()).map(\.pid)

        XCTAssertTrue(tree.contains(child.processIdentifier), "direct child missing")
        XCTAssertGreaterThan(tree.count, 1, "expected the grandchild `sleep` as well")
    }

    func testStartTimeIsStableAcrossReads() throws {
        let child = try spawnSleeper()
        let tree = ProcessTree()

        let first = tree.startTime(of: child.processIdentifier)
        Thread.sleep(forTimeInterval: 0.2)
        let second = tree.startTime(of: child.processIdentifier)

        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
    }

    /// The regression that made this whole feature inert in the real app.
    ///
    /// libghostty's direct child on macOS is setuid-root `/usr/bin/login`, and
    /// `proc_pidinfo(PROC_PIDTBSDINFO)` returns `EPERM` for any process the caller does not own.
    /// Every session's shell therefore read back as "no start time", so no identity could be
    /// built, nothing was recorded, and `isAlive` called every live shell dead. `launchd` is the
    /// cheapest permanently-available stand-in for that shape: pid 1, root, never ours. This
    /// test fails against the libproc implementation and passes against `KERN_PROC_PID`.
    func testStartTimeIsReadableForAProcessWeDoNotOwn() throws {
        let launchd = try XCTUnwrap(
            ProcessTree().startTime(of: 1), "cannot read the start time of a root-owned process"
        )

        XCTAssertGreaterThan(launchd, 0)
        XCTAssertTrue(ProcessTree().isAlive(ProcessIdentity(pid: 1, procStart: launchd)))
    }

    func testStartTimeOfDeadProcessIsNil() throws {
        let child = try spawnSleeper()
        let pid = child.processIdentifier
        child.terminate()
        child.waitUntilExit()

        XCTAssertNil(ProcessTree().startTime(of: pid))
    }

    /// The identity gate: a recorded identity whose start time no longer matches is a
    /// *different* process that inherited a recycled pid, and must never be signalled.
    func testIsAliveRejectsAMismatchedStartTime() throws {
        let child = try spawnSleeper()
        let tree = ProcessTree()

        let real = try XCTUnwrap(tree.identity(of: child.processIdentifier))
        let impostor = ProcessIdentity(pid: real.pid, procStart: real.procStart &+ 1)

        XCTAssertTrue(tree.isAlive(real))
        XCTAssertFalse(tree.isAlive(impostor))
    }

    func testIsAliveIsFalseForADeadProcess() throws {
        let child = try spawnSleeper()
        let tree = ProcessTree()
        let identity = try XCTUnwrap(tree.identity(of: child.processIdentifier))
        child.terminate()
        child.waitUntilExit()

        XCTAssertFalse(tree.isAlive(identity))
    }
}
