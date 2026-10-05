import XCTest
@testable import HostKit

final class WorkspaceTests: XCTestCase {
    let controller = UUID()

    /// Snapshot `repo` and sync it to `store` the way the controller does: ask for tips, bundle
    /// what the host lacks, receive.
    @discardableResult
    func push(_ repo: TempRepo, to store: Workspace, include: [String] = []) async throws -> SnapshotRef {
        let ref = try await Snapshotter().snapshot(worktree: repo.url, host: "mini", include: include)
        let tips = try await store.tips(controller: controller, repoRoot: ref.repoRoot, wtKey: ref.wtKey)
        let bundle = try await BundleMaker().bundle(worktree: repo.url, snapshot: ref, haves: tips)
        try await store.receive(controller: controller, bundle: bundle, ref: ref)
        return ref
    }

    func makeRepo() throws -> TempRepo {
        let repo = try TempRepo()
        repo.write(".gitignore", "build/\n")
        repo.write("a.txt", "a\n"); repo.write("b.txt", "b\n"); repo.write("c.txt", "c\n")
        try repo.commitAll()
        return repo
    }

    func text(_ lease: CheckoutLease, _ path: String) -> String? {
        (try? Data(contentsOf: lease.path.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    func exists(_ lease: CheckoutLease, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: lease.path.appendingPathComponent(path).path)
    }

    // MARK: - Apply (§4.4)

    func testCheckoutPathCarriesWorktreeName() async throws {
        let repo = try makeRepo()
        let root = TempRepo.scratch()
        let store = Workspace(root: root)
        let s1 = try await push(repo, to: store)
        let lease = try await store.checkout(controller: controller, ref: s1, pin: false)
        XCTAssertEqual(lease.path.lastPathComponent, "repo")
        XCTAssertEqual(lease.path.deletingLastPathComponent().lastPathComponent, "\(s1.wtKey)-\(lease.slot)")
        XCTAssertEqual(lease.path.deletingLastPathComponent().deletingLastPathComponent().path,
                       root.appendingPathComponent("workspaces/\(controller.uuidString)/\(s1.repoRoot)/checkouts").path)
        XCTAssertEqual(text(lease, "a.txt"), "a\n")
    }

    /// A tree that does not match the snapshot must stop the run before anything executes:
    /// running tests against the wrong code and reporting them green is the worst outcome.
    func testTreeMismatchRejects() async throws {
        let repo = try makeRepo()
        let store = Workspace(root: TempRepo.scratch(), poolSize: 1)
        let s1 = try await push(repo, to: store)
        let lie = SnapshotRef(repoRoot: s1.repoRoot, wtKey: s1.wtKey, worktreeName: s1.worktreeName,
                              commit: s1.commit, tree: try repo.git("rev-parse", "HEAD^{tree}") == s1.tree
                                  ? String(repeating: "0", count: 40) : try repo.git("rev-parse", "HEAD^{tree}"))

        let error = await thrown { try await store.checkout(controller: controller, ref: lie, pin: false) }
        XCTAssertEqual(error as? SyncError, .treeMismatch(expected: lie.tree, actual: s1.tree))
        XCTAssertEqual((error as? SyncError)?.code, "tree_mismatch")
        // The failed checkout gave its slot back: with a pool of one, this would hang otherwise.
        let lease = try await store.checkout(controller: controller, ref: s1, pin: false)
        XCTAssertEqual(text(lease, "a.txt"), "a\n")
    }

    func testIgnoredBuildOutputSurvivesApply() async throws {
        let repo = try makeRepo()
        let store = Workspace(root: TempRepo.scratch(), poolSize: 1)
        let s1 = try await push(repo, to: store)
        let first = try await store.checkout(controller: controller, ref: s1, pin: false)
        try FileManager.default.createDirectory(at: first.path.appendingPathComponent("build"), withIntermediateDirectories: true)
        try Data("obj".utf8).write(to: first.path.appendingPathComponent("build/out.o"))
        try Data("junk".utf8).write(to: first.path.appendingPathComponent("junk.txt"))
        await store.release(first)

        repo.write("a.txt", "a2\n")
        let s2 = try await push(repo, to: store)
        let second = try await store.checkout(controller: controller, ref: s2, pin: false)

        XCTAssertEqual(second.path, first.path)
        XCTAssertEqual(text(second, "build/out.o"), "obj", "clean must never run with -x")
        XCTAssertFalse(exists(second, "junk.txt"), "a non-ignored stray must not leak into the next run")
        XCTAssertEqual(text(second, "a.txt"), "a2\n")
    }

    func testDeletedFileRemovedOnApply() async throws {
        let repo = try makeRepo()
        let store = Workspace(root: TempRepo.scratch(), poolSize: 1)
        let first = try await store.checkout(controller: controller, ref: try await push(repo, to: store), pin: false)
        XCTAssertTrue(exists(first, "c.txt"))
        await store.release(first)

        repo.remove("c.txt")
        let second = try await store.checkout(controller: controller, ref: try await push(repo, to: store), pin: false)

        XCTAssertFalse(exists(second, "c.txt"))
    }

    /// Incremental builds key on mtimes: rewriting an unchanged file would make xcodebuild or
    /// make rebuild everything that depends on it, every run.
    func testMtimesOfUnchangedFilesPreserved() async throws {
        let repo = try makeRepo()
        let store = Workspace(root: TempRepo.scratch(), poolSize: 1)
        let first = try await store.checkout(controller: controller, ref: try await push(repo, to: store), pin: false)
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: first.path.appendingPathComponent("a.txt").path)
        await store.release(first)

        repo.write("b.txt", "b2\n")
        let second = try await store.checkout(controller: controller, ref: try await push(repo, to: store), pin: false)

        let mtime = try FileManager.default.attributesOfItem(atPath: second.path.appendingPathComponent("a.txt").path)[.modificationDate] as? Date
        XCTAssertEqual(mtime, old)
        XCTAssertEqual(text(second, "b.txt"), "b2\n")
    }

    // MARK: - Pool (§4.6)

    func testPoolLocksAndQueues() async throws {
        let repo = try makeRepo()
        let store = Workspace(root: TempRepo.scratch(), poolSize: 2)
        let s1 = try await push(repo, to: store)
        repo.write("a.txt", "2\n"); let s2 = try await push(repo, to: store)
        repo.write("a.txt", "3\n"); let s3 = try await push(repo, to: store)

        let a = try await store.checkout(controller: controller, ref: s1, pin: false)
        let b = try await store.checkout(controller: controller, ref: s2, pin: false)
        XCTAssertNotEqual(a.slot, b.slot)

        let done = Flag()
        let ctl = controller
        let third = Task {
            defer { done.set() }
            return try await store.checkout(controller: ctl, ref: s3, pin: false)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(done.value, "a third snapshot must queue while both slots are locked")

        await store.release(a)
        let lease = try await third.value
        XCTAssertEqual(lease.slot, a.slot)
        XCTAssertEqual(text(lease, "a.txt"), "3\n")
    }

    /// The runner cancels a queued run by cancelling the task awaiting `checkout` (C3 review).
    /// The wait must end at once with `CancellationError`, and the waiters behind it must keep
    /// their places: the run queued first still starts first.
    func testCancelledWaiterLeavesQueueInOrder() async throws {
        let repo = try makeRepo()
        let store = Workspace(root: TempRepo.scratch(), poolSize: 2)
        var refs: [SnapshotRef] = []
        for i in 1...5 { repo.write("a.txt", String(repeating: "x", count: i) + "\n"); refs.append(try await push(repo, to: store)) }
        let a = try await store.checkout(controller: controller, ref: refs[0], pin: false)
        let b = try await store.checkout(controller: controller, ref: refs[1], pin: false)

        let ctl = controller, root = refs[0].repoRoot, wt = refs[0].wtKey, snaps = refs
        func queued(_ n: Int) async throws {
            for _ in 0..<1000 where store.queueLength(controller: ctl, repoRoot: root, wtKey: wt) != n {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(store.queueLength(controller: ctl, repoRoot: root, wtKey: wt), n)
        }
        let first = Task { try await store.checkout(controller: ctl, ref: snaps[2], pin: false) }
        try await queued(1)
        let cancelled = Task { try await store.checkout(controller: ctl, ref: snaps[3], pin: false) }
        try await queued(2)
        let last = Flag()
        let third = Task { defer { last.set() }; return try await store.checkout(controller: ctl, ref: snaps[4], pin: false) }
        try await queued(3)

        let start = Date()
        cancelled.cancel()
        let error = await thrown { try await cancelled.value }
        XCTAssertTrue(error is CancellationError, String(describing: error))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "a cancelled waiter must not sit out its wait")
        try await queued(2)

        await store.release(a)
        let firstLease = try await first.value
        XCTAssertEqual(firstLease.slot, a.slot, "the earliest waiter gets the first free slot")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(last.value, "the last waiter still waits: one slot freed, one waiter served")

        await store.release(b)
        let thirdLease = try await third.value
        XCTAssertEqual(thirdLease.slot, b.slot)
        XCTAssertEqual(text(thirdLease, "a.txt"), "xxxxx\n")
        XCTAssertEqual(store.queueLength(controller: ctl, repoRoot: root, wtKey: wt), 0)
    }

    func testSameSnapshotSharesSlot() async throws {
        let repo = try makeRepo()
        let store = Workspace(root: TempRepo.scratch(), poolSize: 2)
        let s1 = try await push(repo, to: store)
        repo.write("a.txt", "2\n"); let s2 = try await push(repo, to: store)

        let first = try await store.checkout(controller: controller, ref: s1, pin: false)
        let shared = try await store.checkout(controller: controller, ref: s1, pin: false)
        XCTAssertEqual(shared.slot, first.slot)
        XCTAssertEqual(shared.path, first.path)
        XCTAssertNotEqual(shared.id, first.id, "each holder has its own lease, released separately")

        let other = try await store.checkout(controller: controller, ref: s2, pin: false)
        XCTAssertNotEqual(other.slot, first.slot)
        await store.release(other)

        // A service's slot is its own: sharing it would let a sync of the service rewrite a
        // run's tree underneath it, so a pinned checkout neither joins nor is joined.
        let pinned = try await store.checkout(controller: controller, ref: s1, pin: true)
        XCTAssertNotEqual(pinned.slot, first.slot)
        // Releasing one of two holders keeps the slot: the refcount, not the first release, frees it.
        await store.release(first)
        await store.release(first)   // a double release is a no-op, not a second decrement
        let again = try await store.checkout(controller: controller, ref: s1, pin: false)
        XCTAssertEqual(again.slot, first.slot, "the run shares the run's slot, never the service's")
    }

    /// `exec` inspects the checkout as the last run left it (no apply, so no `clean` wiping
    /// the evidence), and a hostd restart must not forget that checkouts exist on disk.
    func testExistingCheckoutNeedsNoApplyAndSurvivesRestart() async throws {
        let repo = try makeRepo()
        let root = TempRepo.scratch()
        let store = Workspace(root: root)
        let s1 = try await push(repo, to: store)
        let none = await thrown { try await store.existingCheckout(controller: controller, repoRoot: s1.repoRoot, wtKey: "unknown") }
        XCTAssertEqual(none as? SyncError, .noCheckout)
        XCTAssertEqual((none as? SyncError)?.code, "no_checkout")

        let run = try await store.checkout(controller: controller, ref: s1, pin: false)
        try Data("left by the run".utf8).write(to: run.path.appendingPathComponent("junk.txt"))
        await store.release(run)

        let exec = try await store.existingCheckout(controller: controller, repoRoot: s1.repoRoot, wtKey: s1.wtKey)
        XCTAssertEqual(exec.path, run.path)
        XCTAssertEqual(text(exec, "junk.txt"), "left by the run")
        await store.release(exec)

        let restarted = Workspace(root: root)
        let found = try await restarted.existingCheckout(controller: controller, repoRoot: s1.repoRoot, wtKey: s1.wtKey)
        XCTAssertEqual(found.path, run.path)
        XCTAssertEqual(found.ref, s1)
    }

    /// `service.sync` re-applies in place: same slot and path (a service's ports and its
    /// `docker compose` project name stay put), new tree.
    func testReapplyInPlace() async throws {
        let repo = try makeRepo()
        let store = Workspace(root: TempRepo.scratch())
        let s1 = try await push(repo, to: store)
        let service = try await store.checkout(controller: controller, ref: s1, pin: true)
        repo.write("a.txt", "a2\n")
        let s2 = try await push(repo, to: store)

        let synced = try await store.reapply(service, ref: s2)

        XCTAssertEqual(synced.id, service.id)
        XCTAssertEqual(synced.slot, service.slot)
        XCTAssertEqual(synced.ref, s2)
        XCTAssertEqual(text(synced, "a.txt"), "a2\n")
    }

    func testUsageAndPrune() async throws {
        let repo = try makeRepo()
        let store = Workspace(root: TempRepo.scratch())
        let s1 = try await push(repo, to: store)
        let lease = try await store.checkout(controller: controller, ref: s1, pin: false)
        try FileManager.default.createDirectory(at: lease.path.appendingPathComponent("build"), withIntermediateDirectories: true)
        try Data(count: 100_000).write(to: lease.path.appendingPathComponent("build/big.o"))

        let rows = try await store.usage(controller: controller)
        XCTAssertEqual(rows.map(\.worktreeName), ["", "repo"])
        XCTAssertGreaterThan(rows[1].bytes, 100_000, "build output counts: it is what prune frees")

        let busy = await thrown { try await store.prune(controller: controller, repoRoot: nil) }
        XCTAssertEqual(busy as? SyncError, .runActive)
        XCTAssertTrue(exists(lease, "build/big.o"))

        await store.release(lease)
        try await store.prune(controller: controller, repoRoot: s1.repoRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.path.path))
        let after = try await store.usage(controller: controller)
        XCTAssertEqual(after.map(\.worktreeName), [""], "the object store stays, so the next sync is still a delta")

        let again = try await store.checkout(controller: controller, ref: s1, pin: false)
        XCTAssertEqual(text(again, "a.txt"), "a\n")
    }

    // MARK: - Results (§4.5)

    func testResultCommitNothingChanged() async throws {
        let repo = try makeRepo()
        let store = Workspace(root: TempRepo.scratch())
        let s1 = try await push(repo, to: store)
        let lease = try await store.checkout(controller: controller, ref: s1, pin: false)

        let unchanged = try await store.resultCommit(lease: lease, runID: "r1")
        XCTAssertNil(unchanged)
        let noBundle = try await store.resultBundle(controller: controller, repoRoot: s1.repoRoot, runID: "r1")
        XCTAssertNil(noBundle)

        try Data("host edit\n".utf8).write(to: lease.path.appendingPathComponent("a.txt"))
        try Data("new\n".utf8).write(to: lease.path.appendingPathComponent("new.txt"))
        try FileManager.default.createDirectory(at: lease.path.appendingPathComponent("build"), withIntermediateDirectories: true)
        try Data("obj".utf8).write(to: lease.path.appendingPathComponent("build/x.o"))

        let committed = try await store.resultCommit(lease: lease, runID: "r2")
        let commit = try XCTUnwrap(committed)
        let storeGit = store.storeURL(controller: controller, repoRoot: s1.repoRoot)
        XCTAssertEqual(try TempRepo.git(["rev-parse", "\(commit)^"], in: storeGit), s1.commit)
        XCTAssertEqual(try TempRepo.git(["rev-parse", "refs/fd/results/r2"], in: storeGit), commit)
        let paths = try TempRepo.git(["ls-tree", "-r", "--name-only", commit], in: storeGit)
        XCTAssertTrue(paths.contains("new.txt"))
        XCTAssertFalse(paths.contains("build/x.o"), "build output is never a result")
        let bundle = try await store.resultBundle(controller: controller, repoRoot: s1.repoRoot, runID: "r2")
        XCTAssertNotNil(bundle)
    }

    // MARK: - Artifacts (§4.5)

    /// A fetch glob over a tracked path would let a tar silently overwrite a file the patch is
    /// supposed to merge, losing the user's concurrent edits.
    func testArtifactGlobOnTrackedPathRefused() async throws {
        let repo = try makeRepo()
        let store = Workspace(root: TempRepo.scratch())
        let lease = try await store.checkout(controller: controller, ref: try await push(repo, to: store), pin: false)
        let fm = FileManager.default
        try fm.createDirectory(at: lease.path.appendingPathComponent("build/out/x.xcresult"), withIntermediateDirectories: true)
        try Data("<xml/>".utf8).write(to: lease.path.appendingPathComponent("build/report.xml"))
        try Data("plist".utf8).write(to: lease.path.appendingPathComponent("build/out/x.xcresult/Info.plist"))

        for glob in ["a.txt", "*.txt"] {
            let error = await thrown { try await store.captureArtifacts(lease: lease, runID: "r1", globs: [glob]) }
            guard case .artifactTracked(glob, _)? = error as? SyncError else { return XCTFail("\(glob): \(String(describing: error))") }
        }
        XCTAssertNil(store.storedArtifacts(runID: "r1"), "a refused capture stores nothing")
        let none = try await store.captureArtifacts(lease: lease, runID: "r1", globs: ["nothing/*"])
        XCTAssertNil(none)

        let captured = try await store.captureArtifacts(lease: lease, runID: "r2", globs: ["build/*.xml", "**/*.xcresult"])
        let tar = try XCTUnwrap(captured)
        XCTAssertEqual(store.storedArtifacts(runID: "r2"), tar)
        let listing = try tarListing(tar)
        XCTAssertTrue(listing.contains("build/report.xml"), listing.joined(separator: ","))
        XCTAssertTrue(listing.contains("build/out/x.xcresult/Info.plist"), "a directory match ships its contents")
        XCTAssertFalse(listing.contains("a.txt"))
    }

    // MARK: - Growth (§4.7)

    func testExpiryAndGC() async throws {
        let repo = try makeRepo()
        let store = Workspace(root: TempRepo.scratch())
        var refs: [SnapshotRef] = []
        for i in 1...7 { repo.write("a.txt", "\(i)\n"); refs.append(try await push(repo, to: store)) }
        let storeGit = store.storeURL(controller: controller, repoRoot: refs[0].repoRoot)
        let snaps = try TempRepo.git(["for-each-ref", "--format=%(objectname)", "refs/fd/snapshots/\(refs[0].wtKey)/"], in: storeGit)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(Set(snaps), Set(refs.suffix(5).map(\.commit)), "the store keeps the last K=5 snapshots")
        XCTAssertEqual(try TempRepo.git(["rev-parse", "refs/fd/heads/\(refs[0].wtKey)"], in: storeGit),
                       try repo.git("rev-parse", "HEAD"))

        let lease = try await store.checkout(controller: controller, ref: refs.last!, pin: false)
        for run in ["fetched", "fresh"] {
            try Data(run.utf8).write(to: lease.path.appendingPathComponent("\(run).txt"))
            let commit = try await store.resultCommit(lease: lease, runID: run)
            XCTAssertNotNil(commit)
        }
        let bundle = try await store.resultBundle(controller: controller, repoRoot: refs[0].repoRoot, runID: "fetched")
        XCTAssertNotNil(bundle)

        func results() throws -> [String] {
            try TempRepo.git(["for-each-ref", "--format=%(refname:lstrip=3)", "refs/fd/results/"], in: storeGit)
                .split(separator: "\n").map(String.init).sorted()
        }
        try await store.gc(now: Date())
        XCTAssertEqual(try results(), ["fresh"], "a fetched result expires at the next gc")
        try await store.gc(now: Date().addingTimeInterval(25 * 3600))
        XCTAssertEqual(try results(), [], "an unfetched result expires after 24h")
    }

    private func tarListing(_ tar: URL) throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["tar", "-tf", tar.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            $0.hasPrefix("./") ? String($0.dropFirst(2)) : String($0)
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func set() { lock.lock(); raised = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return raised }
}
