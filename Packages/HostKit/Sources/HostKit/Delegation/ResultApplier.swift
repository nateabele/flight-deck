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
    ///
    /// Unbundled by hand rather than with `git fetch`: the pack goes through
    /// `index-pack --strict`, so git validates every object the host sent (duplicate tree
    /// entries, `.git` in any case or HFS/NTFS spelling, `..`) before any of it is stored, a
    /// second wall in front of the path checks `apply` makes on its own. `fetch.fsckObjects`
    /// would say the same, but git ignores it for bundles before 2.46, and the Linux image ships
    /// 2.43 (verified: a `.GIT` tree was accepted there).
    public func fetch(bundle: URL, worktree: URL, runID: String) async throws -> String {
        let runID = try SyncName.validate(runID)
        return try await GitRunner.offload { [git] in
            let data = try Data(contentsOf: bundle, options: .mappedIfSafe)
            guard let end = data.range(of: Data("\n\n".utf8)) else { throw SyncError.bundleLacksSnapshot(runID) }
            let header = String(decoding: data[..<end.lowerBound], as: UTF8.self).split(separator: "\n")
            guard let signature = header.first, signature.hasPrefix("# v2 git bundle") || signature.hasPrefix("# v3 git bundle"),
                  let head = header.dropFirst().first(where: { !$0.hasPrefix("-") && !$0.hasPrefix("@") }),
                  let commit = head.split(separator: " ").first.flatMap({ try? SyncName.objectID(String($0)) })
            else { throw SyncError.bundleLacksSnapshot(runID) }
            try git.run(["-c", "core.protectHFS=true", "-c", "core.protectNTFS=true",
                         "index-pack", "--stdin", "--strict", "--fix-thin"], in: worktree,
                        input: Data(data[end.upperBound...]), timeout: GitRunner.longTimeout)
            try git.run(["cat-file", "-e", "\(commit)^{commit}"], in: worktree)
            try git.run(["update-ref", Self.ref(runID), commit], in: worktree)
            return commit
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

        let changes = try Self.changes(try git.run(["diff-tree", "-r", "-z", "--no-renames", "--raw", oursTree, mergedTree], in: top).stdout)
        let realTop = top.resolvingSymlinksInPath()

        // Every check runs before the first write, so a refusal never leaves a partial apply.
        for change in changes { try Self.checkSafe(change.path, under: realTop) }
        try Self.refuseFoldingCollisions(changes)
        var skip = Set<String>()
        var seen: [String: FileSignature?] = [:]
        // Directories the result turns into a file or symlink (`d/` -> `d -> a.txt`): their
        // tracked contents are deleted by this same result, so they may be replaced, but only
        // if nothing else (an ignored build product, say) is left in them by then.
        var replacing = Set<String>()
        let current = try currentIDs(changes, in: top)
        for change in changes {
            let signature = FileSignature(of: top.appendingPathComponent(change.path))
            seen[change.path] = signature
            // The file must still be what "ours" recorded: a save after "ours" was taken would
            // otherwise be thrown away. Absent in ours means it must be absent on disk too (an
            // ignored local file sits there, and is not ours to replace).
            if change.oldMode == Self.absent {
                if signature?.type == .typeDirectory && change.newMode != Self.absent {
                    replacing.insert(change.path)
                } else if signature != nil {
                    skip.insert(change.path)
                }
            } else if current[change.path] != change.oldID {
                skip.insert(change.path)
            }
        }
        let staging = try stage(changes.filter { !skip.contains($0.path) && $0.status != "D" }, of: mergedTree, gitDir: gitDir, in: top)
        defer { try? FileManager.default.removeItem(at: staging) }

        beforeWrite?()
        // Deletions first, so a directory being replaced is empty by the time its replacement
        // is written, and no parent walk mistakes a just-written symlink for an attack.
        let ordered = changes.filter { $0.status == "D" } + changes.filter { $0.status != "D" }
        let fm = FileManager.default
        for change in ordered where !skip.contains(change.path) {
            let file = top.appendingPathComponent(change.path)
            // Again, at the last moment: a symlink made since the checks above (by the user, or
            // by a write earlier in this loop on a case- or normalization-folding file system)
            // must not carry this write out of the worktree.
            try Self.checkSafe(change.path, under: realTop)
            if replacing.contains(change.path) {
                let leftovers = (try? fm.contentsOfDirectory(atPath: file.path)) ?? []
                guard leftovers.isEmpty else {
                    skip.insert(change.path)
                    continue
                }
                try? fm.removeItem(at: file)
            } else if FileSignature(of: file) != seen[change.path] ?? nil {
                skip.insert(change.path)
                continue
            }
            if change.status == "D" {
                try? fm.removeItem(at: file)
                Self.removeEmptyParents(of: file, below: top)
                continue
            }
            let staged = staging.appendingPathComponent(change.path)
            guard (try? fm.attributesOfItem(atPath: staged.path)) != nil else {
                // Only a gitlink legitimately stages nothing. Anything else missing lost a
                // collision in staging (on APFS, `Notes/bar` and `notes` from a case-sensitive
                // host are one entry): report it and keep the result, never drop it silently.
                if change.newMode != "160000" { skip.insert(change.path) }
                continue
            }
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: file)
            try fm.moveItem(at: staged, to: file)
        }
        conflicts.formUnion(skip)
        if mergedTree == oursTree && conflicts.isEmpty {
            try git.run(["update-ref", "-d", Self.ref(runID)], in: top)
            return .nothing
        }
        guard conflicts.isEmpty else { return .conflicts(conflicts.sorted()) }
        try git.run(["update-ref", "-d", Self.ref(runID)], in: top)
        return .clean
    }

    private static let absent = "000000"

    /// One changed path, both sides, from `diff-tree --raw -z`.
    struct Change {
        let oldMode: String, newMode: String, oldID: String, newID: String, status: String, path: String
    }

    /// Parses `:<old mode> <new mode> <old id> <new id> <status>` NUL `<path>` NUL pairs.
    static func changes(_ raw: Data) -> [Change] {
        let fields = raw.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        return stride(from: 0, to: fields.count - 1, by: 2).compactMap { i in
            let meta = fields[i].dropFirst().split(separator: " ")
            guard fields[i].hasPrefix(":"), meta.count == 5 else { return nil }
            return Change(oldMode: String(meta[0]), newMode: String(meta[1]), oldID: String(meta[2]),
                          newID: String(meta[3]), status: String(meta[4].prefix(1)), path: fields[i + 1])
        }
    }

    /// Refuses a result that writes a symlink whose name, case-folded and NFC-normalised,
    /// equals another path in the result or one of its leading directories. On APFS (and any
    /// case- or normalization-insensitive file system) `A` and `a`, or NFC and NFD `café`, are
    /// one directory entry: writing `A -> .git` first and then `a/hooks/pre-commit` plants a
    /// git hook, even though every name passes the per-path checks.
    ///
    /// The folding here is full Unicode case folding on the NFC form, which catches final sigma,
    /// sharp s and ligatures that `lowercased()` misses. It is still not APFS's own table, so it
    /// is the early, whole-result refusal; the real guard is the `lstat` parent walk repeated
    /// before every write, which asks the file system itself. Deleted paths are left out: a
    /// result that replaces `d/` with `d -> a.txt` deletes `d/…`, it does not write beneath it.
    static func refuseFoldingCollisions(_ changes: [Change]) throws {
        func fold(_ path: String) -> String {
            path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
                .precomposedStringWithCanonicalMapping
        }
        let links = changes.filter { $0.newMode == "120000" }
        guard !links.isEmpty else { return }
        let folded = changes.filter { $0.newMode != absent }.map { (path: $0.path, key: fold($0.path)) }
        for link in links {
            let key = fold(link.path)
            if let other = folded.first(where: { $0.path != link.path && ($0.key == key || $0.key.hasPrefix(key + "/")) }) {
                throw SyncError.unsafePath(other.path)
            }
        }
    }

    /// The object id of each changed path's file *on disk*, hashed as `add` would hash it
    /// (through its clean filters), in one `hash-object --stdin-paths` for regular files.
    /// A path whose disk entry is missing or of another kind gets no id, which reads as changed.
    private func currentIDs(_ changes: [Change], in top: URL) throws -> [String: String] {
        let fm = FileManager.default
        var regular: [String] = []
        var ids: [String: String] = [:]
        for change in changes where change.oldMode != Self.absent {
            let file = top.appendingPathComponent(change.path)
            let type = (try? fm.attributesOfItem(atPath: file.path))?[.type] as? FileAttributeType
            if change.oldMode == "120000" {
                guard type == .typeSymbolicLink, let target = try? fm.destinationOfSymbolicLink(atPath: file.path) else { continue }
                ids[change.path] = try? git.text(["hash-object", "--stdin"], in: top, input: Data(target.utf8))
            } else if type == .typeRegular {
                regular.append(change.path)
            }
        }
        guard !regular.isEmpty else { return ids }
        // Paths are newline-separated here; `checkSafe` has already refused any containing one.
        let lines = regular.map(Self.stdinPathLine).joined(separator: "\n") + "\n"
        let hashed = try git.text(["hash-object", "--stdin-paths"], in: top, input: Data(lines.utf8))
            .split(separator: "\n").map(String.init)
        for (path, id) in zip(regular, hashed) { ids[path] = id }
        return ids
    }

    /// One path as a `--stdin-paths` line. git C-unquotes a line that starts with `"` and drops
    /// a trailing CR, so such a name is sent C-quoted; any other name goes verbatim. Unquoted,
    /// a tracked `"odd` failed the whole apply ("badly quoted") and `cr<CR>` hashed `cr`.
    static func stdinPathLine(_ path: String) -> String {
        guard path.hasPrefix("\"") || path.contains("\r") else { return path }
        var quoted = "\""
        for byte in path.utf8 {
            switch byte {
            case UInt8(ascii: "\""): quoted += "\\\""
            case UInt8(ascii: "\\"): quoted += "\\\\"
            case 0x0d: quoted += "\\r"
            case 0x09: quoted += "\\t"
            case 0..<0x20, 0x7f, 0x80...: quoted += String(format: "\\%03o", byte)
            default: quoted += String(UnicodeScalar(byte))
            }
        }
        return quoted + "\""
    }

    /// After a deletion, removes the parent directories it left empty, as a checkout does,
    /// stopping at the worktree root.
    static func removeEmptyParents(of file: URL, below top: URL) {
        let fm = FileManager.default
        var dir = file.deletingLastPathComponent().standardizedFileURL
        let root = top.standardizedFileURL.path
        while dir.path.count > root.count, dir.path.hasPrefix(root + "/"),
              (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
            try? fm.removeItem(at: dir)
            dir = dir.deletingLastPathComponent()
        }
    }

    /// Writes every file to be applied into a staging directory exactly as a checkout would
    /// (smudge and eol filters, executable bit, symlinks), in one `checkout-index` fed the
    /// paths on stdin, so no path list ever reaches a command line. The staging directory is
    /// inside the git dir, on the worktree's volume, so each file then moves into place with an
    /// atomic rename. `checkout-index` runs git's own path checks as well, a second guard
    /// behind `checkSafe`. (`cat-file --batch --filters` cannot do this: its header reports
    /// the unfiltered size, so a filtered body cannot be framed.)
    private func stage(_ changes: [Change], of tree: String, gitDir: URL, in top: URL) throws -> URL {
        let staging = gitDir.appendingPathComponent("flightdeck-apply-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        guard !changes.isEmpty else { return staging }
        let index = staging.appendingPathExtension("index")
        defer { try? FileManager.default.removeItem(at: index) }
        let env = ["GIT_INDEX_FILE": index.path]
        try git.run(["read-tree", tree], in: top, env: env)
        let paths = Data(changes.map(\.path).joined(separator: "\0").utf8 + [0])
        try git.run(["checkout-index", "-f", "-z", "--stdin", "--prefix=\(staging.path)/"], in: top, env: env, input: paths,
                    timeout: GitRunner.longTimeout)
        return staging
    }

    /// Refuses a host-supplied path that could write outside the worktree or into git's own
    /// files: absolute, a `.`/`..`/`.git` component (any case: macOS's file system folds it),
    /// or an existing parent that is a symlink (checked with `lstat`, component by component),
    /// which would carry the write wherever it points. A newline is refused too: the batched
    /// git calls take paths one per line.
    static func checkSafe(_ path: String, under top: URL) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.hasPrefix("/"), !path.contains("\n"),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.lowercased() == ".git" })
        else { throw SyncError.unsafePath(path) }
        var dir = top
        let fm = FileManager.default
        for part in parts.dropLast() {
            dir = dir.appendingPathComponent(part)
            guard let type = (try? fm.attributesOfItem(atPath: dir.path))?[.type] as? FileAttributeType else { break }
            if type == .typeSymbolicLink { throw SyncError.unsafePath(path) }
        }
    }

}

/// What `lstat` says about a path, to notice it changing between the checks and the write.
/// nil (at the call sites) means nothing is there.
struct FileSignature: Equatable {
    let type: FileAttributeType?
    let size: Int64?
    let modified: Date?
    let inode: Int?

    init?(of url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        type = attrs[.type] as? FileAttributeType
        size = (attrs[.size] as? NSNumber)?.int64Value
        modified = attrs[.modificationDate] as? Date
        inode = (attrs[.systemFileNumber] as? NSNumber)?.intValue
    }
}
