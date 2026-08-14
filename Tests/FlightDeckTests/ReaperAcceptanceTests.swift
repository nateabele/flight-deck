// Tests/FlightDeckTests/ReaperAcceptanceTests.swift
import XCTest
@testable import FlightDeck

/// End-to-end against real processes. No fakes: real signals, real libproc, real waiting.
///
/// This is the test that fails against the behavior this work replaces — libghostty sends
/// SIGHUP and only SIGHUP, and the tree below is built specifically to survive that.
final class ReaperAcceptanceTests: XCTestCase {
    private func reaper() -> SessionReaper {
        SessionReaper(inspector: ProcessTree(), signals: PosixSignals(), sleeper: RealSleeper())
    }

    /// `trap '' HUP` makes the shell ignore SIGHUP entirely, and it forks a child that
    /// outlives a naive single-signal teardown.
    func testKillsAShellThatIgnoresSIGHUPAlongWithItsChild() async throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "trap '' HUP; sleep 300 & sleep 300"]
        try shell.run()
        defer { if shell.isRunning { kill(shell.processIdentifier, SIGKILL) } }

        // Let `sh` install the trap and fork its child.
        try await Task.sleep(nanoseconds: 500_000_000)

        let tree = ProcessTree()
        let identity = try XCTUnwrap(tree.identity(of: shell.processIdentifier))
        let descendants = tree.descendants(of: identity.pid)
        XCTAssertFalse(descendants.isEmpty, "expected the shell to have forked a child")

        // Confirm the premise: SIGHUP alone does not kill this tree.
        XCTAssertEqual(kill(identity.pid, SIGHUP), 0)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(tree.isAlive(identity), "premise broken: SIGHUP killed a trapping shell")

        let outcome = await reaper().reap(shell: identity, pgid: getpgid(identity.pid))

        XCTAssertEqual(outcome, .clean)
        XCTAssertFalse(tree.isAlive(identity), "the shell survived the ladder")
        for child in descendants {
            XCTAssertFalse(tree.isAlive(child), "child \(child.pid) survived the ladder")
        }
    }

    /// The rail that keeps a reap from killing this very test process.
    ///
    /// Deviation from the brief: it assumed `Foundation.Process` does not `setsid`, so a
    /// spawned child shares the test runner's process group, and drove this test by reading
    /// that group back off the child (`getpgid(identity.pid) == getpgid(0)`). On this SDK
    /// (macOS 26.5.1) that premise is false — `Process` now puts every child in a *new*
    /// process group of its own (`child pgid == child pid`, confirmed with a standalone
    /// repro: spawning via `Process` and comparing `getpgid(child)` to `getpgid(0)` prints
    /// two different numbers every run) even though it still leaves it in the same session.
    /// A pid cannot be moved into another group after it has exec'd except by itself (POSIX:
    /// `setpgid` on an already-exec'd *other* process is `EACCES`), so there is no way to
    /// coerce a `Process`-spawned child back into sharing our group from here. Instead this
    /// drives the exact input the rail branches on directly: `pgid` equal to our own real
    /// group, regardless of which group the child actually landed in. `PosixSignals.send`
    /// still reaches the child either way (`killpg` on its own new group, or a per-pid
    /// fallback), so the reap still has to succeed; the only thing this asserts is that a
    /// `pgid` matching our own group never reaches `killpg`.
    func testNeverSignalsTheTestRunnersOwnGroup() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "sleep 30"]
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }

        let tree = ProcessTree()
        let identity = try XCTUnwrap(tree.identity(of: child.processIdentifier))

        // If the rail were missing, this would `killpg(getpgid(0), SIGHUP)` — our own group,
        // taking down the test runner along with everything else in it.
        let outcome = await reaper().reap(shell: identity, pgid: getpgid(0))

        XCTAssertEqual(outcome, .clean)
        XCTAssertFalse(tree.isAlive(identity))
        // Reaching this line at all is the assertion: we are still running.
    }
}
