import XCTest
@testable import HostKit

/// Checkout retention in `Workspace.gc` (§4.7): idle slots are evicted after
/// `checkoutIdleTTL`, and below the high-water mark the oldest unleased slots go first. The
/// jeeves hostd filled its disk with 60 GB of checkouts for worktrees long gone, because
/// nothing but an explicit `host prune` ever deleted one.
final class CheckoutRetentionTests: XCTestCase {
    let controller = UUID()
    let day: TimeInterval = 24 * 3600
    static let marker = ".fd-last-used"

    /// The workspace's clock, which leases and releases stamp their marker with.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        var now: Date { lock.withLock { value } }
        func advance(_ by: TimeInterval) { lock.withLock { value += by } }
    }

    static let plenty: @Sendable (URL) -> VolumeSpace? = { _ in VolumeSpace(available: 1 << 50, total: 1 << 50) }

    func makeStore(clock: Clock, freeSpace: @escaping @Sendable (URL) -> VolumeSpace? = CheckoutRetentionTests.plenty) -> Workspace {
        Workspace(root: TempRepo.scratch(), poolSize: 1, checkoutIdleTTL: 3 * day, clock: { clock.now }, freeSpace: freeSpace)
    }

    /// A repo of its own, so each slot below is a different store and worktree.
    func makeRepo(_ tag: String) throws -> TempRepo {
        let repo = try TempRepo()
        repo.write(".gitignore", "build/\n")
        repo.write("a.txt", "\(tag)\n")
        try repo.commitAll()
        return repo
    }

    func push(_ repo: TempRepo, to store: Workspace) async throws -> SnapshotRef {
        let ref = try await Snapshotter().snapshot(worktree: repo.url, host: "mini", include: [])
        let tips = try await store.tips(controller: controller, repoRoot: ref.repoRoot, wtKey: ref.wtKey)
        let bundle = try await BundleMaker().bundle(worktree: repo.url, snapshot: ref, haves: tips)
        try await store.receive(controller: controller, bundle: bundle, ref: ref)
        return ref
    }

    /// Syncs a fresh repo and leases its checkout, with build output in it (what eviction frees).
    func leased(_ tag: String, in store: Workspace) async throws -> (ref: SnapshotRef, lease: CheckoutLease) {
        let ref = try await push(try makeRepo(tag), to: store)
        let lease = try await store.checkout(controller: controller, ref: ref, pin: false)
        try FileManager.default.createDirectory(at: lease.path.appendingPathComponent("build"), withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: lease.path.appendingPathComponent("build/out.o"))
        return (ref, lease)
    }

    /// A slot that was used (leased and released) at the clock's current time.
    func idle(_ tag: String, in store: Workspace) async throws -> (ref: SnapshotRef, slot: URL) {
        let (ref, lease) = try await leased(tag, in: store)
        await store.release(lease)
        return (ref, lease.path.deletingLastPathComponent())
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func worktreeList(_ store: Workspace, _ ref: SnapshotRef) throws -> String {
        try TempRepo.git(["worktree", "list", "--porcelain"], in: store.storeURL(controller: controller, repoRoot: ref.repoRoot))
    }

    // MARK: - Idle eviction

    func testIdleCheckoutIsEvicted() async throws {
        let t0 = Date()
        let clock = Clock(t0)
        let store = makeStore(clock: clock)
        let old = try await idle("old", in: store)
        XCTAssertTrue(exists(old.slot.appendingPathComponent(Self.marker)), "a release stamps the slot's marker")

        // The marker is not a worktree: neither the disk report nor exec's rediscovery see it.
        // (An exec is a use too, so this happens before the clock moves on.)
        let rows = try await store.usage(controller: controller)
        XCTAssertFalse(rows.contains { $0.worktreeName == Self.marker }, "\(rows)")
        let fresh = Workspace(root: store.root, poolSize: 1, clock: { clock.now }, freeSpace: Self.plenty)
        let found = try await fresh.existingCheckout(controller: controller, repoRoot: old.ref.repoRoot, wtKey: old.ref.wtKey)
        XCTAssertEqual(found.path.lastPathComponent, "repo")
        await fresh.release(found)

        clock.advance(2 * day)
        let recent = try await idle("recent", in: store)

        try await store.gc(now: t0 + 3 * day + 3600)

        XCTAssertFalse(exists(old.slot), "a slot idle past checkoutIdleTTL is deleted")
        XCTAssertFalse(try worktreeList(store, old.ref).contains(old.slot.path), "and its worktree record pruned")
        XCTAssertTrue(exists(recent.slot.appendingPathComponent("repo/a.txt")), "a slot used inside the TTL stays")

        // The store stays, so the next run of the evicted worktree rebuilds its slot.
        let again = try await store.checkout(controller: controller, ref: old.ref, pin: false)
        XCTAssertEqual(try String(contentsOf: again.path.appendingPathComponent("a.txt"), encoding: .utf8), "old\n")
    }

    /// A running build's tree deleted under it would surface as baffling compiler errors. The
    /// leased slot's marker is as old as the idle one's: only the live lease keeps it.
    func testLeasedCheckoutIsKept() async throws {
        let t0 = Date()
        let clock = Clock(t0)
        let store = makeStore(clock: clock)
        let running = try await leased("running", in: store)
        let idle = try await idle("idle", in: store)

        try await store.gc(now: t0 + 4 * day)

        XCTAssertTrue(exists(running.lease.path.appendingPathComponent("build/out.o")), "a leased slot is never evicted")
        XCTAssertFalse(exists(idle.slot), "while an idle one beside it is")
        await store.release(running.lease)
    }

    /// gc picks its victims from their markers, then deletes. A run that leases the slot in
    /// between must keep it: the lease check is made under the pool lock, after the pick.
    func testCheckoutLeasedMidGCIsKept() async throws {
        let t0 = Date()
        let clock = Clock(t0)
        let store = makeStore(clock: clock)
        let victim = try await idle("victim", in: store)
        let other = try await idle("other", in: store)

        let reached = Done()
        let gate = Gate()
        defer { gate.open() }
        let target = victim.slot.standardizedFileURL.path
        store.evictionHook = { slot in
            guard slot.standardizedFileURL.path == target else { return }
            reached.set()
            gate.hold()
        }
        let when = t0 + 4 * day
        let gc = Task { try await store.gc(now: when) }
        let picked = await reached.wait(seconds: 20)
        XCTAssertTrue(picked, "gc never picked the idle slot for eviction")
        var lease: CheckoutLease?
        if picked {
            lease = try await store.checkout(controller: controller, ref: victim.ref, pin: false)
            XCTAssertEqual(lease?.path.deletingLastPathComponent().standardizedFileURL.path, target)
        }
        gate.open()
        try await gc.value

        XCTAssertTrue(exists(victim.slot.appendingPathComponent("repo/a.txt")), "a slot leased mid-gc is kept")
        XCTAssertTrue(exists(victim.slot.appendingPathComponent("repo/build/out.o")))
        XCTAssertFalse(exists(other.slot), "the other idle slot is still evicted")
        if let lease { await store.release(lease) }
    }

    // MARK: - High-water mark

    /// Below max(15%, 10 GB) free, gc evicts unleased slots oldest first, and stops as soon as
    /// the volume is back above the mark.
    func testHighWaterEvictsOldestFirst() async throws {
        let t0 = Date()
        let clock = Clock(t0)
        let gib: Int64 = 1 << 30
        let watched = Watched()
        // 100 GiB volume, so the mark is 15 GiB. 5 GiB free, and each slot evicted frees 6.
        let store = makeStore(clock: clock, freeSpace: { _ in
            VolumeSpace(available: 5 * gib + 6 * gib * Int64(watched.gone), total: 100 * gib)
        })
        let oldestButLeased = try await leased("leased", in: store)
        clock.advance(3600)
        let first = try await idle("first", in: store)
        clock.advance(3600)
        let second = try await idle("second", in: store)
        clock.advance(3600)
        let third = try await idle("third", in: store)
        watched.slots = [first.slot, second.slot, third.slot]

        try await store.gc(now: clock.now + 3600)

        XCTAssertTrue(exists(oldestButLeased.lease.path.appendingPathComponent("a.txt")), "a leased slot is never evicted")
        XCTAssertFalse(exists(first.slot), "the oldest unleased slot goes first")
        XCTAssertFalse(exists(second.slot), "then the next, while free space is under the mark")
        XCTAssertTrue(exists(third.slot.appendingPathComponent("repo/a.txt")), "and none once it is back above")
        await store.release(oldestButLeased.lease)
    }

    /// The probe's view of which slots are gone, for a free-space figure that tracks them.
    final class Watched: @unchecked Sendable {
        private let lock = NSLock()
        private var _slots: [URL] = []
        var slots: [URL] {
            get { lock.withLock { _slots } }
            set { lock.withLock { _slots = newValue } }
        }
        var gone: Int { slots.filter { !FileManager.default.fileExists(atPath: $0.path) }.count }
    }

    // MARK: - No marker

    /// Checkouts made before markers existed have none. gc falls back, once, to the slot's
    /// last apply (its worktree index's mtime, which every apply rewrites), not the slot
    /// directory's mtime, and stamps a marker with that time so later passes read the marker.
    func testCheckoutWithoutMarkerFallsBackToLastApply() async throws {
        let clock = Clock(Date())
        let store = makeStore(clock: clock)
        let stale = try await idle("stale", in: store)
        let applied = try await idle("applied", in: store)
        let fm = FileManager.default
        let now = Date()
        let longAgo = now - 5 * day
        for slot in [stale.slot, applied.slot] {
            try? fm.removeItem(at: slot.appendingPathComponent(Self.marker))
            try fm.setAttributes([.modificationDate: longAgo], ofItemAtPath: slot.path)
        }
        let staleIndex = try XCTUnwrap(Workspace.adminDir(stale.slot.appendingPathComponent("repo"))).appendingPathComponent("index")
        try fm.setAttributes([.modificationDate: longAgo], ofItemAtPath: staleIndex.path)

        try await store.gc(now: now)

        XCTAssertFalse(exists(stale.slot), "no marker, last applied five days ago: evicted")
        XCTAssertTrue(exists(applied.slot.appendingPathComponent("repo/a.txt")),
                      "no marker, applied just now: kept, though the slot directory's own mtime is old")
        XCTAssertTrue(exists(applied.slot.appendingPathComponent(Self.marker)), "the fallback is stamped into a marker, once")
    }
}
