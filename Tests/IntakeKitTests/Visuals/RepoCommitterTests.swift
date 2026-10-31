import XCTest
@testable import IntakeKit

/// Runs against a real git binary in a temp repo: the point is what git does to the user's other files.
final class RepoCommitterTests: XCTestCase {
    private var repo: URL!
    private let runner = SystemCommandRunner()

    override func setUp() async throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("rc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await git("init", "-q")
        try await git("config", "user.email", "t@example.com")
        try await git("config", "user.name", "T")
        try await git("config", "commit.gpgsign", "false")
        try write("README.md", "hello\n")
        try write("other.txt", "one\n")
        try await git("add", "-A")
        try await git("commit", "-q", "-m", "init")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: repo) }

    @discardableResult
    private func git(_ args: String...) async throws -> String {
        let env = ProcessInfo.processInfo.environment
        let r = try await runner.run(executable: "git", arguments: ["-C", repo.path] + args, cwd: repo, environment: env)
        XCTAssertEqual(r.exitCode, 0, "git \(args): \(r.stderr)")
        return String(decoding: r.stdout, as: UTF8.self)
    }
    private func write(_ rel: String, _ s: String) throws {
        let u = repo.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: u, atomically: true, encoding: .utf8)
    }
    private func read(_ rel: String) -> String? { try? String(contentsOf: repo.appendingPathComponent(rel), encoding: .utf8) }
    private func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: repo.appendingPathComponent(rel).path) }

    private func sample(_ body: String = "plan v1") -> PlanExport {
        PlanExport(slug: "demo", files: [ExportedFile(path: "plan.md", data: Data(body.utf8)),
                                         ExportedFile(path: "visuals/a/x.txt", data: Data("x".utf8))], warnings: [])
    }
    private func committer() -> RepoCommitter { RepoCommitter(runner: runner) }

    func testCommitsOnlyThePlanPathsAndLeavesOtherDirtyFilesAlone() async throws {
        // The user has an unstaged edit, a staged edit and an untracked file, all elsewhere.
        try write("other.txt", "two\n")
        try write("README.md", "staged change\n")
        try await git("add", "README.md")
        try write("untracked.txt", "u\n")
        let before = try await git("status", "--porcelain")

        let result = try await committer().commit(sample(), repo: repo)

        XCTAssertEqual(read("docs/plans/demo/plan.md"), "plan v1")
        let after = try await git("status", "--porcelain")
        XCTAssertEqual(after, before, "everything the user had dirty is exactly as it was")
        XCTAssertEqual(read("other.txt"), "two\n")
        let msg = try await git("log", "-1", "--format=%s")
        XCTAssertEqual(msg.trimmingCharacters(in: .whitespacesAndNewlines), "docs: plan demo for release")
        let files = try await git("show", "--name-only", "--format=", "HEAD")
        XCTAssertFalse(files.contains("other.txt") || files.contains("README.md") || files.contains("untracked"), files)
        XCTAssertTrue(files.contains("docs/plans/demo/plan.md"))
        XCTAssertEqual(result.sha.count, 40)
    }

    /// Review Focus 4.
    func testADirtyPlanFolderRefusesAndWritesNothing() async throws {
        try write("docs/plans/demo/plan.md", "committed\n")
        try await git("add", "-A"); try await git("commit", "-q", "-m", "plan")
        try write("docs/plans/demo/plan.md", "hand edit\n")
        try write("docs/plans/demo/notes.txt", "untracked\n")

        do {
            _ = try await committer().commit(sample(), repo: repo)
            XCTFail("should refuse")
        } catch let RepoCommitter.Failure.dirty(path, _) {
            XCTAssertEqual(path, "docs/plans/demo")
        }
        XCTAssertEqual(read("docs/plans/demo/plan.md"), "hand edit\n", "the hand edit is not overwritten")
        XCTAssertFalse(exists("docs/plans/demo/visuals/a/x.txt"), "nothing was written")
        XCTAssertEqual(read("docs/plans/demo/notes.txt"), "untracked\n")
        let count = try await git("rev-list", "--count", "HEAD")
        XCTAssertEqual(count.trimmingCharacters(in: .whitespacesAndNewlines), "2")
    }

    func testAReReleaseOverwritesAndDropsFilesNoLongerExported() async throws {
        _ = try await committer().commit(sample("plan v1"), repo: repo)
        let v2 = PlanExport(slug: "demo", files: [ExportedFile(path: "plan.md", data: Data("plan v2".utf8))], warnings: [])
        _ = try await committer().commit(v2, repo: repo)
        XCTAssertEqual(read("docs/plans/demo/plan.md"), "plan v2")
        XCTAssertFalse(exists("docs/plans/demo/visuals/a/x.txt"))
        let status = try await git("status", "--porcelain")
        XCTAssertEqual(status, "")
    }

    func testTheUsersHooksRunAndAFailingHookLeavesTheRepoAsItWas() async throws {
        let hook = repo.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\necho blocked >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try write("other.txt", "dirty\n")

        do {
            _ = try await committer().commit(sample(), repo: repo)
            XCTFail("hook should block")
        } catch let RepoCommitter.Failure.git(_, stderr) {
            XCTAssertTrue(stderr.contains("blocked"), stderr)
        }
        XCTAssertFalse(exists("docs/plans/demo"), "rolled back")
        let status = try await git("status", "--porcelain")
        XCTAssertEqual(status, " M other.txt\n")
    }

    func testNeverUsesStashOrCheckout() async throws {
        let rec = RecordingRunner()
        _ = try? await RepoCommitter(runner: rec).commit(sample(), repo: repo)
        XCTAssertFalse(rec.calls.isEmpty)
        for c in rec.calls {
            XCTAssertEqual(Array(c.arguments.prefix(2)), ["-C", repo.path])
            XCTAssertFalse(c.arguments.contains("stash") || c.arguments.contains("checkout") || c.arguments.contains("--no-verify"))
            XCTAssertEqual(c.environment["GIT_TERMINAL_PROMPT"], "0")
        }
    }

    func testAnEscapingPathIsRefusedBeforeAnythingIsWritten() async {
        let bad = PlanExport(slug: "demo", files: [ExportedFile(path: "../escape.txt", data: Data())], warnings: [])
        do { _ = try await committer().commit(bad, repo: repo); XCTFail() } catch {
            XCTAssertEqual(error as? RepoCommitter.Failure, .unsafePath("../escape.txt"))
        }
    }

    func testSlugOwnerReadsTheMarker() async throws {
        XCTAssertEqual(RepoCommitter.owner(of: "demo", repo: repo), .free)
        try write("docs/plans/demo/x", "x")
        XCTAssertEqual(RepoCommitter.owner(of: "demo", repo: repo), .unmarked)
        try write("docs/plans/demo/.flightdeck-intake", "abc\n")
        XCTAssertEqual(RepoCommitter.owner(of: "demo", repo: repo), .intake("abc"))
    }
}

private final class RecordingRunner: CommandRunner, @unchecked Sendable {
    struct Call { var arguments: [String]; var environment: [String: String] }
    private(set) var calls: [Call] = []
    func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
             processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?) async throws -> CommandResult {
        calls.append(Call(arguments: arguments, environment: environment))
        return CommandResult(stdout: Data(), stderr: "", exitCode: 0)
    }
}
