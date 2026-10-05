import Foundation

/// Controller: commits a worktree's current state for delegation (spec §4.2).
///
/// The commit is built in a temporary `GIT_INDEX_FILE`: seeded from `HEAD`, then `add -A`
/// (which honors `.gitignore`), then `add -f` for each include. The user's index, stash,
/// reflog and branches are never written. The snapshot is kept under
/// `refs/flightdeck/snapshots/<host>/<n>`, the last K of them, so `gc` cannot prune an object
/// a host still needs to be sent as a delta base.
///
/// The commit is deterministic: a fixed identity, and author and committer dates taken from
/// `HEAD`. The same `HEAD` with the same files gives the same commit, so a re-run of unchanged
/// code shares the host's checkout slot instead of taking another one (§4.6).
public struct Snapshotter: SnapshotMaking {
    public let keep: Int
    private let git: GitRunner

    public init(keep: Int = 5, git: GitRunner = GitRunner()) {
        self.keep = keep
        self.git = git
    }

    public func snapshot(worktree: URL, host: String, include: [String]) async throws -> SnapshotRef {
        try await GitRunner.offload { [self] in try make(worktree: worktree, host: host, include: include) }
    }

    /// A stable key for an absolute worktree path: FNV-1a 64 in hex. Foundation-only (no
    /// CryptoKit in HostKit), and collision resistance is not a security property here: a
    /// collision only makes two of one controller's worktrees share host checkouts.
    public static func wtKey(forPath path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    func make(worktree: URL, host: String, include: [String]) throws -> SnapshotRef {
        let top = URL(fileURLWithPath: try git.text(["rev-parse", "--show-toplevel"], in: worktree))
        guard let head = try? git.text(["rev-parse", "--verify", "-q", "HEAD^{commit}"], in: top), !head.isEmpty else {
            throw SyncError.unbornHead
        }
        let gitDir = URL(fileURLWithPath: try git.text(["rev-parse", "--absolute-git-dir"], in: top))
        let index = try TempIndex(git: git, top: top, dir: gitDir, seed: head)
        defer { index.remove() }

        try git.run(["add", "-A"], in: top, env: index.env)
        let includes = include.filter { FileManager.default.fileExists(atPath: top.appendingPathComponent($0).path) }
        if !includes.isEmpty {
            try git.run(["add", "-f", "--"] + includes, in: top, env: index.env)
        }
        try refuseUnsupported(top: top, env: index.env)

        let tree = try git.text(["write-tree"], in: top, env: index.env)
        let date = try git.text(["show", "-s", "--format=%ct", head], in: top)
        let commit = try git.text(["commit-tree", tree, "-p", head, "-m", "flightdeck snapshot"], in: top,
                                  env: ["GIT_AUTHOR_DATE": "@\(date) +0000", "GIT_COMMITTER_DATE": "@\(date) +0000"])
        try record(commit, host: host, in: top)

        return SnapshotRef(repoRoot: try rootCommit(top: top), wtKey: Self.wtKey(forPath: top.path),
                           worktreeName: top.lastPathComponent, commit: commit, tree: tree)
    }

    /// Refuses what v1 cannot reproduce on the host, before anything is recorded. LFS (§4.2.5):
    /// the host would check out pointer files and run against them. Submodules (amendment A1):
    /// the host has no store to resolve the gitlink from, so the directory would arrive empty.
    private func refuseUnsupported(top: URL, env: [String: String]) throws {
        let staged = try git.fields(["ls-files", "-s", "-z"], in: top, env: env)
        if staged.contains(where: { $0.hasPrefix("160000 ") }) { throw SyncError.submodulesUnsupported }

        let paths = staged.compactMap { $0.split(separator: "\t", maxSplits: 1).last.map(String.init) }
        guard !paths.isEmpty else { return }
        let input = Data(paths.joined(separator: "\0").utf8 + [0])
        let attrs = try git.fields(["check-attr", "-z", "--stdin", "filter"], in: top, env: env, input: input)
        // -z output is path, attribute, value triples.
        if stride(from: 2, to: attrs.count, by: 3).contains(where: { attrs[$0] == "lfs" }) {
            throw SyncError.lfsUnsupported
        }
    }

    /// Keeps `commit` under the next `refs/flightdeck/snapshots/<host>/<n>` and trims to K.
    /// The create is conditional on the ref not existing, so two agents snapshotting the same
    /// repo at once cannot both claim `<n>` and silently drop one snapshot's protection.
    private func record(_ commit: String, host: String, in top: URL) throws {
        let prefix = "refs/flightdeck/snapshots/\(Self.refComponent(host))/"
        for _ in 0..<5 {
            let numbers = try git.text(["for-each-ref", "--format=%(refname)", prefix], in: top)
                .split(separator: "\n").compactMap { Int($0.dropFirst(prefix.count)) }.sorted()
            let next = (numbers.last ?? 0) + 1
            guard (try? git.run(["update-ref", "\(prefix)\(next)", commit, ""], in: top)) != nil else { continue }
            let stale = (numbers + [next]).dropLast(keep)
            if !stale.isEmpty {
                let script = stale.map { "delete \(prefix)\($0)\n" }.joined()
                try git.run(["update-ref", "--stdin"], in: top, input: Data(script.utf8))
            }
            return
        }
        throw GitError.failed(args: ["update-ref", prefix], status: 1, stderr: "snapshot ref kept changing under us")
    }

    /// The repo's oldest root commit (§4.1): a repo with several roots (a merged-in history)
    /// must name the same store from every clone, whichever root `rev-list` happens to list first.
    private func rootCommit(top: URL) throws -> String {
        let roots = try git.text(["rev-list", "--max-parents=0", "--timestamp", "HEAD"], in: top)
            .split(separator: "\n").compactMap { line -> (Int, String)? in
                let parts = line.split(separator: " ")
                guard parts.count == 2, let ts = Int(parts[0]) else { return nil }
                return (ts, String(parts[1]))
            }
        return roots.min { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }!.1
    }

    /// A host's display name as one ref component: anything git would refuse becomes `-`.
    static func refComponent(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let cleaned = String(name.map { allowed.contains($0) ? $0 : "-" })
        return cleaned.isEmpty ? "host" : cleaned
    }
}

/// A temporary index file, seeded from a tree, used to build a commit without touching the
/// user's own index.
///
/// Seeding with a plain `read-tree` throws away every stat entry, so the following `add -A`
/// re-hashes every file in the repo on every run. Instead the real index is copied and
/// `read-tree -m` keeps its stat data wherever the content matches. That copy also carries
/// `assume-unchanged` and `skip-worktree` bits, which would make `add -A` skip a file's real
/// edit, and a conflicted index refuses `-m` outright; either case falls back to the slow seed.
struct TempIndex {
    let url: URL
    private let git: GitRunner
    var env: [String: String] { ["GIT_INDEX_FILE": url.path] }

    init(git: GitRunner, top: URL, dir: URL, seed treeish: String) throws {
        self.git = git
        self.url = dir.appendingPathComponent("flightdeck-\(UUID().uuidString).index")
        let fm = FileManager.default
        let real = try git.text(["rev-parse", "--git-path", "index"], in: top)
        let realURL = real.hasPrefix("/") ? URL(fileURLWithPath: real) : top.appendingPathComponent(real)
        if fm.fileExists(atPath: realURL.path), (try? fm.copyItem(at: realURL, to: url)) != nil,
           Self.keepRacyCheck(of: realURL, on: url),
           (try? git.run(["read-tree", "-m", treeish], in: top, env: env)) != nil,
           let tags = try? git.fields(["ls-files", "-v", "-z"], in: top, env: env),
           !tags.contains(where: { $0.first.map { $0.isLowercase || $0 == "S" } ?? false }) {
            return
        }
        remove()
        try git.run(["read-tree", treeish], in: top, env: env)
    }

    /// Gives the copy the original's mtime, backdated a second. git trusts an entry's stat
    /// only when the entry is older than the index file; a same-size edit made in the same
    /// second as the last index write is caught solely by that "racy" check. A copy stamped
    /// *now* (Linux's `copyItem` does not keep mtimes) makes every entry look older, and the
    /// snapshot silently ships the file's previous content. Backdating can only make more
    /// entries racy, which costs a re-hash, never correctness.
    private static func keepRacyCheck(of original: URL, on copy: URL) -> Bool {
        let fm = FileManager.default
        guard let mtime = (try? fm.attributesOfItem(atPath: original.path))?[.modificationDate] as? Date else { return false }
        return (try? fm.setAttributes([.modificationDate: mtime.addingTimeInterval(-1)], ofItemAtPath: copy.path)) != nil
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + ".lock")
    }
}
