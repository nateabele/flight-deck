import XCTest
import IntakeKit
@testable import FlightDeck

/// `ProcessSnapshot` must answer exactly as `ProcessTree` does — it only exists to make the
/// probe passes cheaper — and the argv[0] cache must never serve a stale answer.
final class ProcessSnapshotTests: XCTestCase {
    private var children: [Process] = []

    override func tearDown() {
        for child in children where child.isRunning { child.terminate() }
        children.removeAll()
    }

    /// `sh` forking a real `sleep`, so the subtree is two deep (see `ProcessTreeTests`).
    private func spawnTree() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 30 & wait"]
        try p.run()
        children.append(p)
        let deadline = Date().addingTimeInterval(10)
        while ProcessTree().descendants(of: p.processIdentifier).isEmpty, Date() < deadline { usleep(5_000) }
        return p
    }

    func testSnapshotAgreesWithTheLiveTreeOnThisProcessesSubtree() throws {
        _ = try spawnTree()
        _ = try spawnTree()
        let live = ProcessTree()
        guard let snapshot = ProcessSnapshot.capture() else { return XCTFail("KERN_PROC_ALL unreadable") }

        let liveTree = live.descendants(of: getpid())
        let snapTree = snapshot.descendants(of: getpid())
        XCTAssertGreaterThanOrEqual(liveTree.count, 4)
        // Order differs by design (the live walk iterates a Set); identity must not.
        XCTAssertEqual(Set(snapTree.map(\.pid)), Set(liveTree.map(\.pid)))
        for process in liveTree {
            XCTAssertEqual(snapshot.startTime(of: process.pid), live.startTime(of: process.pid), "pid \(process.pid)")
            XCTAssertEqual(snapshot.pgid(of: process.pid), live.pgid(of: process.pid), "pid \(process.pid)")
            XCTAssertEqual(snapshot.children(of: process.pid), live.children(of: process.pid), "pid \(process.pid)")
            XCTAssertTrue(snapshot.isAlive(process))
        }
        XCTAssertEqual(snapshot.startTime(of: getpid()), live.startTime(of: getpid()))
        XCTAssertEqual(snapshot.children(of: getpid()), live.children(of: getpid()))
    }

    /// The reason `startTime` is a sysctl: the setuid `login` under every session. Pid 1 is the
    /// root-owned process every machine has.
    func testRootOwnedProcessesAreReadableWithParentAndGroup() throws {
        guard let snapshot = ProcessSnapshot.capture() else { return XCTFail("KERN_PROC_ALL unreadable") }
        XCTAssertNotNil(snapshot.startTime(of: 1))
        XCTAssertEqual(snapshot.startTime(of: 1), ProcessTree().startTime(of: 1))
        XCTAssertEqual(snapshot.pgid(of: 1), 1)
        XCTAssertTrue(snapshot.children(of: 1).contains { snapshot.pgid(of: $0) != nil }, "launchd's children carry a group")
        XCTAssertFalse(snapshot.children(of: 1).isEmpty)
    }

    func testSnapshotKeepsTheWalkSemanticsOnAScriptedTable() {
        func entry(_ ppid: pid_t) -> ProcessSnapshot.Entry {
            .init(ppid: ppid, startTime: UInt64(ppid) + 1000, pgid: ppid, comm: "x")
        }
        // 10 -> 11 -> 12 ... a chain deeper than the depth limit, plus a sibling.
        var table: [pid_t: ProcessSnapshot.Entry] = [10: entry(1), 99: entry(10)]
        for pid in (11...40).map({ pid_t($0) }) { table[pid] = entry(pid - 1) }
        table[0] = .init(ppid: 0, startTime: nil, pgid: 0, comm: "kernel_task")
        let snapshot = ProcessSnapshot(entries: table)
        let found = snapshot.descendants(of: 10).map(\.pid)
        XCTAssertTrue(found.contains(99))
        XCTAssertTrue(found.contains(11))
        XCTAssertFalse(found.contains(40), "depth limit of 16 holds")
        XCTAssertEqual(snapshot.children(of: 0), [], "kernel_task is not its own child")
        XCTAssertNil(snapshot.pgid(of: 0))
        XCTAssertNil(snapshot.startTime(of: 12345))
    }

    // MARK: - argv[0] cache

    func testCacheReadsOnceWhilePidStartAndCommHold() {
        let cache = ArgvZeroCache()
        let table: [pid_t: ProcessSnapshot.Entry] = [7: .init(ppid: 1, startTime: 5, pgid: 7, comm: "2.1.310")]
        let snapshot = ProcessSnapshot(entries: table)
        var reads = 0
        let read: (pid_t) -> String? = { _ in reads += 1; return "claude" }
        XCTAssertEqual(cache.argv0(of: 7, in: snapshot, read: read), "claude")
        XCTAssertEqual(cache.argv0(of: 7, in: snapshot, read: read), "claude")
        XCTAssertEqual(reads, 1)
    }

    func testCacheInvalidatesWhenCommChangesUnderTheSamePidAndStart() {
        let cache = ArgvZeroCache()
        func snapshot(comm: String) -> ProcessSnapshot {
            ProcessSnapshot(entries: [7: .init(ppid: 1, startTime: 5, pgid: 7, comm: comm)])
        }
        var argv = "fish"
        let read: (pid_t) -> String? = { _ in argv }
        XCTAssertEqual(cache.argv0(of: 7, in: snapshot(comm: "fish"), read: read), "fish")
        // The shell execs the agent: same pid, same start time, new p_comm and argv.
        argv = "claude"
        XCTAssertEqual(cache.argv0(of: 7, in: snapshot(comm: "2.1.310"), read: read), "claude")
    }

    func testCacheInvalidatesOnARecycledPidAndRemembersUnreadable() {
        let cache = ArgvZeroCache()
        func snapshot(start: UInt64) -> ProcessSnapshot {
            ProcessSnapshot(entries: [7: .init(ppid: 1, startTime: start, pgid: 7, comm: "x")])
        }
        var reads = 0
        XCTAssertNil(cache.argv0(of: 7, in: snapshot(start: 1)) { _ in reads += 1; return nil })
        XCTAssertNil(cache.argv0(of: 7, in: snapshot(start: 1)) { _ in reads += 1; return nil })
        XCTAssertEqual(reads, 1, "an unreadable process is not re-asked every pass")
        XCTAssertEqual(cache.argv0(of: 7, in: snapshot(start: 2)) { _ in reads += 1; return "codex" }, "codex")
        XCTAssertEqual(reads, 2)
    }

    func testPruneDropsProcessesAbsentFromTheSnapshot() {
        let cache = ArgvZeroCache()
        let both = ProcessSnapshot(entries: [
            7: .init(ppid: 1, startTime: 5, pgid: 7, comm: "a"),
            8: .init(ppid: 1, startTime: 6, pgid: 8, comm: "b"),
        ])
        _ = cache.argv0(of: 7, in: both) { _ in "a" }
        _ = cache.argv0(of: 8, in: both) { _ in "b" }
        XCTAssertEqual(cache.count, 2)
        cache.prune(keeping: ProcessSnapshot(entries: [8: .init(ppid: 1, startTime: 6, pgid: 8, comm: "b")]))
        XCTAssertEqual(cache.count, 1)
    }

    // MARK: - claude fast path

    /// Counts the walk; scripted so no real process is involved.
    private final class ScriptedInspector: ProcessInspecting, @unchecked Sendable {
        var walks = 0
        var living: [pid_t: UInt64] = [:]
        var tree: [ProcessIdentity] = []
        func children(of ppid: pid_t) -> Set<pid_t> { [] }
        func descendants(of pid: pid_t) -> [ProcessIdentity] { walks += 1; return tree }
        func startTime(of pid: pid_t) -> UInt64? { living[pid] }
        func isAlive(_ identity: ProcessIdentity) -> Bool { living[identity.pid] == identity.procStart }
        func pgid(of pid: pid_t) -> pid_t? { nil }
    }

    func testAKnownLiveClaudePidSkipsTheWalk() {
        let inspector = ScriptedInspector()
        inspector.living = [500: 1]
        let probe = AgentProcessProbe(inspector: inspector, argv0: { $0 == 500 ? "claude" : nil })
        XCTAssertTrue(probe.isRunning(.claude, under: [100], knownPID: 500))
        XCTAssertEqual(inspector.walks, 0)
    }

    func testAStaleKnownPidFallsBackToTheWalk() {
        let inspector = ScriptedInspector()
        // Gone: the pid is not listed at all.
        let gone = AgentProcessProbe(inspector: inspector, argv0: { _ in nil })
        XCTAssertFalse(gone.isRunning(.claude, under: [100], knownPID: 500))
        XCTAssertEqual(inspector.walks, 1)
        // Recycled into something else: listed, but not claude; the walk finds the real one.
        inspector.living = [500: 1, 501: 2]
        inspector.tree = [ProcessIdentity(pid: 501, procStart: 2)]
        let recycled = AgentProcessProbe(inspector: inspector, argv0: { $0 == 501 ? "claude" : "vim" })
        XCTAssertTrue(recycled.isRunning(.claude, under: [100], knownPID: 500))
        XCTAssertEqual(inspector.walks, 2)
        // No row at all: walks, as for any other agent.
        XCTAssertTrue(recycled.isRunning(.claude, under: [100]))
        XCTAssertEqual(inspector.walks, 3)
    }

    // MARK: - Cost

    /// Old pass vs new pass, printed (`PROBE-BENCH`), not asserted: this suite runs unoptimised,
    /// where building the snapshot's dictionaries costs several times what it does in a Release
    /// build, and a timing assert on a loaded machine is a flake. The old pass is ~4 syscalls per
    /// descendant (children, start time, two argv reads); the new one is one table read plus an
    /// argv read only on a cache miss.
    func testReportsSnapshotPassCostAgainstLivePass() throws {
        for _ in 0..<12 { _ = try spawnTree() }
        let roots = [getpid()]
        let cache = ArgvZeroCache()
        let passes = 20

        func oldPass() -> Bool {
            AgentProcessProbe().isRunning(.codex, under: roots)
        }
        func newPass() -> Bool {
            let snapshot = ProcessTree().snapshot()
            let probe = AgentProcessProbe(
                inspector: snapshot,
                argv0: { pid in cache.argv0(of: pid, in: snapshot, read: ProcessArguments.argv0(of:)) })
            defer { cache.prune(keeping: snapshot) }
            return probe.isRunning(.codex, under: roots)
        }
        XCTAssertEqual(oldPass(), newPass())

        let oldStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<passes { _ = oldPass() }
        let oldMs = Double(DispatchTime.now().uptimeNanoseconds - oldStart) / 1e6 / Double(passes)
        _ = newPass()   // warm the argv cache, as every pass after the first sees it
        let newStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<passes { _ = newPass() }
        let newMs = Double(DispatchTime.now().uptimeNanoseconds - newStart) / 1e6 / Double(passes)
        let captureStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<passes { _ = ProcessSnapshot.capture() }
        let captureMs = Double(DispatchTime.now().uptimeNanoseconds - captureStart) / 1e6 / Double(passes)
        print("PROBE-BENCH capture=\(captureMs)ms")
        print("PROBE-BENCH descendants=\(ProcessTree().descendants(of: getpid()).count) old=\(oldMs)ms/pass new=\(newMs)ms/pass")
    }
}
