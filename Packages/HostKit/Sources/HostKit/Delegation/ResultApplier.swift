import Foundation

/// Controller: brings a run's changed files home (spec §4.5).
///
/// The host's result commit is a child of the snapshot. `fetch` stores it as a pending result
/// under `refs/flightdeck/results/<runID>`; `patch` is what `flightdeck diff` shows; `apply`
/// three-way merges it into the worktree **as it is now**, with the snapshot as the base.
///
/// The user keeps editing while a run is in flight, so "now" is not the snapshot. A plain
/// checkout of the result would silently revert those edits. Instead the current worktree is
/// committed (through a temporary index, the same way a snapshot is), `git merge-tree` merges
/// that with the result, and only the paths where the merge differs from the current worktree
/// are written. A path both sides changed gets conflict markers; nothing is overwritten. The
/// user's index, branches and stash are never touched, so `git status` afterwards simply shows
/// the applied changes as unstaged edits.
///
/// Uses `merge-tree --write-tree --merge-base`, which needs git 2.40 or later.
public struct ResultApplier: Sendable {
    public enum Outcome: Sendable, Equatable {
        case clean
        /// Applied, but these paths carry conflict markers (or, for a path the result adds
        /// where an ignored local file already sits, were left alone).
        case conflicts([String])
        /// No pending result for the run, or it is already fully applied.
        case nothing
    }

    private let git: GitRunner

    public init(git: GitRunner = GitRunner()) { self.git = git }

    private static func ref(_ runID: String) -> String { "refs/flightdeck/results/\(runID)" }

    /// Fetches a host result bundle into the worktree's repository as the run's pending result
    /// and returns the result commit.
    public func fetch(bundle: URL, worktree: URL, runID: String) async throws -> String {
        let runID = try SyncName.validate(runID)
        return try await GitRunner.offload { [git] in
            let heads = try git.text(["bundle", "list-heads", bundle.path], in: worktree).split(separator: "\n")
            guard let head = heads.first, let space = head.firstIndex(of: " ") else {
                throw SyncError.bundleLacksSnapshot(runID)
            }
            try git.run(["fetch", "-q", "--no-tags", "--no-write-fetch-head", bundle.path,
                         "+\(head[head.index(after: space)...]):\(Self.ref(runID))"], in: worktree)
            return String(head[..<space])
        }
    }

    /// The pending result as a binary-safe patch against its snapshot; nil when there is none.
    public func patch(worktree: URL, runID: String) async throws -> String? {
        let runID = try SyncName.validate(runID)
        return try await GitRunner.offload { [git] () -> String? in
            guard let result = try? git.text(["rev-parse", "-q", "--verify", Self.ref(runID)], in: worktree) else { return nil }
            let out = try git.run(["diff", "--binary", "--no-color", "--no-ext-diff", "\(result)^", result], in: worktree)
            return String(decoding: out.stdout, as: UTF8.self)
        }
    }

    /// Drops the pending result (after an apply, or when the user declines it).
    public func discard(worktree: URL, runID: String) async throws {
        let runID = try SyncName.validate(runID)
        try await GitRunner.offload { [git] in
            _ = try git.run(["update-ref", "-d", Self.ref(runID)], in: worktree)
        }
    }

    public func apply(worktree: URL, runID: String) async throws -> Outcome {
        let runID = try SyncName.validate(runID)
        return try await GitRunner.offload { [self] in try merge(worktree: worktree, runID: runID) }
    }

    private func merge(worktree: URL, runID: String) throws -> Outcome {
        guard let result = try? git.text(["rev-parse", "-q", "--verify", Self.ref(runID)], in: worktree) else { return .nothing }
        let top = URL(fileURLWithPath: try git.text(["rev-parse", "--show-toplevel"], in: worktree))
        let base = try git.text(["rev-parse", "\(result)^"], in: top)

        // "Ours" is the current worktree seen from the snapshot: seeding from the base keeps an
        // included ignored file (one the snapshot force-added) in view, so a local edit to it
        // merges rather than being clobbered.
        let gitDir = URL(fileURLWithPath: try git.text(["rev-parse", "--absolute-git-dir"], in: top))
        let index = try TempIndex(git: git, top: top, dir: gitDir, seed: base)
        defer { index.remove() }
        try git.run(["add", "-A"], in: top, env: index.env)
        let oursTree = try git.text(["write-tree"], in: top, env: index.env)
        let ours = try git.text(["commit-tree", oursTree, "-p", base, "-m", "flightdeck: working tree"], in: top)

        // A ref, not a bare id, because merge-tree labels conflict markers with the names it was
        // given: `<<<<<<< refs/flightdeck/local/<run>` reads; a hash does not.
        let local = "refs/flightdeck/local/\(runID)"
        try git.run(["update-ref", local, ours], in: top)
        defer { _ = try? git.run(["update-ref", "-d", local], in: top) }
        let merged = try git.run(["merge-tree", "--write-tree", "-z", "--name-only", "--merge-base=\(base)", local, Self.ref(runID)],
                                 in: top, accept: [0, 1])
        // -z --name-only: <tree> NUL <conflicted path> NUL ... NUL NUL <messages>.
        let fields = merged.stdout.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        let mergedTree = fields[0]
        var conflicts = merged.status == 1 ? Array(fields.dropFirst().prefix { !$0.isEmpty }) : []
        guard mergedTree != oursTree else { return conflicts.isEmpty ? .nothing : .conflicts(Array(Set(conflicts)).sorted()) }

        let changes = try git.fields(["diff-tree", "-r", "-z", "--no-renames", "--name-status", oursTree, mergedTree], in: top)
        let fm = FileManager.default
        for i in stride(from: 0, to: changes.count - 1, by: 2) {
            let (status, path) = (changes[i], changes[i + 1])
            let file = top.appendingPathComponent(path)
            if status == "D" {
                try? fm.removeItem(at: file)
                continue
            }
            // An added path that already exists locally was not in "ours", so it is ignored
            // here: refuse to replace it and report it, rather than overwrite the user's file.
            if status == "A", (try? fm.attributesOfItem(atPath: file.path)) != nil {
                conflicts.append(path)
                continue
            }
            try write(path, from: mergedTree, to: file, in: top)
        }
        return conflicts.isEmpty ? .clean : .conflicts(Array(Set(conflicts)).sorted())
    }

    /// Writes one blob from `tree` to `file`, carrying git's two modes (executable bit and
    /// symlink). A gitlink is skipped: submodules are refused at snapshot time anyway.
    private func write(_ path: String, from tree: String, to file: URL, in top: URL) throws {
        let entry = try git.fields(["ls-tree", "-z", tree, "--", path], in: top).first ?? ""
        let meta = entry.split(separator: "\t", maxSplits: 1).first?.split(separator: " ") ?? []
        guard meta.count == 3, meta[1] == "blob" else { return }
        let mode = meta[0]
        let data = try git.run(["cat-file", "blob", String(meta[2])], in: top).stdout
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: file)
        if mode == "120000" {
            try fm.createSymbolicLink(atPath: file.path, withDestinationPath: String(decoding: data, as: UTF8.self))
        } else {
            try data.write(to: file)
            try fm.setAttributes([.posixPermissions: mode == "100755" ? 0o755 : 0o644], ofItemAtPath: file.path)
        }
    }
}
