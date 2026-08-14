// Tests/FlightDeckTests/ProcessTreeTests.swift
import XCTest
@testable import FlightDeck

final class ProcessTreeTests: XCTestCase {
    /// Spawns `/bin/sh -c "sleep 30 & wait"` as a child of this test process and returns it.
    /// The `& wait` forces `sh` to fork a real `sleep` child instead of exec-optimizing itself
    /// away, so the process tree is genuinely two deep. The caller must terminate it.
    private func spawnSleeper() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 30 & wait"]
        try p.run()
        return p
    }

    func testChildrenIncludesASpawnedChild() throws {
        let child = try spawnSleeper()
        defer { child.terminate() }

        let kids = ProcessTree().children(of: getpid())

        XCTAssertTrue(kids.contains(child.processIdentifier))
    }

    func testDescendantsIncludesAGrandchild() throws {
        // `sh` stays alive while its own `sleep` child runs, so the tree is two deep.
        let child = try spawnSleeper()
        defer { child.terminate() }

        // Give `sh` a moment to fork `sleep`.
        Thread.sleep(forTimeInterval: 0.3)
        let tree = ProcessTree().descendants(of: getpid()).map(\.pid)

        XCTAssertTrue(tree.contains(child.processIdentifier), "direct child missing")
        XCTAssertGreaterThan(tree.count, 1, "expected the grandchild `sleep` as well")
    }

    func testStartTimeIsStableAcrossReads() throws {
        let child = try spawnSleeper()
        defer { child.terminate() }
        let tree = ProcessTree()

        let first = tree.startTime(of: child.processIdentifier)
        Thread.sleep(forTimeInterval: 0.2)
        let second = tree.startTime(of: child.processIdentifier)

        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
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
        defer { child.terminate() }
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
