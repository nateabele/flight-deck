import Foundation

/// Host: the per-controller workspace store (spec §4.1, §4.4–§4.7).
///
/// ```
/// <root>/workspaces/<controller>/<repo-root-commit>/
///   store.git/                                  bare object store
///     refs/fd/heads/<wt-key>                    the local HEAD each worktree last sent
///     refs/fd/snapshots/<wt-key>/<n>            the last K snapshots per worktree
///     refs/fd/results/<run-id>                  result commits until fetched or 24h old
///   checkouts/<wt-key>-<slot>/<worktree-name>/  one `git worktree` per pool slot
/// <root>/runs/<run-id>/artifacts.tar            captured artifacts
/// ```
///
/// Every method shells out to git and may take minutes (a first sync, a big checkout). They
/// all run git on a global dispatch queue, never on the caller's executor, so a caller on an
/// event loop (NIO, the Darwin transport) stays responsive; it must still not *block* waiting
/// for the result. `checkout` suspends, without holding a thread, while the pool is full.
///
/// Pool state (who holds which slot) is in memory: a hostd restart ends every run anyway, so
/// there is nothing to recover except the checkouts themselves, which `existingCheckout`
/// rediscovers from disk.
public final class Workspace: WorkspaceStore, @unchecked Sendable {
    public let root: URL
    public let poolSize: Int
    public let keep: Int
    public let resultTTL: TimeInterval
    private let git: GitRunner

    private let lock = NSLock()
    private var pools: [PoolKey: [Int: Slot]] = [:]
    private var leases: [UUID: (key: PoolKey, slot: Int)] = [:]
    private var waiters: [PoolKey: [Waiter]] = [:]
    /// Checkouts waiting for a slot, oldest first. Only the head may take a free slot, so a run
    /// that queued first starts first, and a cancelled one leaves without reordering the rest.
    private var queues: [PoolKey: [UUID]] = [:]
    private var generation: [PoolKey: Int] = [:]
    private var storeLocks: [String: NSLock] = [:]

    public init(root: URL, poolSize: Int = 2, keep: Int = 5, resultTTL: TimeInterval = 24 * 3600,
                git: GitRunner = GitRunner(isolated: true)) {
        self.root = root
        self.poolSize = poolSize
        self.keep = keep
        self.resultTTL = resultTTL
        self.git = git
    }

    public func storeURL(controller: UUID, repoRoot: String) -> URL {
        repoDir(controller, repoRoot).appendingPathComponent("store.git")
    }

    private func repoDir(_ controller: UUID, _ repoRoot: String) -> URL {
        root.appendingPathComponent("workspaces/\(controller.uuidString)/\(repoRoot)")
    }

    private func checkoutsDir(_ key: PoolKey) -> URL { repoDir(key.controller, key.repoRoot).appendingPathComponent("checkouts") }

    private func slotPath(_ key: PoolKey, _ slot: Int, _ name: String) -> URL {
        // isDirectory: a URL built before the directory exists would otherwise lack the
        // trailing slash one built afterwards gets, and two leases on one slot compare unequal.
        checkoutsDir(key).appendingPathComponent("\(key.wtKey)-\(slot)/\(name)", isDirectory: true)
    }

    // MARK: - Sync (§4.3)

    public func tips(controller: UUID, repoRoot: String, wtKey: String) async throws -> [String] {
        let store = storeURL(controller: controller, repoRoot: try SyncName.objectID(repoRoot))
        let wtKey = try SyncName.validate(wtKey)
        return try await GitRunner.offload { [git] in
            guard FileManager.default.fileExists(atPath: store.path) else { return [] }
            // Every worktree's head, not just this one's: two local clones of one repo share the
            // store (§4.1), and the more haves the controller can match, the smaller the bundle.
            let ids = try git.text(["for-each-ref", "--format=%(objectname)", "refs/fd/heads/", "refs/fd/snapshots/\(wtKey)/"], in: store)
            var seen = Set<String>()
            return ids.split(separator: "\n").map(String.init).filter { seen.insert($0).inserted }
        }
    }

    public func receive(controller: UUID, bundle: URL, ref: SnapshotRef) async throws {
        let ref = try validated(ref)
        let store = storeURL(controller: controller, repoRoot: ref.repoRoot)
        try await GitRunner.offload { [self] in
            try withStore(store) {
                if !FileManager.default.fileExists(atPath: store.path) {
                    try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
                    try git.run(["init", "-q", "--bare", store.path])
                }
                let heads = try git.text(["bundle", "list-heads", bundle.path], in: store).split(separator: "\n")
                guard let head = heads.first(where: { $0.hasPrefix(ref.commit + " ") }) else {
                    throw SyncError.bundleLacksSnapshot(ref.commit)
                }
                let bundleRef = String(head.dropFirst(ref.commit.count + 1))
                let prefix = "refs/fd/snapshots/\(ref.wtKey)/"
                let numbers = try numbered(prefix, in: store)
                let next = (numbers.last ?? 0) + 1
                try git.run(["fetch", "-q", "--no-tags", "--no-write-fetch-head", bundle.path, "\(bundleRef):\(prefix)\(next)"], in: store)
                // Early check, so a bad push fails at sync and not on the first checkout.
                let tree = try git.text(["rev-parse", "\(ref.commit)^{tree}"], in: store)
                guard tree == ref.tree else { throw SyncError.treeMismatch(expected: ref.tree, actual: tree) }
                var script = "update refs/fd/heads/\(ref.wtKey) \(try git.text(["rev-parse", "\(ref.commit)^"], in: store))\n"
                script += (numbers + [next]).dropLast(keep).map { "delete \(prefix)\($0)\n" }.joined()
                try git.run(["update-ref", "--stdin"], in: store, input: Data(script.utf8))
            }
        }
    }

    // MARK: - Pool (§4.4, §4.6)

    public func checkout(controller: UUID, ref: SnapshotRef, pin: Bool) async throws -> CheckoutLease {
        try await checkout(controller: controller, ref: ref, pin: pin, pool: nil)
    }

    /// `pool` overrides the slot count for this worktree (a recipe's `pool`); nil is `poolSize`.
    ///
    /// Same-snapshot runs share a slot; a pinned (service) checkout neither joins nor is joined,
    /// because a `service.sync` rewrites its tree in place and would pull it out from under a
    /// run. A different snapshot takes a free slot, preferring one already at that commit, or
    /// waits its turn in a FIFO queue until one is released. Cancelling the waiting task (how
    /// the runner cancels a queued run) throws `CancellationError` at once and drops it from the
    /// queue; the waiters behind it keep their order.
    public func checkout(controller: UUID, ref: SnapshotRef, pin: Bool, pool: Int?) async throws -> CheckoutLease {
        let ref = try validated(ref)
        let key = PoolKey(controller: controller, repoRoot: ref.repoRoot, wtKey: ref.wtKey)
        let size = max(1, pool ?? poolSize)
        let id = UUID()
        var queued = false
        // Leaving the queue by any path (cancelled, failed) must let the next waiter move up.
        defer {
            if queued {
                lock.withLock { queues[key]?.removeAll { $0 == id } }
                wake(key)
            }
        }
        while true {
            try Task.checkCancellation()
            let (claim, seen, dequeued) = lock.withLock { () -> (Claim, Int, Bool) in
                let wasQueued = queued
                let claim = claimSlot(key, ref, pin, size, id, queued: &queued)
                return (claim, generation[key, default: 0], wasQueued && !queued)
            }
            // The head took its slot: the next waiter may now be head of a pool with a slot free.
            if dequeued { wake(key) }
            switch claim {
            case .shared(let lease):
                return lease
            case .wait:
                try await waitForChange(key, since: seen)
            case .apply(let slot, let path):
                do {
                    try await GitRunner.offload { [self] in
                        try withStore(storeURL(controller: controller, repoRoot: ref.repoRoot)) {
                            try apply(ref, at: path, store: storeURL(controller: controller, repoRoot: ref.repoRoot))
                        }
                    }
                } catch {
                    lock.withLock {
                        leases[id] = nil
                        pools[key]?[slot]?.holders.remove(id)
                        pools[key]?[slot]?.ref = nil
                        pools[key]?[slot]?.ready = true
                        if pools[key]?[slot]?.holders.isEmpty == true { pools[key]?[slot]?.pinned = false }
                    }
                    wake(key)
                    throw error
                }
                lock.withLock {
                    pools[key]?[slot]?.ref = ref
                    pools[key]?[slot]?.ready = true
                    pools[key]?[slot]?.lastApplied = Date()
                }
                wake(key)
                return CheckoutLease(id: id, path: path, slot: slot, ref: ref)
            }
        }
    }

    private enum Claim { case shared(CheckoutLease), apply(slot: Int, path: URL), wait }

    /// Under `lock`. Decides what this request gets right now, and if it gets a slot, holds it.
    private func claimSlot(_ key: PoolKey, _ ref: SnapshotRef, _ pin: Bool, _ size: Int, _ id: UUID,
                           queued: inout Bool) -> Claim {
        var slots = pools[key, default: [:]]
        defer { pools[key] = slots }
        func dequeue() {
            if queued { queues[key]?.removeAll { $0 == id }; queued = false }
        }
        if !pin, let (index, slot) = slots.first(where: { !$0.value.pinned && !$0.value.holders.isEmpty && $0.value.ref?.commit == ref.commit }) {
            // Joining while the first holder is still applying would hand out a half-written tree.
            guard slot.ready else { return .wait }
            // A share takes no slot, so it never waits its turn behind slot-takers.
            dequeue()
            slot.holders.insert(id)
            leases[id] = (key, index)
            return .shared(CheckoutLease(id: id, path: slot.path, slot: index, ref: ref))
        }
        let free = (0..<size).filter { slots[$0]?.holders.isEmpty ?? true }
        let queue = queues[key, default: []]
        guard queue.isEmpty || queue.first == id,
              let index = free.first(where: { slots[$0]?.ref?.commit == ref.commit }) ?? free.first else {
            if !queued { queues[key, default: []].append(id); queued = true }
            return .wait
        }
        dequeue()
        let slot = slots[index] ?? Slot(path: slotPath(key, index, ref.worktreeName))
        slot.path = slotPath(key, index, ref.worktreeName)
        slot.holders = [id]
        slot.pinned = pin
        slot.ready = false
        slot.ref = ref
        slots[index] = slot
        leases[id] = (key, index)
        return .apply(slot: index, path: slot.path)
    }

    /// Suspends until the pool for `key` changes. `since` closes the lost-wakeup window: a
    /// release between the claim and this registration bumps the generation, so we return
    /// at once instead of sleeping on a slot that is already free.
    private func waitForChange(_ key: PoolKey, since: Int) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if generation[key, default: 0] != since || Task.isCancelled { return true }
                    waiters[key, default: []].append(Waiter(id: id, cont: cont))
                    return false
                }
                if resumeNow { cont.resume() }
            }
        } onCancel: {
            let cont = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard let i = waiters[key]?.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters[key]?.remove(at: i).cont
            }
            cont?.resume(throwing: CancellationError())
        }
    }

    private func wake(_ key: PoolKey) {
        let woken = lock.withLock { () -> [Waiter] in
            generation[key, default: 0] += 1
            return waiters.removeValue(forKey: key) ?? []
        }
        woken.forEach { $0.cont.resume() }
    }

    /// `checkout --force --detach` then `clean -fd`, never `-x`: non-ignored files now match
    /// the snapshot exactly, while ignored build output (DerivedData, `node_modules`, `.build`)
    /// stays, so builds are incremental. Unchanged files keep their mtimes because git only
    /// rewrites what differs. Then the tree is verified (§4.4.3) before anything can run.
    private func apply(_ ref: SnapshotRef, at path: URL, store: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: path.appendingPathComponent(".git").path) {
            // A run that touched a file without changing it (a formatter, `touch`) leaves it
            // stat-dirty, and `checkout --force` rewrites stat-dirty files, bumping the mtime and
            // forcing a rebuild. Refreshing first re-hashes those and finds them clean.
            try git.run(["update-index", "-q", "--refresh"], in: path, accept: [0, 1])
            try git.run(["checkout", "-q", "--force", "--detach", ref.commit], in: path)
            try git.run(["clean", "-fdq"], in: path)
        } else {
            // A slot directory without `.git` is a leftover from a prune or a crash mid-add.
            try? fm.removeItem(at: path)
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try git.run(["worktree", "prune"], in: store)
            try git.run(["worktree", "add", "-q", "--detach", "--force", path.path, ref.commit], in: store)
        }
        let actual = try git.text(["rev-parse", "HEAD^{tree}"], in: path)
        guard actual == ref.tree else { throw SyncError.treeMismatch(expected: ref.tree, actual: actual) }
    }

    /// For `exec`: the worktree's most recently applied checkout, as it stands, with no apply.
    /// Shares with whoever holds it, a service included, because inspecting is the point.
    public func existingCheckout(controller: UUID, repoRoot: String, wtKey: String) async throws -> CheckoutLease {
        let key = PoolKey(controller: controller, repoRoot: try SyncName.objectID(repoRoot), wtKey: try SyncName.validate(wtKey))
        let id = UUID()
        if let lease = lock.withLock({ joinExisting(key, id) }) { return lease }

        // Nothing in memory (a fresh hostd): rediscover the checkouts from disk.
        let found = try await GitRunner.offload { [self] () -> [(Int, URL, SnapshotRef)] in
            let fm = FileManager.default
            let dirs = (try? fm.contentsOfDirectory(atPath: checkoutsDir(key).path)) ?? []
            return dirs.compactMap { dir -> (Int, URL, SnapshotRef)? in
                guard dir.hasPrefix(key.wtKey + "-"), let slot = Int(dir.dropFirst(key.wtKey.count + 1)),
                      let name = try? fm.contentsOfDirectory(atPath: checkoutsDir(key).appendingPathComponent(dir).path).first
                else { return nil }
                let path = slotPath(key, slot, name)
                guard let commit = try? git.text(["rev-parse", "HEAD"], in: path),
                      let tree = try? git.text(["rev-parse", "HEAD^{tree}"], in: path) else { return nil }
                return (slot, path, SnapshotRef(repoRoot: key.repoRoot, wtKey: key.wtKey, worktreeName: name, commit: commit, tree: tree))
            }
        }
        return try lock.withLock {
            if let lease = joinExisting(key, id) { return lease }
            guard let (index, path, ref) = found.min(by: { $0.0 < $1.0 }) else { throw SyncError.noCheckout }
            let slot = pools[key]?[index] ?? Slot(path: path)
            slot.ref = ref
            slot.ready = true
            slot.holders.insert(id)
            pools[key, default: [:]][index] = slot
            leases[id] = (key, index)
            return CheckoutLease(id: id, path: path, slot: index, ref: ref)
        }
    }

    /// Under `lock`.
    private func joinExisting(_ key: PoolKey, _ id: UUID) -> CheckoutLease? {
        guard let (index, slot) = pools[key]?.filter({ $0.value.ready && $0.value.ref != nil })
            .max(by: { $0.value.lastApplied < $1.value.lastApplied }), let ref = slot.ref else { return nil }
        slot.holders.insert(id)
        leases[id] = (key, index)
        return CheckoutLease(id: id, path: slot.path, slot: index, ref: ref)
    }

    /// `service.sync`: applies `ref` in place to the lease's own slot.
    public func reapply(_ lease: CheckoutLease, ref: SnapshotRef) async throws -> CheckoutLease {
        let ref = try validated(ref)
        guard let (key, index) = lock.withLock({ leases[lease.id] }) else { throw SyncError.noCheckout }
        let store = storeURL(controller: key.controller, repoRoot: key.repoRoot)
        try await GitRunner.offload { [self] in try withStore(store) { try apply(ref, at: lease.path, store: store) } }
        lock.withLock {
            pools[key]?[index]?.ref = ref
            pools[key]?[index]?.lastApplied = Date()
        }
        return CheckoutLease(id: lease.id, path: lease.path, slot: lease.slot, ref: ref)
    }

    /// Releases one holder of the lease's slot; the slot is free once its last holder is gone.
    /// Releasing twice, or a lease this store never issued, does nothing.
    public func release(_ lease: CheckoutLease) async {
        let key = lock.withLock { () -> PoolKey? in
            guard let (key, index) = leases.removeValue(forKey: lease.id), let slot = pools[key]?[index] else { return nil }
            slot.holders.remove(lease.id)
            if slot.holders.isEmpty { slot.pinned = false }
            return key
        }
        if let key { wake(key) }
    }

    // MARK: - Results (§4.5)

    /// Stages the checkout's non-ignored changes in a temporary index and commits them as a
    /// child of the snapshot. Run after the command exits and before the slot is released.
    public func resultCommit(lease: CheckoutLease, runID: String) async throws -> String? {
        let runID = try SyncName.validate(runID)
        return try await GitRunner.offload { [git] () -> String? in
            let index = try TempIndex(git: git, top: lease.path, dir: FileManager.default.temporaryDirectory, seed: lease.ref.commit)
            defer { index.remove() }
            try git.run(["add", "-A"], in: lease.path, env: index.env)
            let tree = try git.text(["write-tree"], in: lease.path, env: index.env)
            guard tree != lease.ref.tree else { return nil }
            let commit = try git.text(["commit-tree", tree, "-p", lease.ref.commit, "-m", "flightdeck result \(runID)"], in: lease.path)
            try git.run(["update-ref", "refs/fd/results/\(runID)", commit], in: lease.path)
            return commit
        }
    }

    /// A bundle of the one result commit (its parent, the snapshot, is the controller's). It is
    /// a fresh temporary file the caller streams and deletes. Bundling marks the result
    /// fetched, so the next `gc` expires it.
    public func resultBundle(controller: UUID, repoRoot: String, runID: String) async throws -> URL? {
        let store = storeURL(controller: controller, repoRoot: try SyncName.objectID(repoRoot))
        let runID = try SyncName.validate(runID)
        return try await GitRunner.offload { [git] () -> URL? in
            guard FileManager.default.fileExists(atPath: store.path),
                  let commit = try? git.text(["rev-parse", "-q", "--verify", "refs/fd/results/\(runID)"], in: store)
            else { return nil }
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("fd-\(UUID().uuidString).bundle")
            try git.run(["bundle", "create", "-q", out.path, "refs/fd/results/\(runID)", "--not", "\(commit)^"], in: store)
            let marks = store.appendingPathComponent("fd-fetched")
            try FileManager.default.createDirectory(at: marks, withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: marks.appendingPathComponent(runID).path, contents: nil)
            return out
        }
    }

    // MARK: - Artifacts (§4.5)

    /// Tars every untracked path in the checkout that a glob matches into
    /// `runs/<runID>/artifacts.tar`, at exit and before the slot is released (the next run's
    /// `clean` would otherwise get there first). A glob matching a directory takes its
    /// contents, so `**/*.xcresult` ships the bundle. nil when nothing matched.
    ///
    /// A glob that matches a *tracked* path throws: tracked files come back through the
    /// three-way-merged patch, and a tar would overwrite the user's concurrent edits instead.
    /// Preflight refuses this earlier (C5); this is the backstop.
    public func captureArtifacts(lease: CheckoutLease, runID: String, globs: [String]) async throws -> URL? {
        let runID = try SyncName.validate(runID)
        let out = root.appendingPathComponent("runs/\(runID)/artifacts.tar")
        return try await GitRunner.offload { [git] () -> URL? in
            guard !globs.isEmpty else { return nil }
            let tracked = try git.fields(["ls-files", "-z"], in: lease.path)
            for glob in globs {
                if let hit = tracked.first(where: { ArtifactGlob.matches(glob, $0) }) {
                    throw SyncError.artifactTracked(glob: glob, path: hit)
                }
            }
            let untracked = try git.fields(["ls-files", "-z", "--others"], in: lease.path)
            let picked = untracked.filter { path in globs.contains { ArtifactGlob.matches($0, path) } }.sorted()
            guard !picked.isEmpty else { return nil }

            let fm = FileManager.default
            try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            let list = fm.temporaryDirectory.appendingPathComponent("fd-\(UUID().uuidString).list")
            try Data(picked.joined(separator: "\0").utf8 + [0]).write(to: list)
            defer { try? fm.removeItem(at: list) }
            try ArtifactGlob.tar(["-cf", out.path, "-C", lease.path.path, "--null", "-T", list.path])
            return out
        }
    }

    public func storedArtifacts(runID: String) -> URL? {
        guard let runID = try? SyncName.validate(runID) else { return nil }
        let url = root.appendingPathComponent("runs/\(runID)/artifacts.tar")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// How many checkouts wait for a slot of this worktree (tests, and a queued run's position).
    func queueLength(controller: UUID, repoRoot: String, wtKey: String) -> Int {
        lock.withLock { queues[PoolKey(controller: controller, repoRoot: repoRoot, wtKey: wtKey)]?.count ?? 0 }
    }

    // MARK: - Growth (§4.7)

    /// One row per checked-out worktree (the sum of its slots, build output included) plus one
    /// per store with an empty `worktreeName` for the shared object store.
    public func usage(controller: UUID) async throws -> [WorkspaceUsage] {
        let base = root.appendingPathComponent("workspaces/\(controller.uuidString)")
        return try await GitRunner.offload { () -> [WorkspaceUsage] in
            let fm = FileManager.default
            var rows: [WorkspaceUsage] = []
            for repoRoot in ((try? fm.contentsOfDirectory(atPath: base.path)) ?? []).sorted() {
                let repo = base.appendingPathComponent(repoRoot)
                rows.append(WorkspaceUsage(repoRoot: repoRoot, worktreeName: "", bytes: Self.bytes(repo.appendingPathComponent("store.git"))))
                var byName: [String: Int64] = [:]
                let checkouts = repo.appendingPathComponent("checkouts")
                for slot in (try? fm.contentsOfDirectory(atPath: checkouts.path)) ?? [] {
                    for name in (try? fm.contentsOfDirectory(atPath: checkouts.appendingPathComponent(slot).path)) ?? [] {
                        byName[name, default: 0] += Self.bytes(checkouts.appendingPathComponent("\(slot)/\(name)"))
                    }
                }
                rows += byName.sorted { $0.key < $1.key }.map { WorkspaceUsage(repoRoot: repoRoot, worktreeName: $0.key, bytes: $0.value) }
            }
            return rows
        }
    }

    /// Deletes the checkouts (and with them their build output) for one repo, or for all of
    /// this controller's repos. The object store stays, so the next sync is still a delta.
    /// Refuses while any of those slots is held: deleting a running build's tree under it
    /// would surface as baffling compiler errors, not as a prune.
    public func prune(controller: UUID, repoRoot: String?) async throws {
        let base = root.appendingPathComponent("workspaces/\(controller.uuidString)")
        let only = try repoRoot.map { try SyncName.objectID($0) }
        try lock.withLock {
            let keys = pools.keys.filter { $0.controller == controller && (only == nil || $0.repoRoot == only) }
            if keys.contains(where: { pools[$0]?.values.contains { !$0.holders.isEmpty } ?? false }) { throw SyncError.runActive }
            keys.forEach { pools[$0] = nil }
        }
        try await GitRunner.offload { [self] in
            let fm = FileManager.default
            let repos = only.map { [$0] } ?? ((try? fm.contentsOfDirectory(atPath: base.path)) ?? [])
            for repoRoot in repos {
                let repo = base.appendingPathComponent(repoRoot)
                let store = repo.appendingPathComponent("store.git")
                try withStore(store) {
                    try? fm.removeItem(at: repo.appendingPathComponent("checkouts"))
                    if fm.fileExists(atPath: store.path) { try git.run(["worktree", "prune"], in: store) }
                }
            }
        }
    }

    /// Expires result refs that were fetched or are older than `resultTTL`, prunes stale
    /// worktree records, then `git gc --auto` (§4.7). The host calls it periodically.
    public func gc(now: Date = Date()) async throws {
        let base = root.appendingPathComponent("workspaces")
        try await GitRunner.offload { [self] in
            let fm = FileManager.default
            for controller in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] {
                for repoRoot in (try? fm.contentsOfDirectory(atPath: base.appendingPathComponent(controller).path)) ?? [] {
                    let store = base.appendingPathComponent("\(controller)/\(repoRoot)/store.git")
                    guard fm.fileExists(atPath: store.path) else { continue }
                    try withStore(store) { try collect(store, now: now) }
                }
            }
        }
    }

    private func collect(_ store: URL, now: Date) throws {
        let fm = FileManager.default
        let marks = store.appendingPathComponent("fd-fetched")
        let fetched = Set((try? fm.contentsOfDirectory(atPath: marks.path)) ?? [])
        let rows = try git.text(["for-each-ref", "--format=%(refname:lstrip=3) %(committerdate:unix)", "refs/fd/results/"], in: store)
            .split(separator: "\n").compactMap { line -> (String, TimeInterval)? in
                let parts = line.split(separator: " ")
                guard parts.count == 2, let t = TimeInterval(parts[1]) else { return nil }
                return (String(parts[0]), t)
            }
        let expired = rows.filter { fetched.contains($0.0) || now.timeIntervalSince1970 - $0.1 > resultTTL }.map(\.0)
        if !expired.isEmpty {
            let script = expired.map { "delete refs/fd/results/\($0)\n" }.joined()
            try git.run(["update-ref", "--stdin"], in: store, input: Data(script.utf8))
        }
        for mark in fetched where !rows.contains(where: { $0.0 == mark }) || expired.contains(mark) {
            try? fm.removeItem(at: marks.appendingPathComponent(mark))
        }
        try git.run(["worktree", "prune"], in: store)
        try git.run(["gc", "--auto", "-q"], in: store)
    }

    // MARK: - Helpers

    private func validated(_ ref: SnapshotRef) throws -> SnapshotRef {
        _ = try SyncName.objectID(ref.repoRoot)
        _ = try SyncName.validate(ref.wtKey)
        _ = try SyncName.directory(ref.worktreeName)
        _ = try SyncName.objectID(ref.commit)
        _ = try SyncName.objectID(ref.tree)
        return ref
    }

    /// Serializes git work per store: `worktree add`, `fetch` and ref transactions on one bare
    /// repo would otherwise race on its lock files and fail one of two concurrent syncs.
    /// Blocks a dispatch thread, never the cooperative pool (every caller is inside `offload`).
    private func withStore<T>(_ store: URL, _ body: () throws -> T) throws -> T {
        let storeLock = lock.withLock { () -> NSLock in
            if let l = storeLocks[store.path] { return l }
            let l = NSLock()
            storeLocks[store.path] = l
            return l
        }
        storeLock.lock()
        defer { storeLock.unlock() }
        return try body()
    }

    private func numbered(_ prefix: String, in store: URL) throws -> [Int] {
        try git.text(["for-each-ref", "--format=%(refname)", prefix], in: store)
            .split(separator: "\n").compactMap { Int($0.dropFirst(prefix.count)) }.sorted()
    }

    private static func bytes(_ dir: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private struct PoolKey: Hashable {
        let controller: UUID
        let repoRoot: String
        let wtKey: String
    }

    private final class Slot {
        var path: URL
        var ref: SnapshotRef?
        var holders: Set<UUID> = []
        var pinned = false
        /// False while the first holder is applying; sharers wait for it.
        var ready = true
        var lastApplied = Date.distantPast
        init(path: URL) { self.path = path }
    }

    private struct Waiter {
        let id: UUID
        let cont: CheckedContinuation<Void, Error>
    }
}

/// Fetch-glob matching (§4.5): `*`, `?` and `[…]` within one path segment, `**` across
/// segments. A glob matches a path if it matches the path itself or any of its leading
/// directories, so `**/*.xcresult` takes everything inside the bundle. git's own pathspec
/// globs cannot do the directory half, which is why this is hand-rolled.
enum ArtifactGlob {
    static func matches(_ glob: String, _ path: String) -> Bool {
        let g = glob.split(separator: "/").map(String.init)
        let p = path.split(separator: "/").map(String.init)
        return (1...max(1, p.count)).contains { match(g[...], p[..<$0]) }
    }

    private static func match(_ g: ArraySlice<String>, _ p: ArraySlice<String>) -> Bool {
        guard let head = g.first else { return p.isEmpty }
        if head == "**" {
            return (p.startIndex...p.endIndex).contains { match(g.dropFirst(), p[$0...]) }
        }
        guard let name = p.first, fnmatch(head, name, 0) == 0 else { return false }
        return match(g.dropFirst(), p.dropFirst())
    }

    /// `tar` from `PATH`: bsdtar on macOS, GNU tar on Linux; both accept `--null -T`.
    static func tar(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["tar"] + args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        try? err.fileHandleForReading.close()   // see GitRunner.run: Foundation never closes it
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw GitError.failed(args: ["tar"] + args, status: p.terminationStatus, stderr: String(decoding: stderr, as: UTF8.self))
        }
    }
}
