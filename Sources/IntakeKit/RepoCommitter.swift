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
        /// A file operation failed.
        case io(String)
    }

    public struct Result: Equatable, Sendable {
        public var sha: String
        public var paths: [String]
        public var noChange = false
        /// The subset of `paths` the commit deleted.
        public var removed: [String] = []
    }

    private let runner: CommandRunner
    private let environment: [String: String]
    private let gitTimeout: TimeInterval

    /// Where a test can act between steps, to prove a swap in that gap changes nothing outside.
    enum Stage { case checked, written }
    var onStage: (@Sendable (Stage) -> Void)?

    /// `environment` is the complete child environment; the default is this process's. Either way
    /// `GIT_TERMINAL_PROMPT=0` is set, so a credential prompt fails instead of hanging release,
    /// and the variables that re-aim git at another repo are dropped: `-C <repo>` must mean the
    /// repo it says. `GIT_LITERAL_PATHSPECS` is deliberately not set (hooks inherit the
    /// environment); the pathspec carries `:(literal)` itself, so an inherited pathspec-magic
    /// variable or injected config must not change what a pathspec means.
    ///
    /// `gitTimeout` bounds each git call, so a hook that never returns fails the release.
    public init(runner: CommandRunner = SystemCommandRunner(),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                gitTimeout: TimeInterval = 120) {
        self.runner = runner
        var env = environment
        for k in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR",
                  "GIT_LITERAL_PATHSPECS", "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS",
                  "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT"] { env[k] = nil }
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

    /// What a release of `export` would do to the repo: the files it writes, and the files already
    /// committed under the folder that the new export no longer has.
    public func preview(_ export: PlanExport, repo: URL) async throws -> PlanExportPreview {
        let tracked = try await git(repo, "ls-files", "-z", "--", ":(literal)\(export.directory)")
        let keep = Set(export.preview.paths)
        let removed = Self.nul(tracked).filter { !keep.contains($0) }.sorted()
        return PlanExportPreview(paths: export.preview.paths, commitMessage: export.commitMessage, removed: removed)
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

        // From here every delete, write and rollback goes through these descriptors, opened one
        // component at a time without following links. A path would be looked up again at each
        // use, and a swap in between could point it outside the repo.
        let rootDir: SafeTree.Dir
        var docsDir: SafeTree.Dir?, plansDir: SafeTree.Dir?, slugDir: SafeTree.Dir?
        do {
            rootDir = try SafeTree.openRoot(repoReal)
            let a = SafeTree.identity(rootDir), b = SafeTree.identity(ofPath: top)
            guard let a, let b, a.dev == b.dev, a.ino == b.ino else { throw Failure.notRepoRoot(top) }
            docsDir = try SafeTree.openChild(rootDir, "docs")
            plansDir = try docsDir.flatMap { try SafeTree.openChild($0, "plans") }
            slugDir = try plansDir.flatMap { try SafeTree.openChild($0, export.slug) }
        } catch let e as SafeTree.Fail {
            throw e.notPlain ? Failure.symlink(Self.relativeName(e.name, dir: dir)) : Failure.io(e.detail)
        }
        let existed = slugDir != nil
        if existed {
            let mine = export.file(PlanExporter.markerName).map {
                String(decoding: $0.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? ""
            guard !mine.isEmpty, Self.owner(of: export.slug, repo: repo) == .intake(mine) else { throw Failure.notOwned(dir) }
        }

        // `assume-unchanged` and `skip-worktree` hide edits from status, and the replace below
        // would destroy them. Lowercase flags and `S` mark them.
        let flags = try await git(repo, "ls-files", "-v", "-z", "--", spec)
        for line in Self.nul(flags) {
            guard let f = line.first, f.isLowercase || f == "S" else { continue }
            throw Failure.dirty(path: String(line.dropFirst(2)), status: String(line))
        }

        // `--ignored` as well: a `.DS_Store` or a swap file is invisible to plain status, and the
        // replace below would delete it for good.
        // `--untracked-files=all` overrides a `status.showUntrackedFiles=no` in the user's config,
        // which would otherwise hide exactly the files the replace deletes.
        let status = try await git(repo, "status", "--porcelain", "-z", "--untracked-files=all", "--ignored", "--", spec)
        if !status.isEmpty { throw Failure.dirty(path: dir, status: Self.nul(status).joined(separator: "\n")) }

        // An exported file git would ignore would be written but never committed: a plan with
        // silently missing snapshots. Refuse instead.
        let ignored = try await ignoredPaths(repo, export.files.map { "\(dir)/\($0.path)" })
        if !ignored.isEmpty { throw Failure.ignored(ignored) }

        onStage?(.checked)
        var plansForRollback = plansDir
        do {
            do {
                let docs = try docsDir ?? SafeTree.openOrMake(rootDir, "docs")
                let plans = try plansDir ?? SafeTree.openOrMake(docs, "plans")
                plansForRollback = plans
                // The folder is clean and this intake's own, so it is replaced whole: a file the new
                // export no longer has leaves with it, and `git add` stages that deletion too.
                if existed { try SafeTree.removeTree(plans, export.slug) }
                let slugNow = try SafeTree.openOrMake(plans, export.slug)
                for f in export.files { try SafeTree.write(f.data, to: f.path, under: slugNow) }
            } catch let e as SafeTree.Fail {
                throw e.notPlain ? Failure.symlink(Self.relativeName(e.name, dir: dir)) : Failure.io(e.detail)
            }
            onStage?(.written)
            try await git(repo, "add", "--", spec)
            let staged = try await git(repo, "diff", "--cached", "--name-status", "-z", "--no-renames", "--", spec)
            if staged.isEmpty {
                // Identical to what HEAD has: nothing to commit, and not a failure.
                let head = try await git(repo, "rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
                return Result(sha: head, paths: export.preview.paths, noChange: true)
            }
            var paths: [String] = [], removed: [String] = []
            // `-z`: "<status>\0<path>\0" pairs, with names exactly as on disk.
            let fields = Self.nul(staged)
            var k = 0
            while k + 1 < fields.count {
                paths.append(fields[k + 1])
                if fields[k] == "D" { removed.append(fields[k + 1]) }
                k += 2
            }
            try await git(repo, "commit", "-m", export.commitMessage, "--", spec)
            let sha = try await git(repo, "rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
            return Result(sha: sha, paths: paths, noChange: false, removed: removed)
        } catch {
            await rollback(repo: repo, spec: spec, plans: plansForRollback, slug: export.slug, existed: existed)
            throw error
        }
    }

    /// Puts the folder back as HEAD has it. Only this folder, and only with `restore`/`clean`/`reset`
    /// scoped to it, or a delete through the descriptor opened at the start; failures here are
    /// swallowed because the original error is the one to report.
    private func rollback(repo: URL, spec: String, plans: SafeTree.Dir?, slug: String, existed: Bool) async {
        _ = try? await git(repo, "reset", "-q", "--", spec)
        if existed {
            _ = try? await git(repo, "restore", "--source=HEAD", "--worktree", "--", spec)
            _ = try? await git(repo, "clean", "-fdq", "--", spec)
        } else if let plans {
            try? SafeTree.removeTree(plans, slug)
        }
    }

    /// `check-ignore` cannot print names unquoted without `--stdin` (which this runner lacks), so
    /// output is never parsed: a batch's exit status says whether anything in it is ignored, and
    /// only then is each path in that batch asked about alone.
    private func ignoredPaths(_ repo: URL, _ paths: [String]) async throws -> [String] {
        var out: [String] = []
        var i = 0
        while i < paths.count {
            let batch = Array(paths[i..<min(i + 200, paths.count)])
            i += 200
            switch try await run(repo, ["check-ignore", "--"] + batch).exitCode {
            case 0:
                for p in batch {
                    let r = try await run(repo, ["check-ignore", "-q", "--", p])
                    if r.exitCode == 0 { out.append(p) } else if r.exitCode != 1 { throw Failure.git(step: "check-ignore", stderr: r.stderr) }
                }
            case 1: break
            default: throw Failure.git(step: "check-ignore", stderr: "")
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

    /// NUL-separated git output as strings (`-z`), with no trailing empty entry.
    static func nul(_ s: String) -> [String] { s.split(separator: "\0", omittingEmptySubsequences: true).map(String.init) }

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

    /// The repo-relative name for the component a refusal was on.
    private static func relativeName(_ name: String, dir: String) -> String {
        switch name {
        case "docs": "docs"
        case "plans": "docs/plans"
        default: dir
        }
    }

    private static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}
