import XCTest
@testable import HostKit

/// `Workspace.usage` (`host ls --disk`) stats every file of every checkout. On the jeeves hostd
/// that was 60 GB of build output on a full disk, and the request waits up to
/// `LiveHostLink.bulkReplyTimeout` (an hour), so the CLI sat for minutes. It now answers within
/// `usageBudget`, from the last finished measure, while one walk at a time carries on.
final class WorkspaceUsageTests: XCTestCase {
    let controller = UUID()

    func push(_ repo: TempRepo, to store: Workspace) async throws -> SnapshotRef {
        let ref = try await Snapshotter().snapshot(worktree: repo.url, host: "mini", include: [])
        let tips = try await store.tips(controller: controller, repoRoot: ref.repoRoot, wtKey: ref.wtKey)
        let bundle = try await BundleMaker().bundle(worktree: repo.url, snapshot: ref, haves: tips)
        try await store.receive(controller: controller, bundle: bundle, ref: ref)
        return ref
    }

    /// A store with one released checkout holding `bytes` of build output; returns the
    /// checkout's build directory.
    func storeWithCheckout(bytes: Int) async throws -> (Workspace, URL) {
        let repo = try TempRepo()
        repo.write(".gitignore", "build/\n")
        repo.write("a.txt", "a\n")
        try repo.commitAll()
        let store = Workspace(root: TempRepo.scratch())
        let lease = try await store.checkout(controller: controller, ref: try await push(repo, to: store), pin: false)
        let build = lease.path.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try Data(count: bytes).write(to: build.appendingPathComponent("first.o"))
        await store.release(lease)
        return (store, build)
    }

    /// Starts `usage` and waits up to `seconds` for its answer. nil when it did not answer in
    /// time (the task is left to finish once the walk is let go).
    func answer(_ store: Workspace, within seconds: Double) async -> (Task<[WorkspaceUsage], Error>, Bool) {
        let done = Done()
        let controller = self.controller
        let task = Task { () throws -> [WorkspaceUsage] in
            defer { done.set() }
            return try await store.usage(controller: controller)
        }
        return (task, await done.wait(seconds: seconds))
    }

    func testUsageAnswersFromTheLastMeasureWhileAWalkIsSlow() async throws {
        let (store, build) = try await storeWithCheckout(bytes: 10_000)
        let first = try await store.usage(controller: controller)
        XCTAssertEqual(first.map(\.worktreeName), ["", "repo"])
        try Data(count: 200_000).write(to: build.appendingPathComponent("second.o"))

        let gate = Gate()
        defer { gate.open() }
        store.usageBudget = 0.5
        store.usageWalkHook = { _ in gate.hold() }
        let (task, answered) = await answer(store, within: 5)
        XCTAssertTrue(answered, "usage waited on the walk past its budget")
        gate.open()
        let slow = try await task.value
        if answered { XCTAssertEqual(slow, first, "a walk past its budget answers with the last finished measure") }

        // The walk went on in the background: a later ask sees the new build output.
        store.usageWalkHook = nil
        var latest = slow
        let deadline = Date().addingTimeInterval(10)
        while (latest.last?.bytes ?? 0) < 200_000, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            latest = try await store.usage(controller: controller)
        }
        XCTAssertGreaterThan(latest.last?.bytes ?? 0, 200_000)
    }

    /// No measure has finished yet: the answer still comes within the budget, every row listed,
    /// each with what had been counted so far (a lower bound).
    func testFirstUsageAnswersWithinItsBudgetWithEveryRow() async throws {
        let (store, _) = try await storeWithCheckout(bytes: 10_000)
        let gate = Gate()
        defer { gate.open() }
        store.usageBudget = 0.5
        store.usageWalkHook = { _ in gate.hold() }
        let (task, answered) = await answer(store, within: 5)
        XCTAssertTrue(answered, "usage waited on the walk past its budget")
        gate.open()
        let rows = try await task.value
        XCTAssertEqual(rows.map(\.worktreeName), ["", "repo"])
    }

    /// Asking again while a walk runs joins it rather than starting another: on a sick disk a
    /// second walk only slows the first.
    func testConcurrentUsageSharesOneWalk() async throws {
        let (store, _) = try await storeWithCheckout(bytes: 10_000)
        let gate = Gate()
        defer { gate.open() }
        let walks = Counter()
        store.usageBudget = 0.5
        store.usageWalkHook = { dir in
            if dir.lastPathComponent == "store.git" { walks.bump() }
            gate.hold()
        }
        let (a, answeredA) = await answer(store, within: 5)
        let (b, answeredB) = await answer(store, within: 5)
        XCTAssertTrue(answeredA && answeredB, "usage waited on the walk past its budget")
        gate.open()
        _ = try await a.value
        _ = try await b.value
        XCTAssertEqual(walks.value, 1)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }
}

/// What a full disk does to the host's calls, measured on a real full volume. Skipped unless
/// `FD_FULL_VOLUME` names an empty, small, writable mount, e.g. in Docker:
///
///     docker run --rm --tmpfs /full:size=64m -e FD_FULL_VOLUME=/full -v "$PWD:/src" -w /src \
///       swift:6.3-noble swift test --scratch-path /tmp/hk --filter FullDiskTests
final class FullDiskTests: XCTestCase {
    func testHostCallsOnAFullVolume() async throws {
        guard let volume = ProcessInfo.processInfo.environment["FD_FULL_VOLUME"] else {
            throw XCTSkip("set FD_FULL_VOLUME to a small scratch mount to run this")
        }
        let controller = UUID()
        let root = URL(fileURLWithPath: volume).appendingPathComponent(UUID().uuidString)
        let t0 = Date()
        let store = Workspace(root: root, clock: { t0 })
        let repo = try TempRepo()
        repo.write("a.txt", "a\n")
        try repo.commitAll()
        let ref = try await Snapshotter().snapshot(worktree: repo.url, host: "mini", include: [])
        let bundle = try await BundleMaker().bundle(worktree: repo.url, snapshot: ref, haves: [])
        try await store.receive(controller: controller, bundle: bundle, ref: ref)
        let lease = try await store.checkout(controller: controller, ref: ref, pin: false)
        await store.release(lease)

        // Fill the volume to ENOSPC.
        let filler = URL(fileURLWithPath: volume).appendingPathComponent("filler-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: filler.path, contents: nil)
        let handle = try FileHandle(forWritingTo: filler)
        let chunk = Data(count: 1 << 20)
        while (try? handle.write(contentsOf: chunk)) != nil {}
        try? handle.close()
        defer { try? FileManager.default.removeItem(at: filler) }
        let full = try XCTUnwrap(Workspace.volumeSpace(at: root))
        XCTAssertLessThan(full.available, 1 << 20, "the volume is full")

        var started = Date()
        let info = HostInfoProbe(stateRoot: root, hostdVersion: "test").gather()
        let probe = Date().timeIntervalSince(started)
        print("FULL-DISK host.info gather: \(probe)s, diskFreeBytes \(info.diskFreeBytes)")
        XCTAssertLessThan(probe, 2, "host.info's probe does not block on a full disk")

        started = Date()
        let rows = try await store.usage(controller: controller)
        print("FULL-DISK usage: \(Date().timeIntervalSince(started))s, \(rows)")

        // git's own steps fail on a full disk; eviction must not depend on them.
        started = Date()
        do { try await store.gc(now: t0 + 4 * 24 * 3600) } catch { print("FULL-DISK gc threw (expected on ENOSPC): \(error)") }
        print("FULL-DISK gc: \(Date().timeIntervalSince(started))s")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.path.path), "an idle slot is evicted on a full disk")
    }
}
