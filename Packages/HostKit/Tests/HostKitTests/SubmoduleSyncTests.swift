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
    func makeApp(in scratch: URL, url: ((Remote) -> String)? = nil) throws -> (app: TempRepo, lib: Remote, pin: String) {
        let lib = try makeRemote("lib", in: scratch, ["lib.txt": "v1\n"])
        let pin = try lib.work.git("rev-parse", "HEAD")
        let app = try TempRepo(at: scratch.appendingPathComponent("app"))
        app.write("main.txt", "main\n")
        try app.git("submodule", "add", "-q", url?(lib) ?? lib.bare.path, "lib")
        try app.commitAll()
        try lib.advance(["lib.txt": "v2\n"])
        return (app, lib, pin)
    }

    @discardableResult
    func push(_ repo: TempRepo, to store: Workspace) async throws -> SnapshotRef {
        try await Self.push(repo, to: store, controller: controller)
    }

    @discardableResult
    static func push(_ repo: TempRepo, to store: Workspace, controller: UUID) async throws -> SnapshotRef {
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

    /// A URL with credentials in it (a token in a local `submodule.*.url`, or one an
    /// `insteadOf` rule adds) must not travel: the pin goes over the wire, is stored on the
    /// host and is quoted in error messages. The host fetches with its own credentials.
    func testCredentialsInASubmoduleURLNeverLeaveTheController() async throws {
        let (app, _, _) = try makeApp(in: TempRepo.scratch())
        try app.git("config", "submodule.lib.url", "https://user:tskey-auth-EXAMPLE@example.com/lib.git")
        var ref = try await Snapshotter().snapshot(worktree: app.url, host: "mini", include: [])
        XCTAssertEqual(ref.submodules.map(\.url), ["https://example.com/lib.git"])

        try app.git("config", "url.https://oauth2:tskey-auth-EXAMPLE@example.com/.insteadOf", "https://mirror.example.com/")
        try app.git("config", "submodule.lib.url", "https://mirror.example.com/lib.git")
        ref = try await Snapshotter().snapshot(worktree: app.url, host: "mini", include: [])
        XCTAssertEqual(ref.submodules.map(\.url), ["https://example.com/lib.git"], "the rewrite applies, its token does not")
    }

    func testCredentialsAreStrippedButSSHUsersKept() {
        XCTAssertEqual(SubmoduleURL.withoutCredentials("https://user:tskey-auth-EXAMPLE@example.com/lib.git"),
                       "https://example.com/lib.git")
        XCTAssertEqual(SubmoduleURL.withoutCredentials("HTTP://tskey-auth-EXAMPLE@example.com:8443/lib.git"),
                       "HTTP://example.com:8443/lib.git")
        XCTAssertEqual(SubmoduleURL.withoutCredentials("ssh://git:secret-EXAMPLE@example.com/lib.git"),
                       "ssh://git@example.com/lib.git", "the ssh user names the account; only the password goes")
        XCTAssertEqual(SubmoduleURL.withoutCredentials("ssh://git@example.com/lib.git"), "ssh://git@example.com/lib.git")
        XCTAssertEqual(SubmoduleURL.withoutCredentials("git@example.com:org/lib.git"), "git@example.com:org/lib.git")
        XCTAssertEqual(SubmoduleURL.withoutCredentials("https://example.com/a@b/lib.git"), "https://example.com/a@b/lib.git",
                       "an @ in the path is not userinfo")
        XCTAssertEqual(SubmoduleURL.withoutCredentials("/srv/git/lib.git"), "/srv/git/lib.git")
    }

    /// A host's fetch error quotes the URL it was given and whatever git printed; neither may
    /// carry a token into the run's output, the CLI's line, or a log.
    func testFetchErrorsRedactCredentials() {
        let url = "https://user:tskey-auth-EXAMPLE@example.com/lib.git"
        for problem: SubmoduleProblem in [.fetchFailed(url: url, detail: "fatal: unable to access '\(url)/': 403"),
                                          .missingCommit(url: url, commit: String(repeating: "a", count: 40))] {
            let message = "\(SyncError.submodule(path: "lib", problem: problem))"
            XCTAssertFalse(message.contains("tskey-auth-EXAMPLE"), message)
            XCTAssertTrue(message.contains("example.com/lib.git"), message)
        }
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

    /// `mid` with a nested `inner`, whose URL in mid's `.gitmodules` is `innerURL(inner)`, and
    /// `app` with `mid` (not recursively initialized). Returns the pushed ref with only mid's
    /// pin: a nested gitlink the controller sent no pin for.
    func nestedWithoutPin(in scratch: URL, store: Workspace, innerURL: (Remote) -> String) async throws -> SnapshotRef {
        let inner = try makeRemote("inner", in: scratch, ["inner.txt": "inner\n"])
        let mid = try makeRemote("mid", in: scratch, ["mid.txt": "mid\n"])
        try mid.work.git("submodule", "add", "-q", innerURL(inner), "inner")
        try mid.advance([:])
        let app = try TempRepo(at: scratch.appendingPathComponent("app"))
        app.write("main.txt", "main\n")
        try app.git("submodule", "add", "-q", mid.bare.path, "mid")   // not --recursive
        try app.commitAll()
        let pushed = try await push(app, to: store)
        XCTAssertEqual(pushed.submodules.map(\.path), ["mid", "mid/inner"],
                       "an uninitialized nested submodule is still pinned, from mid's committed .gitmodules")
        return SnapshotRef(repoRoot: pushed.repoRoot, wtKey: pushed.wtKey, worktreeName: pushed.worktreeName,
                           commit: pushed.commit, tree: pushed.tree, submodules: Array(pushed.submodules.prefix(1)))
    }

    /// A nested gitlink with no pin (a controller that could not read it) is found in the
    /// parent submodule's own `.gitmodules` on the host, instead of being left empty.
    func testNestedSubmoduleWithoutAPinUsesItsGitmodules() async throws {
        let scratch = TempRepo.scratch()
        let daemon = try GitDaemon(base: scratch)
        defer { daemon.stop() }
        let store = Workspace(root: scratch.appendingPathComponent("host"))
        let ref = try await nestedWithoutPin(in: scratch, store: store) { _ in daemon.url("inner.git") }
        let lease = try await store.checkout(controller: controller, ref: ref, pin: false)
        XCTAssertEqual(text(lease, "mid/inner/inner.txt"), "inner\n")
    }

    /// That fallback reads a `.gitmodules` from a fetched repository, written by whoever wrote
    /// it, not by the controller. A local path there would have the host read its own disk
    /// (another controller's cache, a repository the host user can read) into a checkout the
    /// controller gets back. Only a pin the controller sent may use the file transport.
    func testNestedLocalPathFromAGitmodulesIsRefused() async throws {
        let scratch = TempRepo.scratch()
        let store = Workspace(root: scratch.appendingPathComponent("host"))
        let ref = try await nestedWithoutPin(in: scratch, store: store) { $0.bare.path }
        let error = await thrown { try await store.checkout(controller: controller, ref: ref, pin: false) }
        guard case .submodule(path: "mid/inner", problem: .fetchFailed(_, let detail))? = error as? SyncError else {
            return XCTFail("\(String(describing: error))")
        }
        XCTAssertTrue(detail.contains("local"), detail)
    }

    /// The same refusal holds in git itself (`GIT_ALLOW_PROTOCOL`), not only in the URL check
    /// in front of it: a path or `file://` URL fetched without `allowFile` fails.
    func testFileTransportIsRefusedByGitWithoutAllowFile() throws {
        let scratch = TempRepo.scratch()
        let (_, lib, pin) = try makeApp(in: scratch)
        let store = Workspace(root: scratch.appendingPathComponent("host"))
        let cache = scratch.appendingPathComponent("cache.git")
        for url in [lib.bare.path, "file://\(lib.bare.path)"] {
            XCTAssertThrowsError(try store.fetchIfMissing(pin, from: url, into: cache, path: "lib", allowFile: false), url)
        }
        XCTAssertNoThrow(try store.fetchIfMissing(pin, from: lib.bare.path, into: cache, path: "lib", allowFile: true))
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

    /// A slow submodule fetch (a big repository, a slow remote) must not hold the repo's store:
    /// that lock serializes every sync, apply, gc and prune of the repo, so holding it for the
    /// fetch would stall every other agent syncing the same repo until the fetch finished.
    func testSlowSubmoduleFetchDoesNotBlockTheStore() async throws {
        let scratch = TempRepo.scratch()
        let (app, _, _) = try makeApp(in: scratch)
        let store = Workspace(root: scratch.appendingPathComponent("host"), poolSize: 2)
        let ref = try await push(app, to: store)
        let gate = Gate()
        store.submoduleFetchHook = { _ in gate.hold() }
        defer { gate.open() }
        let controller = self.controller
        let slow = Task { try await store.checkout(controller: controller, ref: ref, pin: false) }
        try await gate.waitUntilHeld()

        app.write("main.txt", "second\n")
        try app.commitAll()
        let finished = Done()
        let sync = Task {
            _ = try await SubmoduleSyncTests.push(app, to: store, controller: controller)
            try await store.gc()
            finished.set()
        }
        let done = await finished.wait(seconds: 20)
        gate.open()
        XCTAssertTrue(done, "a sync and a gc of the same repo waited on another slot's submodule fetch")
        try await sync.value
        let lease = try await slow.value
        XCTAssertEqual(text(lease, "lib/lib.txt"), "v1\n")
    }

    /// `ref` with every pin's URL replaced: what a controller would send for a remote that
    /// has since gone away, hung, or never existed.
    func repointed(_ ref: SnapshotRef, to url: String) -> SnapshotRef {
        SnapshotRef(repoRoot: ref.repoRoot, wtKey: ref.wtKey, worktreeName: ref.worktreeName, commit: ref.commit,
                    tree: ref.tree, submodules: ref.submodules.map { SubmodulePin(path: $0.path, commit: $0.commit, url: url) })
    }

    // MARK: - Fetch bounds

    /// A server that will not hand out one unadvertised commit (protocol v0 without
    /// `allowReachableSHA1InWant`, as many older servers run) still works: the host falls back
    /// to fetching everything it advertises. The cache is set to v0 here, which makes the
    /// daemon refuse the shallow request as such a server does.
    func testFallsBackToAFullFetchWhenTheServerRefusesOneCommit() async throws {
        let scratch = TempRepo.scratch()
        let daemon = try GitDaemon(base: scratch)
        defer { daemon.stop() }
        let (app, _, pin) = try makeApp(in: scratch, url: { _ in daemon.url("lib.git") })
        let root = scratch.appendingPathComponent("host")
        let store = Workspace(root: root)
        let ref = try await push(app, to: store)
        XCTAssertEqual(ref.submodules.first?.url, daemon.url("lib.git"))
        let cache = store.submoduleCaches(controller: controller).appendingPathComponent(SubmoduleURL.cacheName(daemon.url("lib.git")))
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try TempRepo.git(["init", "-q", "--bare", cache.path], in: scratch)
        try TempRepo.git(["config", "protocol.version", "0"], in: cache)

        let lease = try await store.checkout(controller: controller, ref: ref, pin: false)
        XCTAssertEqual(try head(lease, "lib"), pin)
        XCTAssertFalse(try TempRepo.git(["for-each-ref", "refs/fd/remote/heads/"], in: cache).isEmpty,
                       "the full fetch ran: the shallow one was refused")
    }

    /// A pinned commit the remote no longer has (history rewritten after the snapshot) is
    /// named as such, after the full fetch found it missing, not as a bare fetch error.
    func testCommitMissingFromTheRemoteIsReported() async throws {
        let scratch = TempRepo.scratch()
        let daemon = try GitDaemon(base: scratch)
        defer { daemon.stop() }
        let (app, lib, _) = try makeApp(in: scratch, url: { _ in daemon.url("lib.git") })
        let sub = app.url.appendingPathComponent("lib")
        try TempRepo.git(["fetch", "-q", "origin"], in: sub)
        let doomed = try lib.work.git("rev-parse", "HEAD")
        try TempRepo.git(["checkout", "-q", doomed], in: sub)
        try app.commitAll()
        let store = Workspace(root: scratch.appendingPathComponent("host"))
        let ref = try await push(app, to: store)
        // The remote drops the pinned commit for good.
        try TempRepo.git(["update-ref", "refs/heads/main", "\(doomed)^"], in: lib.bare)
        try TempRepo.git(["reflog", "expire", "--all", "--expire=now"], in: lib.bare)
        try TempRepo.git(["gc", "-q", "--prune=now"], in: lib.bare)

        let error = await thrown { try await store.checkout(controller: controller, ref: ref, pin: false) }
        XCTAssertEqual(error as? SyncError,
                       .submodule(path: "lib", problem: .missingCommit(url: daemon.url("lib.git"), commit: doomed)))
        XCTAssertEqual((error as? SyncError)?.code, "submodule_fetch_failed")
    }

    /// A server that is down (or refuses us) fails once. Retrying it as a full fetch only
    /// doubled the wait, and a hung one doubled a wait measured in hours.
    func testConnectionFailureIsNotRetriedAsAFullFetch() async throws {
        let scratch = TempRepo.scratch()
        let (app, _, _) = try makeApp(in: scratch)
        let store = Workspace(root: scratch.appendingPathComponent("host"))
        let pushed = try await push(app, to: store)
        let stub = try TCPStub(.close)
        defer { stub.stop() }
        let ref = repointed(pushed, to: "git://127.0.0.1:\(stub.port)/lib.git")

        let error = await thrown { try await store.checkout(controller: controller, ref: ref, pin: false) }
        guard case .submodule(path: "lib", problem: .fetchFailed)? = error as? SyncError else {
            return XCTFail("\(String(describing: error))")
        }
        XCTAssertEqual(stub.connections, 1, "one attempt, not a shallow one and then a full one")
    }

    /// Cancelling the run (`flightdeck cancel`, a controller that hung up) while its checkout
    /// waits on a hung remote ends it now, and the git doing the fetch dies with it rather than
    /// holding the cache lock until its timeout.
    func testCancellingACheckoutKillsTheFetch() async throws {
        let scratch = TempRepo.scratch()
        let (app, _, _) = try makeApp(in: scratch)
        let store = Workspace(root: scratch.appendingPathComponent("host"))
        let pushed = try await push(app, to: store)
        let stub = try TCPStub(.hang)
        defer { stub.stop() }
        let ref = repointed(pushed, to: "git://127.0.0.1:\(stub.port)/lib.git")
        let controller = self.controller

        let ended = Done()
        let checkout = Task {
            defer { ended.set() }
            _ = try await store.checkout(controller: controller, ref: ref, pin: false)
        }
        let deadline = Date().addingTimeInterval(20)
        while stub.connections == 0 && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(stub.connections, 1)
        checkout.cancel()
        let stopped = await ended.wait(seconds: 10)
        let died = stub.disconnected == 1
        stub.stop()   // frees a git that was not killed, so a failure here does not hang
        XCTAssertTrue(stopped, "the checkout outlived its cancel")
        XCTAssertTrue(died, "the fetching git outlived its cancel")
        let error = await thrown { try await checkout.value }
        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")
    }

    func testFetchesAreBoundedAndNeverPrompt() {
        XCTAssertEqual(SubmoduleURL.fetchConfig, ["-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=60"])
        let ssh = SubmoduleURL.fetchEnvironment(allowFile: true)["GIT_SSH_COMMAND"] ?? ""
        for option in ["BatchMode=yes", "ConnectTimeout=15", "ServerAliveInterval=15"] {
            XCTAssertTrue(ssh.contains("-o \(option)"), ssh)
        }
    }

    /// The line of git's stderr a fetch failure reports is the one that says why. ssh puts the
    /// reason first and git's generic "Could not read from remote repository" last, so the last
    /// line hid "Permission denied (publickey)" and "Host key verification failed".
    func testFetchFailureReportsTheLineThatSaysWhy() {
        XCTAssertEqual(SubmoduleURL.failureDetail("""
            git@example.com: Permission denied (publickey).
            fatal: Could not read from remote repository.

            Please make sure you have the correct access rights
            and the repository exists.
            """), "git@example.com: Permission denied (publickey).")
        XCTAssertEqual(SubmoduleURL.failureDetail("""
            Host key verification failed.
            fatal: Could not read from remote repository.
            """), "Host key verification failed.")
        XCTAssertEqual(SubmoduleURL.failureDetail("""
            warning: redirecting to https://example.com/lib.git/
            fatal: Authentication failed for 'https://example.com/lib.git/'
            """), "fatal: Authentication failed for 'https://example.com/lib.git/'")
        XCTAssertEqual(SubmoduleURL.failureDetail("""
            fatal: unable to connect to 192.0.2.1:
            192.0.2.1[0: 192.0.2.1]: errno=Connection refused
            """), "fatal: unable to connect to 192.0.2.1: 192.0.2.1[0: 192.0.2.1]: errno=Connection refused",
            "a fatal line ending in a colon continues on the next")
        XCTAssertEqual(SubmoduleURL.failureDetail("error: something odd\n"), "error: something odd")
        XCTAssertEqual(SubmoduleURL.failureDetail(""), "git fetch failed")
    }

    /// Only a server's refusal of the one commit earns the full fetch.
    func testOnlyARefusedCommitFallsBack() {
        for refused in ["error: Server does not allow request for unadvertised object 0123",
                        "fatal: remote error: upload-pack: not our ref 0123",
                        "fatal: dumb http transport does not support shallow capabilities"] {
            XCTAssertTrue(SubmoduleURL.refusedOneCommit(refused), refused)
        }
        for failed in ["fatal: unable to connect to 192.0.2.1:\nConnection refused",
                       "git@example.com: Permission denied (publickey).\nfatal: Could not read from remote repository.",
                       "fatal: Authentication failed for 'https://example.com/lib.git/'",
                       "fatal: the remote end hung up unexpectedly"] {
            XCTAssertFalse(SubmoduleURL.refusedOneCommit(failed), failed)
        }
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

    /// The controller's own ignore rules (its `info/exclude` and global excludes, which the
    /// snapshot carries) cover a submodule's files on the host as they cover the
    /// superproject's: build output there is neither "a change the run made" nor wiped by the
    /// next apply's `clean`, which would force a full rebuild of the submodule every run.
    func testControllersExcludesCoverSubmodules() async throws {
        let scratch = TempRepo.scratch()
        let (app, _, _) = try makeApp(in: scratch)
        app.write(".git/info/exclude", "scratch/\n")
        let store = Workspace(root: scratch.appendingPathComponent("host"), poolSize: 1)
        let first = try await store.checkout(controller: controller, ref: try await push(app, to: store), pin: false)
        let output = first.path.appendingPathComponent("lib/scratch/out.o")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("obj".utf8).write(to: output)
        let changes = await store.submoduleChanges(lease: first)
        XCTAssertEqual(changes, [], "ignored build output is not a change")
        await store.release(first)

        app.write("main.txt", "second\n")
        try app.commitAll()
        let second = try await store.checkout(controller: controller, ref: try await push(app, to: store), pin: false)
        XCTAssertEqual(second.slot, first.slot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "the next apply's clean kept it")
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
