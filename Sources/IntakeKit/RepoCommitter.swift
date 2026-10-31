import Foundation

/// Writes a `PlanExport` into the user's repo and commits exactly those paths (V-R4).
///
/// The working copy is shared with the user's own unfinished work, so this never stashes, never
/// checks out, and never commits with a bare `git commit`: `git commit -- <paths>` records only
/// the pathspec, and leaves every other staged, unstaged and untracked file as it was. The user's
/// hooks run (no `--no-verify`), since the commit is theirs.
public struct RepoCommitter: Sendable {
    public enum Failure: Error, Equatable {
        /// `docs/plans/<slug>` has changes git has not committed. `path` is what was refused.
        case dirty(path: String, status: String)
        /// A step failed; `stderr` is git's own words (a hook's output arrives here).
        case git(step: String, stderr: String)
        case unsafePath(String)
        case symlink(String)
        case notOwned(String)
        case ignored([String])
        case badSlug(String)
        case notRepoRoot(String)
        case timeout(step: String)
    }

    public struct Result: Equatable, Sendable {
        public var sha: String
        public var paths: [String]
        public var noChange = false
    }

    private let runner: CommandRunner
    private let environment: [String: String]
    private let gitTimeout: TimeInterval

    /// `environment` is the complete child environment; the default is this process's. Either way
    /// `GIT_TERMINAL_PROMPT=0` is set, so a credential prompt fails instead of hanging release,
    /// and the variables that re-aim git at another repo are dropped: `-C <repo>` must mean the
    /// repo it says. `GIT_LITERAL_PATHSPECS` is deliberately not set (hooks inherit the
    /// environment); the pathspec carries `:(literal)` itself.
    ///
    /// `gitTimeout` bounds each git call, so a hook that never returns fails the release.
    public init(runner: CommandRunner = SystemCommandRunner(),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                gitTimeout: TimeInterval = 120) {
        self.runner = runner
        var env = environment
        for k in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY"] { env[k] = nil }
        env["GIT_TERMINAL_PROMPT"] = "0"
        self.environment = env
        self.gitTimeout = gitTimeout
    }

    /// Who owns `docs/plans/<slug>` in `repo`, by its marker file.
    public static func owner(of slug: String, repo: URL) -> SlugOwner {
        let dir = repo.appendingPathComponent("\(PlanExporter.plansRoot)/\(slug)", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) else { return .free }
        let marker = dir.appendingPathComponent(PlanExporter.markerName)
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return .unmarked }
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? .unmarked : .intake(id)
    }

    public func commit(_ export: PlanExport, repo: URL) async throws -> Result {
        // Everything below up to the first write is a check; a refusal changes nothing. They are
        // here, not only in `resolveSlug`, because the folder can change between choosing a slug
        // and committing, and because this is the one place that deletes.
        guard Self.isValidSlug(export.slug) else { throw Failure.badSlug(export.slug) }
        for f in export.files where !Self.isSafe(f.path) { throw Failure.unsafePath(f.path) }
        let dir = export.directory
        let spec = ":(literal)\(dir)"

        let repoReal = Self.realpath(repo.path) ?? repo.path
        let top = try await git(repo, "rev-parse", "--show-toplevel").trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.realpath(top) == repoReal else { throw Failure.notRepoRoot(top) }

        try Self.checkNoSymlinks(repoReal: repoReal, dir: dir)
        let root = repo.appendingPathComponent(dir, isDirectory: true)
        let existed = FileManager.default.fileExists(atPath: root.path)
        if existed {
            let mine = export.file(PlanExporter.markerName).map {
                String(decoding: $0.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? ""
            guard !mine.isEmpty, Self.owner(of: export.slug, repo: repo) == .intake(mine) else { throw Failure.notOwned(dir) }
        }

        // `--ignored` as well: a `.DS_Store` or a swap file is invisible to plain status, and the
        // replace below would delete it for good.
        let status = try await git(repo, "status", "--porcelain", "--ignored", "--", spec)
        if !status.isEmpty { throw Failure.dirty(path: dir, status: status) }

        // An exported file git would ignore would be written but never committed: a plan with
        // silently missing snapshots. Refuse instead.
        let ignored = try await ignoredPaths(repo, export.files.map { "\(dir)/\($0.path)" })
        if !ignored.isEmpty { throw Failure.ignored(ignored) }

        let fm = FileManager.default
        do {
            // The folder is clean and this intake's own, so it is replaced whole: a file the new
            // export no longer has leaves with it, and `git add` stages that deletion too.
            if existed { try fm.removeItem(at: root) }
            for f in export.files {
                let url = root.appendingPathComponent(f.path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try f.data.write(to: url)
            }
            try await git(repo, "add", "--", spec)
            let diff = try await run(repo, ["diff", "--cached", "--quiet", "--", spec])
            if diff.exitCode == 0 {
                // Identical to what HEAD has: nothing to commit, and not a failure.
                let head = try await git(repo, "rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
                return Result(sha: head, paths: export.preview.paths, noChange: true)
            }
            guard diff.exitCode == 1 else { throw Failure.git(step: "diff", stderr: diff.stderr) }
            try await git(repo, "commit", "-m", export.commitMessage, "--", spec)
        } catch {
            await rollback(repo: repo, spec: spec, root: root, existed: existed)
            throw error
        }
        let sha = try await git(repo, "rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(sha: sha, paths: export.preview.paths)
    }

    /// Puts the folder back as HEAD has it. Only this folder, and only with `restore`/`clean`/`reset`
    /// scoped to it; failures here are swallowed because the original error is the one to report.
    private func rollback(repo: URL, spec: String, root: URL, existed: Bool) async {
        _ = try? await git(repo, "reset", "-q", "--", spec)
        if existed {
            _ = try? await git(repo, "restore", "--source=HEAD", "--worktree", "--", spec)
            _ = try? await git(repo, "clean", "-fdq", "--", spec)
        } else {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func ignoredPaths(_ repo: URL, _ paths: [String]) async throws -> [String] {
        var out: [String] = []
        var i = 0
        while i < paths.count {
            let batch = Array(paths[i..<min(i + 200, paths.count)])
            i += 200
            let r = try await run(repo, ["-c", "core.quotePath=false", "check-ignore", "--"] + batch)
            switch r.exitCode {
            case 0: out += String(decoding: r.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
            case 1: break
            default: throw Failure.git(step: "check-ignore", stderr: r.stderr)
            }
        }
        return out
    }

    /// Runs git in `repo`, always as `git -C <repo>`, with the call bounded by `gitTimeout`. A
    /// process group, so that timing out kills a hook's children too instead of leaving them
    /// holding the pipes.
    private func run(_ repo: URL, _ args: [String]) async throws -> CommandResult {
        let step = args.first { $0 != "-c" && !$0.contains("=") } ?? "git"
        let runner = runner, env = environment
        let seconds = gitTimeout
        return try await withThrowingTaskGroup(of: CommandResult?.self) { group in
            group.addTask {
                try await runner.run(executable: "git", arguments: ["-C", repo.path] + args, cwd: repo,
                                     environment: env, processGroup: true, onSpawn: nil)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            guard let result = first else { throw Failure.timeout(step: step) }
            return result
        }
    }

    @discardableResult
    private func git(_ repo: URL, _ args: String...) async throws -> String {
        let r = try await run(repo, args)
        guard r.exitCode == 0 else {
            throw Failure.git(step: args.first ?? "git", stderr: r.stderr.isEmpty ? String(decoding: r.stdout, as: UTF8.self) : r.stderr)
        }
        return String(decoding: r.stdout, as: UTF8.self)
    }

    // MARK: Path checks

    /// `^[a-z0-9]+(-[a-z0-9]+)*$`
    static func isValidSlug(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { p in
            !p.isEmpty && p.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) }
        }
    }

    private static func realpath(_ path: String) -> String? {
        guard let p = Darwin.realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// Every component from the repo down to the export folder must be a real directory (or not
    /// exist yet). A symlink anywhere would make `removeItem` delete what it points at, outside
    /// the repo, while git says the folder is clean.
    private static func checkNoSymlinks(repoReal: String, dir: String) throws {
        var current = repoReal
        var rel = ""
        for comp in dir.split(separator: "/") {
            current += "/" + comp
            rel += (rel.isEmpty ? "" : "/") + comp
            var st = stat()
            if lstat(current, &st) != 0 {
                guard errno == ENOENT else { throw Failure.unsafePath(rel) }
                break
            }
            if (st.st_mode & S_IFMT) == S_IFLNK { throw Failure.symlink(rel) }
            if (st.st_mode & S_IFMT) != S_IFDIR { throw Failure.unsafePath(rel) }
            guard let real = realpath(current), real == repoReal || real.hasPrefix(repoReal + "/") else {
                throw Failure.symlink(rel)
            }
        }
    }

    private static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}
