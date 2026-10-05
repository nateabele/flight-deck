import Foundation

// Sync (spec §4): the controller snapshots a worktree into a commit, bundles what the host
// lacks, and the host fetches it into its per-repo object store and checks it out into a pool
// slot. Implemented by track C2; the host router and `DelegationService` consume it.

/// One snapshot commit and the workspace it belongs to, as both ends name it.
public struct SnapshotRef: Codable, Sendable, Equatable {
    /// The repo's root commit (the oldest, when there are several): two local clones of one
    /// repo share a host object store under it (§4.1).
    public let repoRoot: String
    /// A stable hash of the controller's absolute worktree path.
    public let wtKey: String
    /// The local worktree's basename. The host's checkout directory carries it, which keeps
    /// derived names such as a `docker compose` project identical to the local ones.
    public let worktreeName: String
    /// The snapshot commit.
    public let commit: String
    /// `commit^{tree}`, verified on the host after checkout and before anything runs (§4.4).
    public let tree: String

    public init(repoRoot: String, wtKey: String, worktreeName: String, commit: String, tree: String) {
        self.repoRoot = repoRoot
        self.wtKey = wtKey
        self.worktreeName = worktreeName
        self.commit = commit
        self.tree = tree
    }

    // Explicit raw values: a Swift rename must not change the wire.
    enum CodingKeys: String, CodingKey {
        case repoRoot = "repoRoot"
        case wtKey = "wtKey"
        case worktreeName = "worktreeName"
        case commit = "commit"
        case tree = "tree"
    }

    /// Hand-written so the leniency rule has a place to live: every field here is the first
    /// wire version's and required, and any field added later must be read with
    /// `decodeIfPresent`, so a 1.1 peer that omits it still decodes. A synthesized decoder
    /// would make a new non-optional field a silent break between builds.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(repoRoot: try c.decode(String.self, forKey: .repoRoot),
                  wtKey: try c.decode(String.self, forKey: .wtKey),
                  worktreeName: try c.decode(String.self, forKey: .worktreeName),
                  commit: try c.decode(String.self, forKey: .commit),
                  tree: try c.decode(String.self, forKey: .tree))
    }
}

/// Controller: commits the worktree's current state (tracked, untracked-not-ignored, and each
/// `include` path) through a temporary `GIT_INDEX_FILE`, never touching the user's index,
/// stash, reflog or branches (§4.2). The commit is kept under
/// `refs/flightdeck/snapshots/<host>/<n>` so `gc` cannot prune it before the host has it. Throws
/// `lfs_unsupported` for an LFS repo and `submodules_unsupported` for a tree with a gitlink:
/// both are out of v1. Async because it shells out to git, which can take seconds on a big
/// tree, and must not hold a cooperative thread while it does.
public protocol SnapshotMaking: Sendable {
    func snapshot(worktree: URL, host: String, include: [String]) async throws -> SnapshotRef
}

/// Controller: a `git bundle` of `snapshot` excluding everything reachable from `haves` (the
/// host's tips), written to a temporary file (§4.3). `haves` is filtered first to the commits
/// that exist locally (`git cat-file -e`): a tip the host has and this clone does not would
/// make `--not` fail the whole bundle.
public protocol BundleMaking: Sendable {
    func bundle(worktree: URL, snapshot: SnapshotRef, haves: [String]) async throws -> URL
}

/// Host: the per-controller workspace store (§4.1, §4.4–§4.7). `controller` is the paired
/// slot, so two controllers never share a store. Async throughout: every call shells out to
/// git, and `checkout` may wait a long time for a pool slot.
public protocol WorkspaceStore: Sendable {
    /// The commits this workspace already holds for `wtKey`, for the controller's `--not`.
    func tips(controller: UUID, repoRoot: String, wtKey: String) async throws -> [String]
    /// Fetches a received bundle into the store and records `ref` as the worktree's latest.
    func receive(controller: UUID, bundle: URL, ref: SnapshotRef) async throws
    /// Waits (suspends) for a free pool slot, locks it and applies `ref`
    /// (`checkout --force --detach`, `clean -fd`, never `-x`), then verifies the tree hash;
    /// throws `tree_mismatch` on a mismatch. `pin` holds the slot for a service's lifetime.
    func checkout(controller: UUID, ref: SnapshotRef, pin: Bool) async throws -> CheckoutLease
    /// `flightdeck exec`: a lease on the worktree's existing checkout, applying nothing.
    /// Throws `no_checkout` when this worktree has never been synced to this host.
    func existingCheckout(controller: UUID, repoRoot: String, wtKey: String) async throws -> CheckoutLease
    /// `service.sync`: re-applies `ref` in place to `lease`'s slot (same slot, verified as
    /// `checkout` is) and returns the lease that now describes it.
    func reapply(_ lease: CheckoutLease, ref: SnapshotRef) async throws -> CheckoutLease
    /// Gives a lease back, by `lease.id`. Slots are refcounted, because an `exec` lease and a
    /// service's pin may share one; the slot frees when its last lease is released. Releasing
    /// an id twice is a no-op, so a cleanup path that races exit cannot free someone else's.
    func release(_ lease: CheckoutLease) async
    /// Commits the run's non-ignored changes as a child of the snapshot under
    /// `refs/fd/results/<runID>`; nil when nothing changed.
    func resultCommit(lease: CheckoutLease, runID: String) async throws -> String?
    /// A bundle of that one result commit, for the controller to fetch; nil if none exists.
    func resultBundle(controller: UUID, repoRoot: String, runID: String) async throws -> URL?
    /// Tars the checkout's paths matching `globs` (relative to the checkout root) into
    /// `runs/<runID>/`, at exit and before the slot is released: the next run in the slot
    /// would otherwise overwrite them before the controller asks. Nil when nothing matched.
    func captureArtifacts(lease: CheckoutLease, runID: String, globs: [String]) async throws -> URL?
    /// The tar `captureArtifacts` stored for `runID`, for `run.artifacts`; nil if none.
    func storedArtifacts(runID: String) -> URL?
    /// Disk used per checkout, for `host ls --disk` (§4.7).
    func usage(controller: UUID) async throws -> [WorkspaceUsage]
    /// Deletes this controller's checkouts and object stores, or one repo's when `repoRoot`
    /// is given (`host prune`, §4.7).
    func prune(controller: UUID, repoRoot: String?) async throws
}

/// A locked checkout slot. Not `Codable`: it names a host-local path and never crosses the wire.
public struct CheckoutLease: Sendable, Equatable {
    /// Identifies this lease rather than the slot: a slot can be leased more than once (an
    /// `exec` beside a service), and `release` must give back exactly this one.
    public let id: UUID
    /// The innermost checkout directory, `…/checkouts/<wt-key>-<slot>/<worktreeName>/`.
    public let path: URL
    public let slot: Int
    public let ref: SnapshotRef

    public init(id: UUID, path: URL, slot: Int, ref: SnapshotRef) {
        self.id = id
        self.path = path
        self.slot = slot
        self.ref = ref
    }
}

/// One checkout's disk use, for `host ls --disk`.
public struct WorkspaceUsage: Codable, Sendable, Equatable {
    public let repoRoot: String
    public let worktreeName: String
    public let bytes: Int64

    public init(repoRoot: String, worktreeName: String, bytes: Int64) {
        self.repoRoot = repoRoot
        self.worktreeName = worktreeName
        self.bytes = bytes
    }

    enum CodingKeys: String, CodingKey {
        case repoRoot = "repoRoot"
        case worktreeName = "worktreeName"
        case bytes = "bytes"
    }
}
