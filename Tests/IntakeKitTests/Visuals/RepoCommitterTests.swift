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
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: repo)
        if let outside { try? FileManager.default.removeItem(at: outside) }
    }

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

    private func sample(_ body: String = "plan v1", intake: String = "intake-1") -> PlanExport {
        PlanExport(slug: "demo", files: [ExportedFile(path: "plan.md", data: Data(body.utf8)),
                                         ExportedFile(path: PlanExporter.markerName, data: Data((intake + "\n").utf8)),
                                         ExportedFile(path: "visuals/a/x.txt", data: Data("x".utf8))], warnings: [])
    }
    private var outside: URL!
    private func makeOutside() throws -> URL {
        let o = FileManager.default.temporaryDirectory.appendingPathComponent("rc-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: o.appendingPathComponent("plans/demo"), withIntermediateDirectories: true)
        try "precious".write(to: o.appendingPathComponent("plans/demo/keep.txt"), atomically: true, encoding: .utf8)
        try "intake-1\n".write(to: o.appendingPathComponent("plans/demo/.flightdeck-intake"), atomically: true, encoding: .utf8)
        outside = o
        return o
    }
    private func commitAll(_ msg: String) async throws { try await git("add", "-A"); try await git("commit", "-q", "-m", msg) }
    private func assertFails(_ expected: RepoCommitter.Failure, file: StaticString = #filePath, line: UInt = #line,
                             _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("should have thrown", file: file, line: line) } catch {
            XCTAssertEqual(error as? RepoCommitter.Failure, expected, file: file, line: line)
        }
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
        try write("docs/plans/demo/.flightdeck-intake", "intake-1\n")
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
        let v2 = PlanExport(slug: "demo", files: [ExportedFile(path: "plan.md", data: Data("plan v2".utf8)),
                                                  ExportedFile(path: PlanExporter.markerName, data: Data("intake-1\n".utf8))], warnings: [])
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
        rec.top = repo.path
        _ = try? await RepoCommitter(runner: rec, environment: ["GIT_DIR": "/elsewhere", "GIT_WORK_TREE": "/elsewhere",
                                                               "GIT_INDEX_FILE": "/x", "GIT_OBJECT_DIRECTORY": "/x", "PATH": "/usr/bin",
                                                               "GIT_LITERAL_PATHSPECS": "1", "GIT_GLOB_PATHSPECS": "1",
                                                               "GIT_NOGLOB_PATHSPECS": "1", "GIT_ICASE_PATHSPECS": "1",
                                                               "GIT_COMMON_DIR": "/x", "GIT_CONFIG_PARAMETERS": "'a.b=c'",
                                                               "GIT_CONFIG_COUNT": "1"])
            .commit(sample(), repo: repo)
        XCTAssertFalse(rec.calls.isEmpty)
        XCTAssertTrue(rec.calls.contains { $0.arguments.contains(":(literal)docs/plans/demo") }, "one literal pathspec")
        for c in rec.calls {
            XCTAssertEqual(Array(c.arguments.prefix(2)), ["-C", repo.path])
            XCTAssertFalse(c.arguments.contains("stash") || c.arguments.contains("checkout") || c.arguments.contains("--no-verify"))
            XCTAssertEqual(c.environment["GIT_TERMINAL_PROMPT"], "0")
            for k in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_LITERAL_PATHSPECS",
                      "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS", "GIT_COMMON_DIR",
                      "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT"] { XCTAssertNil(c.environment[k], k) }
        }
    }

    func testAnEscapingPathIsRefusedBeforeAnythingIsWritten() async {
        let bad = PlanExport(slug: "demo", files: [ExportedFile(path: "../escape.txt", data: Data())], warnings: [])
        do { _ = try await committer().commit(bad, repo: repo); XCTFail() } catch {
            XCTAssertEqual(error as? RepoCommitter.Failure, .unsafePath("../escape.txt"))
        }
    }

    // MARK: Safety review, fix round 1

    func testASymlinkedDocsFolderRefusesAndTheOutsideFolderSurvives() async throws {
        let o = try makeOutside()
        try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent("docs"), withDestinationURL: o)
        try await commitAll("link docs")
        await assertFails(.symlink("docs")) { _ = try await committer().commit(sample(), repo: repo) }
        XCTAssertEqual(try String(contentsOf: o.appendingPathComponent("plans/demo/keep.txt")), "precious")
    }

    func testASymlinkedPlansFolderRefuses() async throws {
        let o = try makeOutside()
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent("docs/plans"),
                                                   withDestinationURL: o.appendingPathComponent("plans"))
        try await commitAll("link plans")
        await assertFails(.symlink("docs/plans")) { _ = try await committer().commit(sample(), repo: repo) }
        XCTAssertEqual(try String(contentsOf: o.appendingPathComponent("plans/demo/keep.txt")), "precious")
    }

    /// A folder that appeared after `resolveSlug` chose the slug must not be taken over.
    func testAnUnmarkedCommittedFolderRefusesAndSurvives() async throws {
        try write("docs/plans/demo/own.md", "mine\n")
        try await commitAll("their docs")
        await assertFails(.notOwned("docs/plans/demo")) { _ = try await committer().commit(sample(), repo: repo) }
        XCTAssertEqual(read("docs/plans/demo/own.md"), "mine\n")
        XCTAssertFalse(exists("docs/plans/demo/plan.md"))
    }

    func testAnotherIntakesFolderRefuses() async throws {
        _ = try await committer().commit(sample(intake: "someone-else"), repo: repo)
        await assertFails(.notOwned("docs/plans/demo")) { _ = try await committer().commit(sample(), repo: repo) }
        XCTAssertEqual(read("docs/plans/demo/plan.md"), "plan v1")
    }

    func testIgnoredFilesInsideTheFolderRefuseAndSurvive() async throws {
        try write(".gitignore", ".DS_Store\n*.swp\n")
        try await commitAll("ignore")
        _ = try await committer().commit(sample(), repo: repo)
        try write("docs/plans/demo/.DS_Store", "finder")
        do {
            _ = try await committer().commit(sample("plan v2"), repo: repo)
            XCTFail("should refuse")
        } catch let RepoCommitter.Failure.dirty(_, status) {
            XCTAssertTrue(status.contains(".DS_Store"), status)
        }
        XCTAssertEqual(read("docs/plans/demo/.DS_Store"), "finder")
        XCTAssertEqual(read("docs/plans/demo/plan.md"), "plan v1")
    }

    func testAFailedDeleteRollsBack() async throws {
        let first = PlanExport(slug: "demo", files: [ExportedFile(path: "a.txt", data: Data("a".utf8)),
            ExportedFile(path: PlanExporter.markerName, data: Data("intake-1\n".utf8)),
            ExportedFile(path: "sub/b.txt", data: Data("b".utf8))], warnings: [])
        _ = try await committer().commit(first, repo: repo)
        let sub = repo.appendingPathComponent("docs/plans/demo/sub").path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sub)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sub) }
        do { _ = try await committer().commit(sample(), repo: repo); XCTFail("the delete should fail") } catch {}
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sub)
        XCTAssertEqual(read("docs/plans/demo/a.txt"), "a")
        XCTAssertEqual(read("docs/plans/demo/sub/b.txt"), "b")
        let status = try await git("status", "--porcelain")
        XCTAssertEqual(status, "")
    }

    func testAnIdenticalReReleaseIsANoChangeNotAnError() async throws {
        let first = try await committer().commit(sample(), repo: repo)
        XCTAssertFalse(first.noChange)
        let again = try await committer().commit(sample(), repo: repo)
        XCTAssertTrue(again.noChange)
        XCTAssertEqual(again.sha, first.sha)
        let count = try await git("rev-list", "--count", "HEAD")
        XCTAssertEqual(count.trimmingCharacters(in: .whitespacesAndNewlines), "2")
        XCTAssertEqual(read("docs/plans/demo/plan.md"), "plan v1")
        let status = try await git("status", "--porcelain")
        XCTAssertEqual(status, "")
    }

    func testAnExportedPathGitWouldIgnoreRefusesBeforeWriting() async throws {
        try write(".gitignore", "*.png\n")
        try await commitAll("ignore png")
        let e = PlanExport(slug: "demo", files: [ExportedFile(path: "plan.md", data: Data("p".utf8)),
            ExportedFile(path: "visuals/a/snapshot@default-1x.png", data: Data("png".utf8))], warnings: [])
        await assertFails(.ignored(["docs/plans/demo/visuals/a/snapshot@default-1x.png"])) {
            _ = try await committer().commit(e, repo: repo)
        }
        XCTAssertFalse(exists("docs/plans/demo"))
    }

    func testABadSlugIsRefused() async {
        for bad in ["../x", "Demo", "a/b", "", "-a", "a--b", "a b"] {
            let e = PlanExport(slug: bad, files: [ExportedFile(path: "plan.md", data: Data())], warnings: [])
            await assertFails(.badSlug(bad)) { _ = try await committer().commit(e, repo: repo) }
        }
    }

    func testAFolderInsideAnOuterRepoIsNotARepoRoot() async throws {
        let inner = repo.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        do { _ = try await committer().commit(sample(), repo: inner); XCTFail() } catch RepoCommitter.Failure.notRepoRoot {}
        XCTAssertFalse(exists("sub/docs"))
    }

    func testABlockedHookTimesOutInsteadOfHanging() async throws {
        let hook = repo.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\nsleep 30\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let started = Date()
        await assertFails(.timeout(step: "commit")) {
            _ = try await RepoCommitter(runner: runner, gitTimeout: 1).commit(sample(), repo: repo)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
        XCTAssertFalse(exists("docs/plans/demo"), "rolled back")
    }

    // MARK: Safety review, fix round 2

    /// A swap in the gap between the checks and the act must not reach outside the repo.
    private func swapDocsForALink(to o: URL) {
        let docs = repo.appendingPathComponent("docs")
        try? FileManager.default.moveItem(at: docs, to: repo.appendingPathComponent("docs-moved"))
        try? FileManager.default.createSymbolicLink(at: docs, withDestinationURL: o)
    }
    private func assertOutsideUntouched(_ o: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(try? String(contentsOf: o.appendingPathComponent("plans/demo/keep.txt")), "precious", file: file, line: line)
        XCTAssertEqual(try? String(contentsOf: o.appendingPathComponent("plans/demo/plan.md")), "outside plan", file: file, line: line)
    }

    func testASwapBetweenCheckAndDeleteTouchesNothingOutside() async throws {
        let o = try makeOutside()
        try "outside plan".write(to: o.appendingPathComponent("plans/demo/plan.md"), atomically: true, encoding: .utf8)
        _ = try await committer().commit(sample(), repo: repo)
        var c = committer()
        c.onStage = { [self] stage in if stage == .checked { swapDocsForALink(to: o) } }
        _ = try? await c.commit(sample("plan v2"), repo: repo)
        assertOutsideUntouched(o)
    }

    func testASwapBeforeARollbackTouchesNothingOutside() async throws {
        let o = try makeOutside()
        try "outside plan".write(to: o.appendingPathComponent("plans/demo/plan.md"), atomically: true, encoding: .utf8)
        var c = committer()
        c.onStage = { [self] stage in if stage == .written { swapDocsForALink(to: o) } }
        // The new folder is written, then `add` fails because docs is now a link: the rollback runs.
        _ = try? await c.commit(sample(), repo: repo)
        assertOutsideUntouched(o)
    }

    func testAssumeUnchangedAndSkipWorktreeEditsAreRefused() async throws {
        for flag in ["--assume-unchanged", "--skip-worktree"] {
            _ = try await committer().commit(sample(flag), repo: repo)
            try await git("update-index", flag, "docs/plans/demo/plan.md")
            try write("docs/plans/demo/plan.md", "my edit \(flag)")
            do { _ = try await committer().commit(sample("other"), repo: repo); XCTFail("should refuse \(flag)") }
            catch let RepoCommitter.Failure.dirty(path, _) { XCTAssertEqual(path, "docs/plans/demo/plan.md") }
            XCTAssertEqual(read("docs/plans/demo/plan.md"), "my edit \(flag)")
            try await git("update-index", flag == "--assume-unchanged" ? "--no-assume-unchanged" : "--no-skip-worktree",
                          "docs/plans/demo/plan.md")
            try await git("checkout-index", "-f", "docs/plans/demo/plan.md")
        }
    }

    func testTheResultNamesWhatGitCommittedIncludingDeletions() async throws {
        _ = try await committer().commit(sample(), repo: repo)
        let v2 = PlanExport(slug: "demo", files: [ExportedFile(path: "plan.md", data: Data("plan v2".utf8)),
            ExportedFile(path: PlanExporter.markerName, data: Data("intake-1\n".utf8))], warnings: [])
        let r = try await committer().commit(v2, repo: repo)
        XCTAssertEqual(r.paths.sorted(), ["docs/plans/demo/plan.md", "docs/plans/demo/visuals/a/x.txt"])
        XCTAssertEqual(r.removed, ["docs/plans/demo/visuals/a/x.txt"])
    }

    func testThePreviewListsWhatAReReleaseWillRemove() async throws {
        _ = try await committer().commit(sample(), repo: repo)
        let v2 = PlanExport(slug: "demo", files: [ExportedFile(path: "plan.md", data: Data("v2".utf8))], warnings: [])
        let p = try await committer().preview(v2, repo: repo)
        XCTAssertEqual(p.removed, ["docs/plans/demo/.flightdeck-intake", "docs/plans/demo/visuals/a/x.txt"])
        XCTAssertEqual(p.paths, ["docs/plans/demo/plan.md"])
        let fresh = try await committer().preview(PlanExport(slug: "fresh", files: [], warnings: []), repo: repo)
        XCTAssertEqual(fresh.removed, [])
    }

    // MARK: Fix round 3

    func testAnUntrackedFileIsSeenEvenWhenGitIsToldToHideUntrackedFiles() async throws {
        try await git("config", "status.showUntrackedFiles", "no")
        _ = try await committer().commit(sample(), repo: repo)
        try write("docs/plans/demo/my-notes.txt", "mine")
        do { _ = try await committer().commit(sample("plan v2"), repo: repo); XCTFail("should refuse") }
        catch RepoCommitter.Failure.dirty {}
        XCTAssertEqual(read("docs/plans/demo/my-notes.txt"), "mine")
    }

    func testAFileIsNeverCreatedThroughAHardLink() throws {
        let o = try makeOutside()
        let target = o.appendingPathComponent("plans/demo/keep.txt")
        let dirURL = repo.appendingPathComponent("d", isDirectory: true)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        XCTAssertEqual(link(target.path, dirURL.appendingPathComponent("a.txt").path), 0)
        let dir = try SafeTree.openRoot(dirURL.path)
        XCTAssertThrowsError(try SafeTree.write(Data("EVIL".utf8), to: "a.txt", under: dir))
        XCTAssertEqual(try String(contentsOf: target), "precious")
    }

    private static let odd = ["a\"q\tb.txt", "n\nl.txt"]
    private func oddExport(_ body: String = "v1") -> PlanExport {
        PlanExport(slug: "demo", files: [ExportedFile(path: "plan.md", data: Data(body.utf8)),
            ExportedFile(path: PlanExporter.markerName, data: Data("intake-1\n".utf8))]
            + Self.odd.map { ExportedFile(path: "visuals/\($0)", data: Data("x".utf8)) }, warnings: [])
    }

    func testNamesWithQuotesTabsAndNewlinesComeBackExactly() async throws {
        let first = try await committer().commit(oddExport(), repo: repo)
        for n in Self.odd { XCTAssertTrue(first.paths.contains("docs/plans/demo/visuals/\(n)"), "\(first.paths)") }
        // A kept file is not "removed", and a dropped one is named as it is on disk.
        let p = try await committer().preview(oddExport("v2"), repo: repo)
        XCTAssertEqual(p.removed, [])
        let v2 = PlanExport(slug: "demo", files: [ExportedFile(path: "plan.md", data: Data("v2".utf8)),
            ExportedFile(path: PlanExporter.markerName, data: Data("intake-1\n".utf8))], warnings: [])
        let r = try await committer().commit(v2, repo: repo)
        XCTAssertEqual(r.removed.sorted(), Self.odd.map { "docs/plans/demo/visuals/\($0)" }.sorted())
    }

    func testAHiddenEditToAnOddlyNamedFileNamesItExactly() async throws {
        _ = try await committer().commit(oddExport(), repo: repo)
        let name = "docs/plans/demo/visuals/\(Self.odd[0])"
        try await git("update-index", "--assume-unchanged", name)
        do { _ = try await committer().commit(oddExport("v2"), repo: repo); XCTFail() }
        catch let RepoCommitter.Failure.dirty(path, _) { XCTAssertEqual(path, name) }
    }

    func testAnIgnoredOddlyNamedExportPathIsNamedExactly() async throws {
        try write(".gitignore", "*.png\n")
        try await commitAll("ignore")
        let name = "visuals/a\"q\nb.png"
        let e = PlanExport(slug: "demo", files: [ExportedFile(path: "plan.md", data: Data("p".utf8)),
                                                 ExportedFile(path: name, data: Data("x".utf8))], warnings: [])
        await assertFails(.ignored(["docs/plans/demo/\(name)"])) { _ = try await committer().commit(e, repo: repo) }
    }

    /// A batch `check-ignore` that git itself fails (not "ignored", not "not ignored") reports
    /// git's own words, so the release names what went wrong.
    func testABatchCheckIgnoreErrorCarriesGitsStderr() async throws {
        let failing = CheckIgnoreFailingRunner(real: runner)
        do {
            _ = try await RepoCommitter(runner: failing).commit(sample(), repo: repo)
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual(error as? RepoCommitter.Failure, .git(step: "check-ignore", stderr: "fatal: index file corrupt\n"))
        }
        XCTAssertFalse(exists("docs/plans/demo/plan.md"), "refused before anything was written")
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
    var top = ""
    struct Call { var arguments: [String]; var environment: [String: String] }
    private(set) var calls: [Call] = []
    func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
             processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?) async throws -> CommandResult {
        calls.append(Call(arguments: arguments, environment: environment))
        // Answers the way a clean repo at `top` does, so the commit gets as far as its pathspecs.
        var out = ""
        var code: Int32 = 0
        if arguments.contains("--show-toplevel") { out = top }
        if arguments.contains("check-ignore") { code = 1 }
        return CommandResult(stdout: Data(out.utf8), stderr: "", exitCode: code)
    }
}

/// Real git for everything except a batch `check-ignore`, which fails the way a broken index does.
private struct CheckIgnoreFailingRunner: CommandRunner {
    let real: CommandRunner
    func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
             processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?) async throws -> CommandResult {
        if arguments.contains("check-ignore"), !arguments.contains("-q") {
            return CommandResult(stdout: Data(), stderr: "fatal: index file corrupt\n", exitCode: 128)
        }
        return try await real.run(executable: executable, arguments: arguments, cwd: cwd, environment: environment,
                                  processGroup: processGroup, onSpawn: onSpawn)
    }
}
