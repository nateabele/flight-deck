import Foundation

/// Controller: a `git bundle` of a snapshot minus everything the host already has (spec §4.3).
///
/// `haves` are the host's tips. Only those that exist locally are usable as `--not` (a tip
/// from another clone, or a commit this repo has since gc'd, would make `bundle create` fail),
/// so they are filtered first. On a first sync nothing survives the filter and the bundle is the
/// full history. On the same `HEAD` the previous snapshot is a have and only the working-copy
/// delta is sent. After a rebase git finds the merge-base itself.
public struct BundleMaker: BundleMaking {
    private let git: GitRunner

    public init(git: GitRunner = GitRunner()) { self.git = git }

    /// The bundle is written to a fresh temporary file that the caller streams and then deletes.
    public func bundle(worktree: URL, snapshot: SnapshotRef, haves: [String]) async throws -> URL {
        try await GitRunner.offload { [self] in try make(worktree: worktree, snapshot: snapshot, haves: haves) }
    }

    private func make(worktree: URL, snapshot: SnapshotRef, haves: [String]) throws -> URL {
        let commit = try SyncName.objectID(snapshot.commit)
        let present = try presentCommits(haves.filter { $0 != commit }, in: worktree)

        // `bundle create` records refs, not bare ids ("Refusing to create empty bundle"), so it
        // needs a ref at the snapshot: the Snapshotter's own, or a temporary one.
        let existing = try git.text(["for-each-ref", "--points-at", commit, "--format=%(refname)", "refs/flightdeck/snapshots/"],
                                    in: worktree).split(separator: "\n").first.map(String.init)
        let ref = existing ?? "refs/flightdeck/bundle/\(commit)"
        if existing == nil { try git.run(["update-ref", ref, commit], in: worktree) }
        defer { if existing == nil { _ = try? git.run(["update-ref", "-d", ref], in: worktree) } }

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("fd-\(UUID().uuidString).bundle")
        // The revisions go on stdin: the host's tips grow with every worktree it has seen, and
        // one argv per tip would eventually trip NSTask's argument limit (an uncatchable abort).
        let revs = ([ref] + present.map { "^\($0)" }).joined(separator: "\n") + "\n"
        try git.run(["bundle", "create", "-q", out.path, "--stdin"], in: worktree, input: Data(revs.utf8),
                    timeout: GitRunner.longTimeout)
        return out
    }

    /// The subset of `ids` that name commits in this repository, in one `cat-file` call.
    private func presentCommits(_ ids: [String], in worktree: URL) throws -> [String] {
        let wellFormed = ids.filter { (try? SyncName.objectID($0)) != nil }
        guard !wellFormed.isEmpty else { return [] }
        let input = Data(wellFormed.map { "\($0)^{commit}\n" }.joined().utf8)
        let lines = try git.text(["cat-file", "--batch-check=%(objectname) %(objecttype)"], in: worktree, input: input)
            .split(separator: "\n")
        return lines.compactMap { line in
            let parts = line.split(separator: " ")
            return parts.count == 2 && parts[1] == "commit" ? String(parts[0]) : nil
        }
    }
}
