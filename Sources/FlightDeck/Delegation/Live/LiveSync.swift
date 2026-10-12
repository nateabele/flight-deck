import Foundation
import HostKit

/// C2's `Snapshotter` with its failures worded as delegation's 125 lines. Without this a
/// refusal such as LFS reaches the CLI as `delegation_failed` with the bare description, and
/// a script that keys on `lfs_unsupported` never sees the code.
struct LiveSnapshotter: SnapshotMaking {
    var base = Snapshotter()

    func snapshot(worktree: URL, host: String, include: [String]) async throws -> SnapshotRef {
        do { return try await base.snapshot(worktree: worktree, host: host, include: include) } catch {
            throw LiveGitFailure.delegationError(error, doing: "snapshot \(worktree.lastPathComponent) for \(host)")
        }
    }
}

/// C2's `BundleMaker`, its failures worded the same way.
struct LiveBundleMaker: BundleMaking {
    var base = BundleMaker()

    func bundle(worktree: URL, snapshot: SnapshotRef, haves: [String]) async throws -> URL {
        do { return try await base.bundle(worktree: worktree, snapshot: snapshot, haves: haves) } catch {
            throw LiveGitFailure.delegationError(error, doing: "bundle \(worktree.lastPathComponent) for the host")
        }
    }
}

/// Controller-side git and sync failures as `DelegationError`s: `SyncError`'s code (A5) with
/// its description and the next step.
enum LiveGitFailure {
    static func delegationError(_ error: Error, doing what: String) -> Error {
        switch error {
        case let error as DelegationError:
            return error
        case is CancellationError:
            // The caller hung up; it must see that to stop, not a line nobody reads.
            return error
        case let sync as SyncError:
            return DelegationError(code: sync.code, message: "\(sync) — \(nextStep(sync))")
        case let git as GitError:
            return DelegationError(code: "git_failed", message: "couldn't \(what): \(git) — fix the repository, then rerun")
        default:
            return DelegationError(code: "delegation_failed", message: "couldn't \(what): \(error)")
        }
    }

    private static func nextStep(_ error: SyncError) -> String {
        switch error {
        case .lfsUnsupported: return "run it locally"
        // The description already names the submodule and the fix; this is the way around it.
        case .submodule: return "or run it locally"
        case .unbornHead: return "commit once, then rerun"
        case .gitTooOld: return "update git on this Mac, then rerun"
        case .unsafePath: return "check the run's changes on the host; nothing here was touched"
        case .resultExpired: return "rerun to get the changes again"
        case .artifactTracked: return "drop that fetch glob, then rerun"
        case .treeMismatch, .bundleLacksSnapshot, .invalidName, .noCheckout, .runActive:
            return "rerun; if it repeats, report it"
        }
    }
}

/// Blocking work (git, tar, the file system) on a global queue, so a caller on the main actor
/// awaits it without the UI stalling, and a burst of it never pins the cooperative pool.
func offloaded<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
    }
}
