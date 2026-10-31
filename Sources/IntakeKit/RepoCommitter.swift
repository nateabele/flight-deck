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
    }

    public struct Result: Equatable, Sendable {
        public var sha: String
        public var paths: [String]
    }

    private let runner: CommandRunner
    private let environment: [String: String]

    /// `environment` is the complete child environment; the default is this process's. Either way
    /// `GIT_TERMINAL_PROMPT=0` is set, so a credential prompt fails instead of hanging release.
    public init(runner: CommandRunner = SystemCommandRunner(),
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.runner = runner
        var env = environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        self.environment = env
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
        // Checked before the first byte is written, so a refusal changes nothing.
        for f in export.files where !Self.isSafe(f.path) { throw Failure.unsafePath(f.path) }
        let dir = export.directory
        let status = try await git(repo, "status", "--porcelain", "--", dir)
        if !status.isEmpty { throw Failure.dirty(path: dir, status: status) }

        let fm = FileManager.default
        let root = repo.appendingPathComponent(dir, isDirectory: true)
        let existed = fm.fileExists(atPath: root.path)
        // The folder is clean and this intake's own, so it is replaced whole: a file the new
        // export no longer has leaves with it, and `git add -- <dir>` stages that deletion too.
        if existed { try fm.removeItem(at: root) }
        do {
            for f in export.files {
                let url = root.appendingPathComponent(f.path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try f.data.write(to: url)
            }
            try await git(repo, "add", "--", dir)
            try await git(repo, "commit", "-m", export.commitMessage, "--", dir)
        } catch {
            await rollback(repo: repo, dir: dir, root: root, existed: existed)
            throw error
        }
        let sha = try await git(repo, "rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(sha: sha, paths: export.preview.paths)
    }

    /// Puts `dir` back as HEAD has it. Only this folder, and only with `restore`/`clean`/`reset`
    /// scoped to it; failures here are swallowed because the original error is the one to report.
    private func rollback(repo: URL, dir: String, root: URL, existed: Bool) async {
        _ = try? await git(repo, "reset", "-q", "--", dir)
        if existed {
            _ = try? await git(repo, "restore", "--source=HEAD", "--worktree", "--", dir)
            _ = try? await git(repo, "clean", "-fdq", "--", dir)
        } else {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @discardableResult
    private func git(_ repo: URL, _ args: String...) async throws -> String {
        let r = try await runner.run(executable: "git", arguments: ["-C", repo.path] + args, cwd: repo,
                                     environment: environment)
        guard r.exitCode == 0 else {
            throw Failure.git(step: args.first ?? "git", stderr: r.stderr.isEmpty ? String(decoding: r.stdout, as: UTF8.self) : r.stderr)
        }
        return String(decoding: r.stdout, as: UTF8.self)
    }

    private static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}
