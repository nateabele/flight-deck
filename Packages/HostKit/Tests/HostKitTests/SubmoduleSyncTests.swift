import XCTest
@testable import HostKit

/// Submodules through the whole sync (spec §4.2 step 4): the controller pins each gitlink with
/// its URL, the host brings every submodule to its pin from a per-repo cache, and nothing
/// inside a submodule comes back in a result. Real git, real bare "remotes", in temp dirs.
final class SubmoduleSyncTests: XCTestCase {
    let controller = UUID()

    // MARK: - Fixtures

    /// A bare repository standing in for a submodule's remote, plus the working clone that
    /// pushes to it. `scratch/<name>.git` is the URL a superproject records.
    struct Remote {
        let bare: URL
        let work: TempRepo

        /// Commits `files` in the working clone and pushes them, so the remote's tip moves on.
        @discardableResult
        func advance(_ files: [String: String]) throws -> String {
            for (path, text) in files { work.write(path, text) }
            try work.commitAll()
            try work.git("push", "-q", "origin", "HEAD:main")
            return try work.git("rev-parse", "HEAD")
        }
    }

    func makeRemote(_ name: String, in scratch: URL, _ files: [String: String]) throws -> Remote {
        let work = try TempRepo(at: scratch.appendingPathComponent("\(name)-work"))
        for (path, text) in files { work.write(path, text) }
        try work.commitAll()
        let bare = scratch.appendingPathComponent("\(name).git")
        try TempRepo.git(["clone", "-q", "--bare", work.url.path, bare.path], in: scratch)
        try work.git("remote", "add", "origin", bare.path)
        try work.git("fetch", "-q", "origin")
        return Remote(bare: bare, work: work)
    }

    /// `app` with one submodule `lib` from its own bare remote, committed at lib's first commit.
    /// The remote then moves past that commit, so a host that fetched "the tip" instead of the
    /// pin would check out the wrong code and every test below would see it.
    func makeApp(in scratch: URL) throws -> (app: TempRepo, lib: Remote, pin: String) {
        let lib = try makeRemote("lib", in: scratch, ["lib.txt": "v1\n"])
        let pin = try lib.work.git("rev-parse", "HEAD")
        let app = try TempRepo(at: scratch.appendingPathComponent("app"))
        app.write("main.txt", "main\n")
        try app.git("submodule", "add", "-q", lib.bare.path, "lib")
        try app.commitAll()
        try lib.advance(["lib.txt": "v2\n"])
        return (app, lib, pin)
    }

    @discardableResult
    func push(_ repo: TempRepo, to store: Workspace) async throws -> SnapshotRef {
        let ref = try await Snapshotter().snapshot(worktree: repo.url, host: "mini", include: [])
        let tips = try await store.tips(controller: controller, repoRoot: ref.repoRoot, wtKey: ref.wtKey)
        let bundle = try await BundleMaker().bundle(worktree: repo.url, snapshot: ref, haves: tips)
        defer { try? FileManager.default.removeItem(at: bundle) }
        try await store.receive(controller: controller, bundle: bundle, ref: ref)
        return ref
    }

    func text(_ lease: CheckoutLease, _ path: String) -> String? {
        (try? Data(contentsOf: lease.path.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    func head(_ lease: CheckoutLease, _ path: String) throws -> String {
        try TempRepo.git(["rev-parse", "HEAD"], in: lease.path.appendingPathComponent(path))
    }

    // MARK: - Controller (§4.2)

    /// The snapshot names each gitlink's path, pinned commit and URL, which is everything the
    /// host needs: it has neither the controller's `.git/config` nor network access to it.
    func testSnapshotRecordsEachSubmodulesPin() async throws {
        let (app, lib, pin) = try makeApp(in: TempRepo.scratch())
        let ref = try await Snapshotter().snapshot(worktree: app.url, host: "mini", include: [])
        XCTAssertEqual(ref.submodules, [SubmodulePin(path: "lib", commit: pin, url: lib.bare.path)])
    }

    /// Uncommitted work inside a submodule cannot reach the host (only the pinned commit
    /// travels), so a run would silently test the wrong code. Refused before anything is
    /// recorded or sent, naming the submodule so the user knows where to look.
    func testDirtySubmoduleIsRefusedNamingItsPath() async throws {
        let (app, _, _) = try makeApp(in: TempRepo.scratch())
        app.write("lib/lib.txt", "edited inside the submodule\n")

        let error = await thrown { try await Snapshotter().snapshot(worktree: app.url, host: "mini", include: []) }
        XCTAssertEqual(error as? SyncError, .submodule(path: "lib", problem: .dirty))
        XCTAssertEqual((error as? SyncError)?.code, "submodule_dirty")
        let message = "\(error.map { "\($0)" } ?? "")"
        XCTAssertTrue(message.contains("lib"), message)
        XCTAssertTrue(message.contains("commit"), "the message says what to do: \(message)")
        XCTAssertEqual(try app.git("for-each-ref", "refs/flightdeck/"), "", "a refused snapshot records nothing")
    }

    /// An untracked file inside the submodule is uncommitted work too.
    func testUntrackedFileInSubmoduleIsDirty() async throws {
        let (app, _, _) = try makeApp(in: TempRepo.scratch())
        app.write("lib/new.txt", "new\n")
        let error = await thrown { try await Snapshotter().snapshot(worktree: app.url, host: "mini", include: []) }
        XCTAssertEqual(error as? SyncError, .submodule(path: "lib", problem: .dirty))
    }

    /// A commit made inside the submodule and never pushed exists only on this machine: the
    /// host's fetch could never find it. Refused up front instead of after a long sync.
    func testUnpushedSubmoduleCommitIsRefused() async throws {
        let (app, _, _) = try makeApp(in: TempRepo.scratch())
        let sub = TempRepo.git(_:in:input:)
        app.write("lib/lib.txt", "local only\n")
        try sub(["commit", "-q", "-am", "local"], app.url.appendingPathComponent("lib"), nil)
        let local = try sub(["rev-parse", "HEAD"], app.url.appendingPathComponent("lib"), nil)

        let error = await thrown { try await Snapshotter().snapshot(worktree: app.url, host: "mini", include: []) }
        XCTAssertEqual(error as? SyncError, .submodule(path: "lib", problem: .unpushed(commit: local)))
        XCTAssertEqual((error as? SyncError)?.code, "submodule_unpushed")
        XCTAssertTrue("\(error!)".contains("push"), "\(error!)")
    }

    /// A nested repository that is not a registered submodule has no URL anywhere: refused by
    /// name instead of arriving on the host as an empty directory.
    func testEmbeddedRepositoryWithoutURLIsRefused() async throws {
        let app = try TempRepo()
        app.write("main.txt", "main\n")
        try app.commitAll()
        let inner = try TempRepo(at: app.url.appendingPathComponent("inner"))
        inner.write("x.txt", "x\n")
        try inner.commitAll()

        let error = await thrown { try await Snapshotter().snapshot(worktree: app.url, host: "mini", include: []) }
        XCTAssertEqual(error as? SyncError, .submodule(path: "inner", problem: .noURL))
    }

    /// A relative URL in `.gitmodules` is relative to the superproject's remote, which only
    /// the controller knows; it must be resolved before it travels.
    func testRelativeSubmoduleURLIsResolvedAgainstTheSuperprojectRemote() async throws {
        let scratch = TempRepo.scratch()
        let lib = try makeRemote("lib", in: scratch, ["lib.txt": "v1\n"])
        let appRemote = try makeRemote("app", in: scratch, ["main.txt": "main\n"])
        let app = appRemote.work
        try app.git("submodule", "add", "-q", "../lib.git", "lib")
        try app.commitAll()
        XCTAssertTrue(try app.git("config", "-f", ".gitmodules", "submodule.lib.url") == "../lib.git")

        let ref = try await Snapshotter().snapshot(worktree: app.url, host: "mini", include: [])
        XCTAssertEqual(ref.submodules.map(\.url), [lib.bare.path])
    }

    func testRelativeURLResolution() {
        XCTAssertEqual(SubmoduleURL.resolve("../lib.git", against: "https://example.com/org/app.git"),
                       "https://example.com/org/lib.git")
        XCTAssertEqual(SubmoduleURL.resolve("./lib.git", against: "https://example.com/org/app.git/"),
                       "https://example.com/org/app.git/lib.git")
        XCTAssertEqual(SubmoduleURL.resolve("../../other/lib.git", against: "https://example.com/org/app.git"),
                       "https://example.com/other/lib.git")
        XCTAssertEqual(SubmoduleURL.resolve("../lib.git", against: "git@example.com:org/app.git"),
                       "git@example.com:org/lib.git")
        XCTAssertEqual(SubmoduleURL.resolve("../lib.git", against: "git@example.com:app.git"),
                       "git@example.com:lib.git")
        XCTAssertEqual(SubmoduleURL.resolve("https://example.com/x.git", against: "https://example.com/org/app.git"),
                       "https://example.com/x.git", "an absolute URL is left alone")
        XCTAssertEqual(SubmoduleURL.resolve("../lib.git", against: "/srv/git/app.git"), "/srv/git/lib.git")
    }

    // MARK: - Host (§4.4)

    /// The headline: a superproject with a submodule snapshots, transfers, and checks out with
    /// the submodule at its pinned commit, not its remote's newer tip.
    func testSubmoduleChecksOutAtItsPinnedCommit() async throws {
        let scratch = TempRepo.scratch()
        let (app, _, pin) = try makeApp(in: scratch)
        let store = Workspace(root: scratch.appendingPathComponent("host"))
        let ref = try await push(app, to: store)

        let lease = try await store.checkout(controller: controller, ref: ref, pin: false)
        XCTAssertEqual(text(lease, "main.txt"), "main\n")
        XCTAssertEqual(text(lease, "lib/lib.txt"), "v1\n", "the pin, not the remote's tip")
        XCTAssertEqual(try head(lease, "lib"), pin)
        XCTAssertEqual(try TempRepo.git(["status", "--porcelain"], in: lease.path), "",
                       "the superproject sees its submodule at the recorded commit")
    }

    /// A second run fetches nothing: the first one left the commit in the host's cache, so the
    /// remote being gone (offline, or a slow server) costs nothing.
    func testSecondRunReusesTheCache() async throws {
        let scratch = TempRepo.scratch()
        let (app, lib, pin) = try makeApp(in: scratch)
        let root = scratch.appendingPathComponent("host")
        let store = Workspace(root: root, poolSize: 2)
        let first = try await store.checkout(controller: controller, ref: try await push(app, to: store), pin: false)
        let caches = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("submodules/\(controller.uuidString)").path)
        XCTAssertEqual(caches.count, 1, "one cache per submodule repository: \(caches)")

        // Unreachable from here on: only the cache can satisfy the next checkout.
        try FileManager.default.moveItem(at: lib.bare, to: scratch.appendingPathComponent("moved.git"))
        app.write("main.txt", "second\n")
        try app.commitAll()
        let second = try await store.checkout(controller: controller, ref: try await push(app, to: store), pin: false)
        XCTAssertNotEqual(first.slot, second.slot, "a fresh slot, so the submodule really was placed again")
        XCTAssertEqual(text(second, "lib/lib.txt"), "v1\n")
        XCTAssertEqual(try head(second, "lib"), pin)
    }

    /// Moving the pin forward in the same slot updates the submodule in place.
    func testReapplyMovesTheSubmoduleToTheNewPin() async throws {
        let scratch = TempRepo.scratch()
        let (app, lib, _) = try makeApp(in: scratch)
        let store = Workspace(root: scratch.appendingPathComponent("host"), poolSize: 1)
        let first = try await store.checkout(controller: controller, ref: try await push(app, to: store), pin: false)
        await store.release(first)

        let tip = try lib.work.git("rev-parse", "HEAD")
        let sub = app.url.appendingPathComponent("lib")
        try TempRepo.git(["fetch", "-q", "origin"], in: sub)
        try TempRepo.git(["checkout", "-q", tip], in: sub)
        try app.commitAll()
        let second = try await store.checkout(controller: controller, ref: try await push(app, to: store), pin: false)
        XCTAssertEqual(second.slot, first.slot)
        XCTAssertEqual(text(second, "lib/lib.txt"), "v2\n")
        XCTAssertEqual(try head(second, "lib"), tip)
    }

    /// A submodule removed from the superproject goes from the slot too. git leaves a
    /// populated submodule directory behind on checkout, and the next result's `add -A` would
    /// commit it back as a gitlink the user deleted.
    func testRemovedSubmoduleLeavesTheSlot() async throws {
        let scratch = TempRepo.scratch()
        let (app, _, _) = try makeApp(in: scratch)
        let store = Workspace(root: scratch.appendingPathComponent("host"), poolSize: 1)
        let first = try await store.checkout(controller: controller, ref: try await push(app, to: store), pin: false)
        XCTAssertEqual(text(first, "lib/lib.txt"), "v1\n")
        await store.release(first)

        try app.git("rm", "-q", "lib")
        try app.commitAll()
        let second = try await store.checkout(controller: controller, ref: try await push(app, to: store), pin: false)
        XCTAssertEqual(second.slot, first.slot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path.appendingPathComponent("lib").path))
        let commit = try await store.resultCommit(lease: second, runID: "r1")
        XCTAssertNil(commit, "nothing changed: no stray gitlink in the result")
    }

    /// Nested submodules recurse, on both ends.
    func testNestedSubmoduleChecksOut() async throws {
        let scratch = TempRepo.scratch()
        let inner = try makeRemote("inner", in: scratch, ["inner.txt": "inner\n"])
        let innerPin = try inner.work.git("rev-parse", "HEAD")
        let mid = try makeRemote("mid", in: scratch, ["mid.txt": "mid\n"])
        try mid.work.git("submodule", "add", "-q", inner.bare.path, "inner")
        let midPin = try mid.advance([:])
        try inner.advance(["inner.txt": "inner v2\n"])
        let app = try TempRepo(at: scratch.appendingPathComponent("app"))
        app.write("main.txt", "main\n")
        try app.git("submodule", "add", "-q", mid.bare.path, "mid")
        try app.git("submodule", "update", "-q", "--init", "--recursive")
        try app.commitAll()

        let store = Workspace(root: scratch.appendingPathComponent("host"))
        let ref = try await push(app, to: store)
        XCTAssertEqual(ref.submodules, [SubmodulePin(path: "mid", commit: midPin, url: mid.bare.path),
                                        SubmodulePin(path: "mid/inner", commit: innerPin, url: inner.bare.path)])
        let lease = try await store.checkout(controller: controller, ref: ref, pin: false)
        XCTAssertEqual(text(lease, "mid/mid.txt"), "mid\n")
        XCTAssertEqual(text(lease, "mid/inner/inner.txt"), "inner\n")
        XCTAssertEqual(try head(lease, "mid/inner"), innerPin)
    }

    /// A nested gitlink with no pin (a controller that could not read it) is found in the
    /// parent submodule's own `.gitmodules` on the host, instead of being left empty.
    func testNestedSubmoduleWithoutAPinUsesItsGitmodules() async throws {
        let scratch = TempRepo.scratch()
        let inner = try makeRemote("inner", in: scratch, ["inner.txt": "inner\n"])
        let mid = try makeRemote("mid", in: scratch, ["mid.txt": "mid\n"])
        try mid.work.git("submodule", "add", "-q", inner.bare.path, "inner")
        try mid.advance([:])
        let app = try TempRepo(at: scratch.appendingPathComponent("app"))
        app.write("main.txt", "main\n")
        try app.git("submodule", "add", "-q", mid.bare.path, "mid")   // not --recursive
        try app.commitAll()

        let store = Workspace(root: scratch.appendingPathComponent("host"))
        let pushed = try await push(app, to: store)
        XCTAssertEqual(pushed.submodules.map(\.path), ["mid", "mid/inner"],
                       "an uninitialized nested submodule is still pinned, from mid's committed .gitmodules")
        let ref = SnapshotRef(repoRoot: pushed.repoRoot, wtKey: pushed.wtKey, worktreeName: pushed.worktreeName,
                              commit: pushed.commit, tree: pushed.tree, submodules: Array(pushed.submodules.prefix(1)))
        let lease = try await store.checkout(controller: controller, ref: ref, pin: false)
        XCTAssertEqual(text(lease, "mid/inner/inner.txt"), "inner\n")
    }

    /// A URL the host cannot reach fails the checkout naming the submodule and the URL, not
    /// with a bare git exit status, and nothing runs.
    func testUnreachableURLFailsClearly() async throws {
        let scratch = TempRepo.scratch()
        let (app, lib, _) = try makeApp(in: scratch)
        let store = Workspace(root: scratch.appendingPathComponent("host"), poolSize: 1)
        let ref = try await push(app, to: store)
        try FileManager.default.removeItem(at: lib.bare)

        let error = await thrown { try await store.checkout(controller: controller, ref: ref, pin: false) }
        guard case .submodule(let path, .fetchFailed(let url, _))? = error as? SyncError else {
            return XCTFail("expected a submodule fetch failure, got \(String(describing: error))")
        }
        XCTAssertEqual(path, "lib")
        XCTAssertEqual(url, lib.bare.path)
        XCTAssertEqual((error as? SyncError)?.code, "submodule_fetch_failed")
        let message = "\(error!)"
        XCTAssertTrue(message.contains("lib") && message.contains(lib.bare.path), message)
    }

    /// The host never runs a URL as a command or an option, whatever a controller sends.
    func testHostileURLIsRefused() async throws {
        let scratch = TempRepo.scratch()
        let (app, _, pin) = try makeApp(in: scratch)
        let store = Workspace(root: scratch.appendingPathComponent("host"), poolSize: 1)
        let pushed = try await push(app, to: store)
        for url in ["ext::sh -c touch% /tmp/fd-pwned", "--upload-pack=touch /tmp/fd-pwned"] {
            let ref = SnapshotRef(repoRoot: pushed.repoRoot, wtKey: pushed.wtKey, worktreeName: pushed.worktreeName,
                                  commit: pushed.commit, tree: pushed.tree,
                                  submodules: [SubmodulePin(path: "lib", commit: pin, url: url)])
            let error = await thrown { try await store.checkout(controller: controller, ref: ref, pin: false) }
            guard case .submodule(path: "lib", problem: .fetchFailed)? = error as? SyncError else {
                return XCTFail("\(url): \(String(describing: error))")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/fd-pwned"))
    }

    // MARK: - Results (§4.5)

    /// A run's edits inside a submodule never ride the result (the result is the superproject's
    /// own files), and are reported so the user knows they were left behind.
    func testResultLeavesSubmoduleChangesOutAndReportsThem() async throws {
        let scratch = TempRepo.scratch()
        let (app, _, pin) = try makeApp(in: scratch)
        let store = Workspace(root: scratch.appendingPathComponent("host"))
        let ref = try await push(app, to: store)
        let lease = try await store.checkout(controller: controller, ref: ref, pin: false)
        try Data("run edit\n".utf8).write(to: lease.path.appendingPathComponent("main.txt"))
        try Data("run edit\n".utf8).write(to: lease.path.appendingPathComponent("lib/lib.txt"))
        let changes = await store.submoduleChanges(lease: lease)
        XCTAssertEqual(changes, ["lib"])

        // Also commit inside it: a moved HEAD must not move the gitlink in the result.
        try TempRepo.git(["commit", "-q", "-am", "inside"], in: lease.path.appendingPathComponent("lib"))
        let commit = try await store.resultCommit(lease: lease, runID: "r1")
        let result = try XCTUnwrap(commit)
        let storeGit = store.storeURL(controller: controller, repoRoot: ref.repoRoot)
        let changed = try TempRepo.git(["diff-tree", "-r", "--name-only", "--no-commit-id", result], in: storeGit)
        XCTAssertEqual(changed, "main.txt")
        XCTAssertEqual(try TempRepo.git(["rev-parse", "\(result):lib"], in: storeGit), pin)
    }

    /// A clean run reports nothing.
    func testUntouchedSubmoduleReportsNothing() async throws {
        let scratch = TempRepo.scratch()
        let (app, _, _) = try makeApp(in: scratch)
        let store = Workspace(root: scratch.appendingPathComponent("host"))
        let lease = try await store.checkout(controller: controller, ref: try await push(app, to: store), pin: false)
        let changes = await store.submoduleChanges(lease: lease)
        XCTAssertEqual(changes, [])
        let commit = try await store.resultCommit(lease: lease, runID: "r1")
        XCTAssertNil(commit)
    }

    /// The controller's half of the same rule, for a result from a host that predates it: a
    /// gitlink change is neither shown in the diff nor applied, and the user's own submodule
    /// checkout is not touched, while the rest of the result applies cleanly.
    func testApplyIgnoresGitlinkChangesInAResult() async throws {
        let scratch = TempRepo.scratch()
        let (app, lib, pin) = try makeApp(in: scratch)
        let base = try await Snapshotter().snapshot(worktree: app.url, host: "mini", include: [])
        // A result commit, made by hand, that edits main.txt and moves lib to the remote's tip.
        let tip = try lib.work.git("rev-parse", "HEAD")
        let index = scratch.appendingPathComponent("result.index")
        func indexed(_ args: String...) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git"] + args
            p.currentDirectoryURL = app.url
            p.environment = ProcessInfo.processInfo.environment.merging(["GIT_INDEX_FILE": index.path]) { $1 }
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try indexed("read-tree", base.commit)
        let blob = try app.git("hash-object", "-w", "--stdin", input: "from the host\n")
        _ = try indexed("update-index", "--cacheinfo", "100644,\(blob),main.txt")
        _ = try indexed("update-index", "--cacheinfo", "160000,\(tip),lib")
        let tree = try indexed("write-tree")
        let result = try app.git("commit-tree", tree, "-p", base.commit, "-m", "result")
        try app.git("update-ref", "refs/flightdeck/results/r1", result)

        let patch = try await ResultApplier().patch(worktree: app.url, runID: "r1")
        XCTAssertFalse(patch?.contains("Subproject") ?? true, patch ?? "")
        let outcome = try await ResultApplier().apply(worktree: app.url, runID: "r1")
        XCTAssertEqual(outcome, .clean)
        XCTAssertEqual(app.read("main.txt"), "from the host\n")
        XCTAssertEqual(try TempRepo.git(["rev-parse", "HEAD"], in: app.url.appendingPathComponent("lib")), pin)
        XCTAssertEqual(app.read("lib/lib.txt"), "v1\n")
    }

    // MARK: - Version skew

    /// A host that predates submodule support would ignore the pins and run against empty
    /// submodule directories. The controller refuses to send it such a snapshot.
    func testOldHostIsRefusedASnapshotWithSubmodules() {
        let plain = SnapshotRef(repoRoot: "r", wtKey: "k", worktreeName: "w", commit: "c", tree: "t")
        let withSub = SnapshotRef(repoRoot: "r", wtKey: "k", worktreeName: "w", commit: "c", tree: "t",
                                  submodules: [SubmodulePin(path: "lib", commit: "c", url: "https://example.com/lib.git")])
        let old: Set<HostCapability> = [.hostInfo, .run, .sync, .service]
        XCTAssertNil(plain.unsupported(on: "mini", capabilities: old), "no submodules: any host will do")
        XCTAssertNil(withSub.unsupported(on: "mini", capabilities: old.union([.submodules])))
        XCTAssertNil(withSub.unsupported(on: "mini", capabilities: nil), "unknown capabilities: the host decides")
        let refusal = withSub.unsupported(on: "mini", capabilities: old)
        XCTAssertEqual(refusal?.code, "submodules_unsupported")
        XCTAssertTrue(refusal?.message.contains("mini") ?? false, refusal?.message ?? "")
    }
}
