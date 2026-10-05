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
/// Every path comes from the host, so none is trusted: an absolute path, a `.`, `..` or
/// `.git` component, or a parent directory that is a symlink refuses the whole apply before
/// anything is written.
///
/// Uses `merge-tree --write-tree --merge-base`, which needs git 2.40 or later.
public struct ResultApplier: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// Fully applied; the pending result is dropped.
        case clean
        /// Applied except these paths, which carry conflict markers or were left alone because
        /// the local file changed under the apply. The pending result is kept for another try.
        case conflicts([String])
        /// No pending result for the run, or it is already fully applied.
        case nothing
    }

    private let git: GitRunner
    /// Test seam: runs after the merge is computed and before the first write, where a
    /// concurrent save by the user lands in real life.
    private let beforeWrite: (@Sendable () -> Void)?

    public init(git: GitRunner = GitRunner()) {
        self.git = git
        self.beforeWrite = nil
    }

    init(git: GitRunner = GitRunner(), beforeWrite: (@Sendable () -> Void)?) {
        self.git = git
        self.beforeWrite = beforeWrite
    }

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
                         "+\(head[head.index(after: space)...]):\(Self.ref(runID))"], in: worktree,
                        timeout: GitRunner.longTimeout)
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

    /// Drops the pending result (when the user declines it). A no-op when there is none.
    public func discard(worktree: URL, runID: String) async throws {
        let runID = try SyncName.validate(runID)
        try await GitRunner.offload { [git] in
            guard (try? git.text(["rev-parse", "-q", "--verify", Self.ref(runID)], in: worktree)) != nil else { return }
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
        var conflicts = Set(merged.status == 1 ? Array(fields.dropFirst().prefix { !$0.isEmpty }) : [])

        let changes = try git.fields(["diff-tree", "-r", "-z", "--no-renames", "--name-status", oursTree, mergedTree], in: top)
        let pairs = stride(from: 0, to: changes.count - 1, by: 2).map { (status: changes[$0], path: changes[$0 + 1]) }
        let realTop = top.resolvingSymlinksInPath()
        for (_, path) in pairs { try Self.checkSafe(path, under: realTop) }
        let before = try entries(of: oursTree, paths: pairs.map(\.path), in: top)

        beforeWrite?()
        for (status, path) in pairs {
            let file = top.appendingPathComponent(path)
            // The file must still be what "ours" recorded, or the user saved it after the merge
            // was computed: writing now would throw that save away.
            guard try isUnchanged(file, path: path, since: before[path], in: top) else {
                conflicts.insert(path)
                continue
            }
            if status == "D" {
                try? FileManager.default.removeItem(at: file)
            } else {
                try write(path, from: mergedTree, to: file, in: top)
            }
        }
        if mergedTree == oursTree && conflicts.isEmpty {
            try git.run(["update-ref", "-d", Self.ref(runID)], in: top)
            return .nothing
        }
        guard conflicts.isEmpty else { return .conflicts(conflicts.sorted()) }
        try git.run(["update-ref", "-d", Self.ref(runID)], in: top)
        return .clean
    }

    /// Refuses a host-supplied path that could write outside the worktree or into git's own
    /// files: absolute, a `.`/`..`/`.git` component (any case: macOS's file system folds it),
    /// or an existing parent that is a symlink, which would carry the write wherever it points.
    static func checkSafe(_ path: String, under top: URL) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.lowercased() == ".git" })
        else { throw SyncError.unsafePath(path) }
        var dir = top
        let fm = FileManager.default
        for part in parts.dropLast() {
            dir = dir.appendingPathComponent(part)
            guard let type = (try? fm.attributesOfItem(atPath: dir.path))?[.type] as? FileAttributeType else { break }
            if type == .typeSymbolicLink { throw SyncError.unsafePath(path) }
        }
    }

    /// `path -> (mode, object id)` in `tree`, for the given paths.
    private func entries(of tree: String, paths: [String], in top: URL) throws -> [String: (mode: String, id: String)] {
        guard !paths.isEmpty else { return [:] }
        let rows = try git.fields(["ls-tree", "-r", "-z", "--full-tree", tree, "--"] + paths.map { ":(literal)\($0)" }, in: top)
        var out: [String: (mode: String, id: String)] = [:]
        for row in rows {
            let halves = row.split(separator: "\t", maxSplits: 1)
            let meta = halves.first?.split(separator: " ") ?? []
            guard halves.count == 2, meta.count == 3 else { continue }
            out[String(halves[1])] = (String(meta[0]), String(meta[2]))
        }
        return out
    }

    /// Whether the file on disk is still what "ours" recorded for it (absent, when ours had no
    /// entry). Hashed with the path's clean filters, the way `add` saw it.
    private func isUnchanged(_ file: URL, path: String, since entry: (mode: String, id: String)?, in top: URL) throws -> Bool {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: file.path)
        guard let entry else { return attrs == nil }
        guard let attrs else { return false }
        if entry.mode == "120000" {
            guard attrs[.type] as? FileAttributeType == .typeSymbolicLink,
                  let target = try? fm.destinationOfSymbolicLink(atPath: file.path) else { return false }
            return try git.text(["hash-object", "--stdin"], in: top, input: Data(target.utf8)) == entry.id
        }
        return try git.text(["hash-object", "--path=\(path)", file.path], in: top) == entry.id
    }

    /// Writes one blob from `tree` to `file` as a checkout would: through the path's smudge
    /// and eol filters, with git's two modes (executable bit and symlink). A gitlink is
    /// skipped: submodules are refused at snapshot time anyway.
    private func write(_ path: String, from tree: String, to file: URL, in top: URL) throws {
        guard let entry = try entries(of: tree, paths: [path], in: top)[path] else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: file)
        if entry.mode == "120000" {
            let target = try git.run(["cat-file", "blob", entry.id], in: top).stdout
            try fm.createSymbolicLink(atPath: file.path, withDestinationPath: String(decoding: target, as: UTF8.self))
        } else if entry.mode.hasPrefix("100") {
            let data = try git.run(["cat-file", "--filters", "--path=\(path)", entry.id], in: top).stdout
            try data.write(to: file)
            try fm.setAttributes([.posixPermissions: entry.mode == "100755" ? 0o755 : 0o644], ofItemAtPath: file.path)
        }
    }
}
