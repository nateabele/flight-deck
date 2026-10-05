import Foundation
import HostKit

/// `ResultApplying` over C2's `ResultApplier` (spec §4.5), off the main actor.
///
/// `ResultApplier` keys a pending result by run under `refs/flightdeck/results/<run>`; the
/// seam hands over a bundle and the result commit instead. So each call fetches the bundle
/// under a key named for the commit, works on it, and drops the ref again: the bundle file
/// `DelegationService` keeps is the one record of a pending result, and a ref left behind
/// would outlive it in the user's repository.
struct LiveResultApplier: ResultApplying {
    var git = GitRunner()

    func patch(bundle: URL, commit: String, snapshot: SnapshotRef, worktree: URL) async throws -> String {
        let applier = ResultApplier(git: git)
        return try await withResult(bundle: bundle, commit: commit, worktree: worktree, doing: "diff the result") { key in
            try await applier.patch(worktree: worktree, runID: key) ?? ""
        }
    }

    func apply(bundle: URL, commit: String, snapshot: SnapshotRef, worktree: URL,
               allowConflicts: Bool) async throws -> ApplyOutcome {
        let applier = ResultApplier(git: git)
        let git = git
        return try await withResult(bundle: bundle, commit: commit, worktree: worktree, doing: "apply the result") { key in
            // `apply = "auto"` must write nothing when the merge would conflict, and
            // `ResultApplier.apply` always writes, markers included; so the same merge is
            // computed first without touching the worktree.
            if !allowConflicts {
                let conflicts = try await offloaded { try Self.wouldConflict(commit: commit, worktree: worktree, git: git) }
                if !conflicts.isEmpty { return .conflicts(conflicts) }
            }
            switch try await applier.apply(worktree: worktree, runID: key) {
            case .clean: return .clean
            case .conflicts(let paths): return .conflicts(paths)
            case .nothing: return .nothing
            }
        }
    }

    /// Unpacks into a scratch directory first, then moves each file in: a file replaces a local
    /// one only if git ignores the local one (§4.5 — tracked and unignored work is the user's),
    /// and nothing lands inside `.git` or through a symlinked directory.
    func extractArtifacts(tar: URL, into worktree: URL) async throws {
        let git = git
        do {
            try await offloaded { try Self.extract(tar: tar, into: worktree, git: git) }
        } catch {
            throw LiveGitFailure.delegationError(error, doing: "unpack the run's artifacts")
        }
    }

    // MARK: -

    private func withResult<T: Sendable>(bundle: URL, commit: String, worktree: URL, doing what: String,
                                         _ body: @Sendable (String) async throws -> T) async throws -> T {
        let applier = ResultApplier(git: git)
        let key = "fd-\(commit)"
        do {
            let fetched = try await applier.fetch(bundle: bundle, worktree: worktree, runID: key)
            guard fetched == commit else {
                try? await applier.discard(worktree: worktree, runID: key)
                throw DelegationError(code: "unexpected_reply",
                                      message: "the result bundle holds \(fetched.prefix(12)), not \(commit.prefix(12)) — rerun")
            }
            let value = try await body(key)
            try? await applier.discard(worktree: worktree, runID: key)
            return value
        } catch {
            try? await applier.discard(worktree: worktree, runID: key)
            throw LiveGitFailure.delegationError(error, doing: what)
        }
    }

    /// The paths `ResultApplier.apply` would leave conflicted: the same merge-tree of the
    /// worktree as it is now against the result, with the snapshot as the base, written to
    /// nothing but a scratch index and loose objects.
    static func wouldConflict(commit: String, worktree: URL, git: GitRunner) throws -> [String] {
        let top = URL(fileURLWithPath: try git.text(["rev-parse", "--show-toplevel"], in: worktree))
        let base = try git.text(["rev-parse", "\(commit)^"], in: top)
        let gitDir = URL(fileURLWithPath: try git.text(["rev-parse", "--absolute-git-dir"], in: top))
        let index = gitDir.appendingPathComponent("flightdeck-dryrun-\(UUID().uuidString).index")
        defer { try? FileManager.default.removeItem(at: index) }
        let env = ["GIT_INDEX_FILE": index.path]
        try git.run(["read-tree", base], in: top, env: env)
        try git.run(["add", "-A"], in: top, env: env)
        let tree = try git.text(["write-tree"], in: top, env: env)
        let ours = try git.text(["commit-tree", tree, "-p", base, "-m", "flightdeck: working tree"], in: top)
        let merged = try git.run(["merge-tree", "--write-tree", "-z", "--name-only", "--merge-base=\(base)", ours, commit],
                                 in: top, accept: [0, 1])
        guard merged.status == 1 else { return [] }
        // -z --name-only: <tree> NUL <conflicted path> NUL ... NUL NUL <messages>.
        let fields = merged.stdout.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        return Array(Set(fields.dropFirst().prefix { !$0.isEmpty })).sorted()
    }

    static func extract(tar: URL, into worktree: URL, git: GitRunner) throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("fd-artifacts-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        try untar(tar, into: scratch)

        // Leaves only: a directory is created by what goes into it.
        var paths: [String] = []
        let base = scratch.resolvingSymlinksInPath().path + "/"
        let walker = fm.enumerator(at: scratch, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        while let url = walker?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true, values.isSymbolicLink != true { continue }
            let full = url.resolvingSymlinksInPath().deletingLastPathComponent().path + "/" + url.lastPathComponent
            guard full.hasPrefix(base) else { continue }
            paths.append(String(full.dropFirst(base.count)))
        }
        let safe = paths.filter { isSafe($0, under: worktree) }
        let existing = safe.filter { (try? fm.attributesOfItem(atPath: worktree.appendingPathComponent($0).path)) != nil }
        let ignored = try Self.ignored(existing, in: worktree, git: git)
        for path in safe where !existing.contains(path) || ignored.contains(path) {
            let target = worktree.appendingPathComponent(path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            try fm.moveItem(at: scratch.appendingPathComponent(path), to: target)
        }
    }

    /// Not absolute, no `.`/`..`/`.git` component (any case: APFS folds it), and no existing
    /// parent that is a symlink — the same rule `ResultApplier` holds host paths to.
    static func isSafe(_ path: String, under worktree: URL) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.lowercased() == ".git" })
        else { return false }
        var dir = worktree
        for part in parts.dropLast() {
            dir = dir.appendingPathComponent(part)
            guard let type = (try? FileManager.default.attributesOfItem(atPath: dir.path))?[.type] as? FileAttributeType else { break }
            if type == .typeSymbolicLink { return false }
        }
        return true
    }

    private static func ignored(_ paths: [String], in worktree: URL, git: GitRunner) throws -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let out = try git.run(["check-ignore", "-z", "--stdin"], in: worktree,
                              input: Data(paths.joined(separator: "\0").utf8 + [0]), accept: [0, 1]).stdout
        return Set(out.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
    }

    /// bsdtar strips `..` and leading `/` from member names by default, so nothing is written
    /// outside `directory`.
    private static func untar(_ tar: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xf", tar.path, "-C", directory.path]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        try? err.fileHandleForReading.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DelegationError(code: "artifacts_failed",
                                  message: "couldn't unpack the run's artifacts: \(String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) — rerun")
        }
    }
}
