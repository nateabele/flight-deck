import XCTest
@testable import HostKit

/// A real git repository in a fresh temporary directory. Setup runs git directly through
/// `Process`, not through `GitRunner`, so a bug in the unit under test cannot also corrupt the
/// fixture it is judged against.
final class TempRepo {
    let url: URL

    /// A unique scratch directory, removed by nothing: the OS reaps temp, and a failing test's
    /// leftovers are what you want to look at.
    static func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fd-sync-\(UUID().uuidString.prefix(8))")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // The canonical path, so it compares equal to what `git rev-parse --show-toplevel`
        // reports (macOS's temp lives behind the /var -> /private/var symlink).
        return url.resolvingSymlinksInPath()
    }

    init(at url: URL = TempRepo.scratch().appendingPathComponent("repo")) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git("init", "-q")
    }

    /// Fixture git: no system or global config (so the developer's own `~/.gitconfig` cannot
    /// change what the fixture contains), a fixed identity, and file-URL submodules allowed.
    @discardableResult
    func git(_ args: String..., input: String? = nil) throws -> String {
        try TempRepo.git(args, in: url, input: input)
    }

    @discardableResult
    static func git(_ args: [String], in dir: URL, input: String? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_AUTHOR_NAME"] = "Test"; env["GIT_AUTHOR_EMAIL"] = "test@example.com"
        env["GIT_COMMITTER_NAME"] = "Test"; env["GIT_COMMITTER_EMAIL"] = "test@example.com"
        env["GIT_CONFIG_COUNT"] = "2"
        env["GIT_CONFIG_KEY_0"] = "protocol.file.allow"; env["GIT_CONFIG_VALUE_0"] = "always"
        env["GIT_CONFIG_KEY_1"] = "init.defaultBranch"; env["GIT_CONFIG_VALUE_1"] = "main"
        p.environment = env
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = inp
        try p.run()
        if let input { inp.fileHandleForWriting.write(Data(input.utf8)) }
        try inp.fileHandleForWriting.close()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "TempRepo", code: Int(p.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")): \(String(decoding: e, as: UTF8.self))"])
        }
        return String(decoding: o, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ path: String, _ text: String) {
        let file = url.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: file)
    }

    func write(_ path: String, _ data: Data) {
        let file = url.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: file)
    }

    func read(_ path: String) -> String? {
        (try? Data(contentsOf: url.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    func remove(_ path: String) { try? FileManager.default.removeItem(at: url.appendingPathComponent(path)) }

    func commitAll(_ message: String = "c") throws {
        try git("add", "-A")
        try git("commit", "-q", "-m", message)
    }

    /// The file at `path` in `commit`'s tree, or nil when the tree has no such path.
    func show(_ commit: String, _ path: String) -> String? {
        try? git("show", "\(commit):\(path)")
    }

    /// Every path in `commit`'s tree.
    func paths(_ commit: String) throws -> [String] {
        try git("ls-tree", "-r", "--name-only", commit).split(separator: "\n").map(String.init)
    }
}

/// The error `body` throws, or nil. `XCTAssertThrowsError` takes no async expression.
func thrown<T>(_ body: () async throws -> T) async -> Error? {
    do { _ = try await body(); return nil } catch { return error }
}

/// `n` bytes no compressor can shrink, so bundle sizes measure what was actually sent.
func incompressible(_ n: Int) -> Data {
    var rng = SystemRandomNumberGenerator()
    return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) })
}

final class SnapshotterTests: XCTestCase {
    let controller = UUID()

    // MARK: - Snapshot (§4.2)

    /// The headline guarantee of §4.2: delegating never shows up in the user's own git state.
    /// A snapshot that wrote the real index would silently unstage a half-staged file; one that
    /// went through `stash` would reorder their stash list.
    func testSnapshotLeavesIndexStashReflogUntouched() async throws {
        let repo = try TempRepo()
        repo.write("a.txt", "a1\n"); repo.write("b.txt", "b1\n")
        try repo.commitAll()
        repo.write("a.txt", "stashed\n")
        try repo.git("stash", "-q")
        repo.write("b.txt", "staged\n")
        try repo.git("add", "b.txt")
        repo.write("b.txt", "unstaged\n")
        repo.write("u.txt", "untracked\n")

        let git = repo.url.appendingPathComponent(".git")
        let before = (
            index: try Data(contentsOf: git.appendingPathComponent("index")),
            stash: try repo.git("stash", "list"),
            reflog: try Data(contentsOf: git.appendingPathComponent("logs/HEAD")),
            branchLog: try Data(contentsOf: git.appendingPathComponent("logs/refs/heads/main")),
            refs: try repo.git("for-each-ref", "refs/heads", "refs/tags", "refs/stash"),
            status: try repo.git("status", "--porcelain")
        )
        let head = try repo.git("rev-parse", "HEAD")

        let ref = try await Snapshotter().snapshot(worktree: repo.url, host: "mini", include: [])

        XCTAssertEqual(try Data(contentsOf: git.appendingPathComponent("index")), before.index)
        XCTAssertEqual(try repo.git("stash", "list"), before.stash)
        XCTAssertEqual(try Data(contentsOf: git.appendingPathComponent("logs/HEAD")), before.reflog)
        XCTAssertEqual(try Data(contentsOf: git.appendingPathComponent("logs/refs/heads/main")), before.branchLog)
        XCTAssertEqual(try repo.git("for-each-ref", "refs/heads", "refs/tags", "refs/stash"), before.refs)
        XCTAssertEqual(try repo.git("status", "--porcelain"), before.status)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: git.path).filter { $0.contains("flightdeck") }
        XCTAssertEqual(leftovers, [], "the temporary index must not outlive the snapshot")

        // The snapshot is the working tree, not the index: the unstaged edit wins.
        XCTAssertEqual(repo.show(ref.commit, "b.txt"), "unstaged")
        XCTAssertEqual(repo.show(ref.commit, "a.txt"), "a1")
        XCTAssertEqual(repo.show(ref.commit, "u.txt"), "untracked")
        XCTAssertEqual(try repo.git("rev-parse", "\(ref.commit)^"), head)
        XCTAssertEqual(try repo.git("rev-parse", "\(ref.commit)^{tree}"), ref.tree)
        XCTAssertEqual(try repo.git("rev-parse", "refs/flightdeck/snapshots/mini/1"), ref.commit)
        XCTAssertEqual(ref.repoRoot, head)
        XCTAssertEqual(ref.worktreeName, "repo")
        XCTAssertEqual(ref.wtKey, Snapshotter.wtKey(forPath: try repo.git("rev-parse", "--show-toplevel")))
    }

    /// An `assume-unchanged` bit in the user's index must not hide that file's edit from the
    /// snapshot. The stat-cache fast path copies the user's index, and `read-tree -m` carries
    /// the bit over, which would ship the committed content instead of the edit.
    func testAssumeUnchangedEditIsStillSnapshotted() async throws {
        let repo = try TempRepo()
        repo.write("a.txt", "a1\n")
        try repo.commitAll()
        try repo.git("update-index", "--assume-unchanged", "a.txt")
        repo.write("a.txt", "edited\n")

        let ref = try await Snapshotter().snapshot(worktree: repo.url, host: "mini", include: [])

        XCTAssertEqual(repo.show(ref.commit, "a.txt"), "edited")
    }

    /// A same-size edit in the same second as the last index write is "racily clean": only
    /// git's racy-index check (entry mtime >= index file mtime) makes it re-read the file. A
    /// copied index that does not keep the original's mtime looks newer than its entries, so
    /// the edit is invisible and the snapshot silently ships the old content. Linux's
    /// `copyItem` does not keep mtimes; this caught it there.
    func testSameSizeEditInTheIndexSecondIsSnapshotted() async throws {
        let repo = try TempRepo()
        let index = repo.url.appendingPathComponent(".git/index")
        for attempt in 0..<10 {
            repo.write("a.txt", "a\(attempt % 10)\n")
            try repo.commitAll()
            repo.write("a.txt", "zz\n")
            let indexTime = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
            if let t = indexTime, Int(t.timeIntervalSince1970) == Int(Date().timeIntervalSince1970) { break }
        }
        // The snapshot must land in a later second: a copy made now carries a newer mtime than
        // the entry, which is exactly what makes a stale stat look trustworthy.
        try await Task.sleep(nanoseconds: 1_200_000_000)

        let ref = try await Snapshotter().snapshot(worktree: repo.url, host: "mini", include: [])

        XCTAssertEqual(repo.show(ref.commit, "a.txt"), "zz")
    }

    func testIncludeForceAddsIgnored() async throws {
        let repo = try TempRepo()
        repo.write(".gitignore", ".env\nbuild/\n")
        repo.write("a.txt", "a\n")
        try repo.commitAll()
        repo.write(".env", "SECRET=1\n")
        repo.write("build/x.o", "obj\n")

        // A missing include is skipped, not fatal: one config's `include` list serves every
        // worktree, and not all of them have every file.
        let ref = try await Snapshotter().snapshot(worktree: repo.url, host: "mini", include: [".env", "missing.txt"])

        XCTAssertEqual(repo.show(ref.commit, ".env"), "SECRET=1")
        XCTAssertNil(repo.show(ref.commit, "build/x.o"))
    }

    func testUntrackedIncludedIgnoredExcluded() async throws {
        let repo = try TempRepo()
        repo.write(".gitignore", "*.log\n")
        repo.write("a.txt", "a\n"); repo.write("gone.txt", "g\n")
        try repo.commitAll()
        repo.write("new.txt", "n\n")
        repo.write("debug.log", "noise\n")
        repo.remove("gone.txt")

        let ref = try await Snapshotter().snapshot(worktree: repo.url, host: "mini", include: [])

        XCTAssertEqual(try repo.paths(ref.commit).sorted(), [".gitignore", "a.txt", "new.txt"])
    }

    /// The same HEAD and the same files give the same commit, so a re-run of an unchanged tree
    /// shares the host's checkout slot instead of taking a second one (§4.6).
    func testUnchangedTreeGivesTheSameCommit() async throws {
        let repo = try TempRepo()
        repo.write("a.txt", "a\n")
        try repo.commitAll()
        repo.write("a.txt", "edit\n")
        let s = Snapshotter()
        let first = try await s.snapshot(worktree: repo.url, host: "mini", include: [])
        let second = try await s.snapshot(worktree: repo.url, host: "mini", include: [])
        XCTAssertEqual(first.commit, second.commit)
    }

    func testSnapshotRefsTrimmedToK() async throws {
        let repo = try TempRepo()
        repo.write("a.txt", "a\n")
        try repo.commitAll()
        let s = Snapshotter()
        var last: SnapshotRef?
        for i in 1...7 {
            repo.write("a.txt", "\(i)\n")
            last = try await s.snapshot(worktree: repo.url, host: "mini", include: [])
        }
        let refs = try repo.git("for-each-ref", "--format=%(refname)", "refs/flightdeck/snapshots/mini/")
            .split(separator: "\n").map(String.init).sorted()
        XCTAssertEqual(refs, (3...7).map { "refs/flightdeck/snapshots/mini/\($0)" }.sorted())
        XCTAssertEqual(try repo.git("rev-parse", "refs/flightdeck/snapshots/mini/7"), last?.commit)
    }

    func testLFSRefused() async throws {
        let repo = try TempRepo()
        repo.write(".gitattributes", "*.bin filter=lfs diff=lfs merge=lfs -text\n")
        repo.write("a.bin", "pointer\n")
        try repo.commitAll()

        let error = await thrown { try await Snapshotter().snapshot(worktree: repo.url, host: "mini", include: []) }
        XCTAssertEqual(error as? SyncError, .lfsUnsupported)
        XCTAssertEqual((error as? SyncError)?.code, "lfs_unsupported")
        XCTAssertEqual(error.map { "\($0)" }, "LFS repos are not supported for delegation yet")
        XCTAssertEqual(try repo.git("for-each-ref", "refs/flightdeck/"), "", "a refused snapshot records nothing")
    }

    /// The root commit cache must not outlive the repository it describes: a repo re-created
    /// at the same path (a fresh clone, `rm -rf` + `init`) has a different root and must name
    /// a different host store.
    func testRootCommitCacheFollowsTheRepositoryNotThePath() async throws {
        let scratch = TempRepo.scratch()
        let path = scratch.appendingPathComponent("repo")
        let first = try TempRepo(at: path)
        first.write("a.txt", "one\n")
        try first.commitAll("one")
        let r1 = try await Snapshotter().snapshot(worktree: path, host: "mini", include: [])
        // Moved, not deleted, so its .git keeps its inode and the new one cannot reuse it.
        try FileManager.default.moveItem(at: path, to: scratch.appendingPathComponent("old"))
        let second = try TempRepo(at: path)
        second.write("b.txt", "two\n")
        try second.commitAll("two")

        let r2 = try await Snapshotter().snapshot(worktree: path, host: "mini", include: [])

        XCTAssertEqual(r2.repoRoot, try second.git("rev-parse", "HEAD"))
        XCTAssertNotEqual(r2.repoRoot, r1.repoRoot)
    }

    /// LFS is refused *before* `add`: with git-lfs installed, `add` runs its clean filter over
    /// every matching file (slow, and it writes LFS objects into the user's repo) only to be
    /// refused afterwards. The filter here leaves a marker if it ever runs.
    func testLFSRefusedBeforeTheCleanFilterRuns() async throws {
        let repo = try TempRepo()
        repo.write("a.txt", "a\n")
        try repo.commitAll()
        let marker = repo.url.deletingLastPathComponent().appendingPathComponent("clean-filter-ran")
        // Both keys: an installed git-lfs sets `filter.lfs.process` globally, and it wins over
        // `clean`, so overriding only `clean` would test nothing on a machine that has git-lfs.
        try repo.git("config", "filter.lfs.clean", "touch '\(marker.path)'; cat")
        try repo.git("config", "filter.lfs.process", "sh -c 'touch \"\(marker.path)\"; exit 1'")
        repo.write(".gitattributes", "*.bin filter=lfs\n")
        repo.write("new.bin", "data\n")

        let error = await thrown { try await Snapshotter().snapshot(worktree: repo.url, host: "mini", include: []) }

        XCTAssertEqual(error as? SyncError, .lfsUnsupported)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the LFS clean filter must never run")
    }

    /// An agent can run `flightdeck run` from inside a git hook, where GIT_DIR and
    /// GIT_INDEX_FILE point at the user's own repo and index. Inherited, they would aim the
    /// snapshot's temporary index at the user's real one.
    func testInheritedGitEnvironmentIsScrubbed() async throws {
        let repo = try TempRepo()
        repo.write("a.txt", "a\n")
        try repo.commitAll()
        repo.write("a.txt", "edit\n")
        let decoy = TempRepo.scratch()
        setenv("GIT_DIR", decoy.path, 1)
        setenv("GIT_INDEX_FILE", decoy.appendingPathComponent("index").path, 1)
        setenv("GIT_WORK_TREE", decoy.path, 1)
        let git = GitRunner()
        unsetenv("GIT_DIR"); unsetenv("GIT_INDEX_FILE"); unsetenv("GIT_WORK_TREE")

        let ref = try await Snapshotter(git: git).snapshot(worktree: repo.url, host: "mini", include: [])

        XCTAssertEqual(repo.show(ref.commit, "a.txt"), "edit")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: decoy.path), [])
    }

    // Submodules: `SubmoduleSyncTests` (they used to be refused here, before §4.2 step 4).

    // MARK: - Transfer (§4.3)

    /// The second sync of the same HEAD must carry only the working-copy delta. Without the
    /// `--not` tips every run would re-send the whole history, and a big repo would take
    /// minutes before its command starts.
    func testBundleIsDeltaOnSharedBase() async throws {
        let repo = try TempRepo()
        repo.write("big.bin", incompressible(512 * 1024))
        repo.write("small.txt", "1\n")
        try repo.commitAll()
        let snap = Snapshotter(), bundler = BundleMaker()
        let store = Workspace(root: TempRepo.scratch())

        let s1 = try await snap.snapshot(worktree: repo.url, host: "mini", include: [])
        let full = try await bundler.bundle(worktree: repo.url, snapshot: s1, haves: [])
        try await store.receive(controller: controller, bundle: full, ref: s1)

        repo.write("small.txt", "2\n")
        let s2 = try await snap.snapshot(worktree: repo.url, host: "mini", include: [])
        let tips = try await store.tips(controller: controller, repoRoot: s2.repoRoot, wtKey: s2.wtKey)
        XCTAssertTrue(tips.contains(s1.commit))
        let delta = try await bundler.bundle(worktree: repo.url, snapshot: s2, haves: tips)

        let fullSize = try size(full), deltaSize = try size(delta)
        XCTAssertGreaterThan(fullSize, 512 * 1024)
        XCTAssertLessThan(deltaSize, fullSize / 20, "delta \(deltaSize) vs full \(fullSize)")

        try await store.receive(controller: controller, bundle: delta, ref: s2)
        let lease = try await store.checkout(controller: controller, ref: s2, pin: false)
        XCTAssertEqual(try String(contentsOf: lease.path.appendingPathComponent("small.txt"), encoding: .utf8), "2\n")
    }

    /// After a rebase the host's tips are no longer ancestors of the new snapshot. The bundle
    /// must still apply: git finds the merge-base from the `--not` list itself.
    func testBundleAfterRebase() async throws {
        let repo = try TempRepo()
        repo.write("a.txt", "base\n")
        try repo.commitAll("c0")
        try repo.git("checkout", "-q", "-b", "feature")
        repo.write("f.txt", "feature\n")
        try repo.commitAll("c1")
        let snap = Snapshotter(), bundler = BundleMaker()
        let store = Workspace(root: TempRepo.scratch())

        let s1 = try await snap.snapshot(worktree: repo.url, host: "mini", include: [])
        try await store.receive(controller: controller, bundle: try await bundler.bundle(worktree: repo.url, snapshot: s1, haves: []), ref: s1)

        try repo.git("checkout", "-q", "main")
        repo.write("up.txt", "upstream\n")
        try repo.commitAll("c2")
        try repo.git("checkout", "-q", "feature")
        try repo.git("rebase", "-q", "main")
        repo.write("f.txt", "edited after rebase\n")

        let s2 = try await snap.snapshot(worktree: repo.url, host: "mini", include: [])
        let tips = try await store.tips(controller: controller, repoRoot: s2.repoRoot, wtKey: s2.wtKey)
        let bundle = try await bundler.bundle(worktree: repo.url, snapshot: s2, haves: tips + ["0123456789abcdef0123456789abcdef01234567"])
        try await store.receive(controller: controller, bundle: bundle, ref: s2)
        let lease = try await store.checkout(controller: controller, ref: s2, pin: false)

        XCTAssertEqual(try String(contentsOf: lease.path.appendingPathComponent("up.txt"), encoding: .utf8), "upstream\n")
        XCTAssertEqual(try String(contentsOf: lease.path.appendingPathComponent("f.txt"), encoding: .utf8), "edited after rebase\n")
    }

    private func size(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }
}

final class GitRunnerTests: XCTestCase {
    /// Open descriptors: on Linux only pipes, the kind a git call opens, because other suites'
    /// sockets and dispatch's own descriptors come and go in the background and would make a
    /// whole-process count measure them instead.
    func openFDs() -> Int {
        #if os(Linux)
        let fds = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")) ?? []
        return fds.filter { ((try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\($0)")) ?? "").hasPrefix("pipe:") }.count
        #else
        return ((try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []).count
        #endif
    }

    /// `merge-tree --write-tree --merge-base` (apply) needs 2.40; an older git would fail
    /// mid-apply with a usage error instead of saying what is wrong.
    func testVersionGate() {
        XCTAssertTrue(GitRunner.isSupported(versionOutput: "git version 2.40.0"))
        XCTAssertTrue(GitRunner.isSupported(versionOutput: "git version 2.50.1 (Apple Git-155)"))
        XCTAssertTrue(GitRunner.isSupported(versionOutput: "git version 3.0.0"))
        XCTAssertFalse(GitRunner.isSupported(versionOutput: "git version 2.39.5"))
        XCTAssertFalse(GitRunner.isSupported(versionOutput: "git version 1.9.1"))
        XCTAssertFalse(GitRunner.isSupported(versionOutput: "nonsense"))
        XCTAssertEqual(SyncError.gitTooOld("2.39.5").code, "git_too_old")
    }

    /// A timed-out git whose grandchild still holds the pipes must not leak them for good:
    /// a host that times out now and then would creep towards the fd limit.
    func testTimeoutPathReleasesPipes() async throws {
        let git = GitRunner(timeout: 0.5)
        let before = openFDs()
        let start = Date()
        XCTAssertThrowsError(try git.run(["-c", "alias.hang=!sleep 2", "hang"])) { error in
            guard case .timedOut? = error as? GitError else { return XCTFail("\(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
        for _ in 0..<100 where openFDs() > before { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertLessThanOrEqual(openFDs(), before)
    }

    /// One failed `git --version` (a transient fork failure, a wrapper's hiccup) must not be
    /// cached as "too old" and refuse every sync until the process restarts.
    func testFailedVersionProbeIsNotCached() throws {
        let dir = TempRepo.scratch()
        let marker = dir.appendingPathComponent("first")
        let script = dir.appendingPathComponent("git")
        let real = try TempRepo.git(["--exec-path"], in: dir)   // proves a real git exists
        XCTAssertFalse(real.isEmpty)
        let gitPath = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"].first { FileManager.default.isExecutableFile(atPath: $0) }!
        try "#!/bin/sh\nif [ ! -e '\(marker.path)' ]; then touch '\(marker.path)'; exit 1; fi\nexec \(gitPath) \"$@\"\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let old = ProcessInfo.processInfo.environment["PATH"]!
        setenv("PATH", "\(dir.path):\(old)", 1)
        let git = GitRunner()
        setenv("PATH", old, 1)

        for _ in 0..<3 {
            XCTAssertTrue(try git.text(["--version"]).hasPrefix("git version"))
        }
    }

    /// Children the process spawns later (the hostd's runs and services) must get SIGPIPE's
    /// default action: an ignored SIGPIPE is inherited across exec, and `producer | head`
    /// would then spin on EPIPE instead of dying quietly.
    func testChildrenKeepDefaultSIGPIPE() throws {
        _ = try GitRunner().run(["hash-object", "--stdin"], input: Data(count: 1 << 20))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "kill -PIPE $$; echo survived"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        XCTAssertEqual(text, "", "the child ignored SIGPIPE: it was inherited")
    }

    /// git exiting without reading its stdin must not kill the caller with SIGPIPE: in the
    /// hostd that is every run and every service on the host.
    func testUnreadStdinDoesNotRaiseSIGPIPE() throws {
        let out = try GitRunner().run(["--version"], input: Data(count: 4 << 20))
        XCTAssertTrue(out.text.hasPrefix("git version"))
    }
}
