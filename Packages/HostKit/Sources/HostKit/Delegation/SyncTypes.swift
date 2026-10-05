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
}

/// Controller: commits the worktree's current state (tracked, untracked-not-ignored, and each
/// `include` path) through a temporary `GIT_INDEX_FILE`, never touching the user's index,
/// stash, reflog or branches (§4.2). Throws for an LFS repo.
public protocol SnapshotMaking: Sendable {
    func snapshot(worktree: URL, include: [String]) throws -> SnapshotRef
}

/// Controller: a `git bundle` of `snapshot` excluding everything reachable from `haves` (the
/// host's tips that the controller also has), written to a temporary file (§4.3).
public protocol BundleMaking: Sendable {
    func bundle(worktree: URL, snapshot: SnapshotRef, haves: [String]) throws -> URL
}

/// Host: the per-controller workspace store (§4.1, §4.4–§4.7). `controller` is the paired
/// slot, so two controllers never share a store.
public protocol WorkspaceStore: Sendable {
    /// The commits this workspace already holds for `wtKey`, for the controller's `--not`.
    func tips(controller: UUID, repoRoot: String, wtKey: String) throws -> [String]
    /// Fetches a received bundle into the store and records `ref` as the worktree's latest.
    func receive(controller: UUID, bundle: URL, ref: SnapshotRef) throws
    /// Locks a pool slot and applies `ref` to it (`checkout --force --detach`, `clean -fd`,
    /// never `-x`), then verifies the tree hash; throws on a mismatch. `pin` holds the slot
    /// for a service's lifetime.
    func checkout(controller: UUID, ref: SnapshotRef, pin: Bool) throws -> CheckoutLease
    /// Commits the run's non-ignored changes as a child of the snapshot under
    /// `refs/fd/results/<runID>`; nil when nothing changed.
    func resultCommit(lease: CheckoutLease, runID: String) throws -> String?
    /// A bundle of that one result commit, for the controller to fetch; nil if none exists.
    func resultBundle(controller: UUID, repoRoot: String, runID: String) throws -> URL?
    /// A tar of the checkout's paths matching `globs`, relative to the checkout root; nil
    /// when nothing matched.
    func artifacts(lease: CheckoutLease, globs: [String]) throws -> URL?
}

/// A locked checkout slot. Not `Codable`: it names a host-local path and never crosses the wire.
public struct CheckoutLease: Sendable, Equatable {
    /// The innermost checkout directory, `…/checkouts/<wt-key>-<slot>/<worktreeName>/`.
    public let path: URL
    public let slot: Int
    public let ref: SnapshotRef

    public init(path: URL, slot: Int, ref: SnapshotRef) {
        self.path = path
        self.slot = slot
        self.ref = ref
    }
}
