import XCTest
@testable import HostKit

final class ResultApplierTests: XCTestCase {
    let controller = UUID()

    /// The whole round trip a `flightdeck run` makes: snapshot, sync, check out on the "host",
    /// let `edit` play the remote command, commit the result, bundle it back, fetch it locally.
    func delegate(_ repo: TempRepo, runID: String, edit: (URL) throws -> Void) async throws {
        let store = Workspace(root: TempRepo.scratch())
        let ref = try await Snapshotter().snapshot(worktree: repo.url, host: "mini", include: [])
        try await store.receive(controller: controller, bundle: try await BundleMaker().bundle(worktree: repo.url, snapshot: ref, haves: []), ref: ref)
        let lease = try await store.checkout(controller: controller, ref: ref, pin: false)
        try edit(lease.path)
        let commit = try await store.resultCommit(lease: lease, runID: runID)
        XCTAssertNotNil(commit)
        let bundle = try await store.resultBundle(controller: controller, repoRoot: ref.repoRoot, runID: runID)
        let fetched = try await ResultApplier().fetch(bundle: try XCTUnwrap(bundle), worktree: repo.url, runID: runID)
        XCTAssertEqual(fetched, commit)
    }

    func makeRepo() throws -> TempRepo {
        let repo = try TempRepo()
        repo.write("a.txt", "line1\nline2\nline3\nline4\nline5\n")
        repo.write("b.txt", "b\n"); repo.write("c.txt", "c\n")
        repo.write("tool.sh", "#!/bin/sh\n")
        try repo.commitAll()
        return repo
    }

    func testApplyCleanPatch() async throws {
        let repo = try makeRepo()
        try await delegate(repo, runID: "r1") { host in
            try Data("line1\nHOST\nline3\nline4\nline5\n".utf8).write(to: host.appendingPathComponent("a.txt"))
            try Data("new\n".utf8).write(to: host.appendingPathComponent("new.txt"))
            try FileManager.default.removeItem(at: host.appendingPathComponent("c.txt"))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: host.appendingPathComponent("tool.sh").path)
        }
        let index = try Data(contentsOf: repo.url.appendingPathComponent(".git/index"))
        let applier = ResultApplier()

        let patch = try await applier.patch(worktree: repo.url, runID: "r1")
        XCTAssertTrue(patch?.contains("+HOST") ?? false, patch ?? "nil")
        XCTAssertTrue(patch?.contains("new.txt") ?? false)

        let outcome = try await applier.apply(worktree: repo.url, runID: "r1")

        XCTAssertEqual(outcome, .clean)
        XCTAssertEqual(repo.read("a.txt"), "line1\nHOST\nline3\nline4\nline5\n")
        XCTAssertEqual(repo.read("new.txt"), "new\n")
        XCTAssertNil(repo.read("c.txt"))
        let mode = try FileManager.default.attributesOfItem(atPath: repo.url.appendingPathComponent("tool.sh").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode.map { $0 & 0o111 != 0 }, true, "the executable bit comes back")
        XCTAssertEqual(try Data(contentsOf: repo.url.appendingPathComponent(".git/index")), index, "apply never touches the user's index")
        XCTAssertEqual(try repo.git("for-each-ref", "refs/flightdeck/local/"), "", "the temporary merge ref is gone")

        XCTAssertEqual(try repo.git("for-each-ref", "refs/flightdeck/results/"), "", "a cleanly applied result is done with")
        let again = try await applier.apply(worktree: repo.url, runID: "r1")
        XCTAssertEqual(again, .nothing, "an applied result applies as nothing the second time")
        let unknown = try await applier.apply(worktree: repo.url, runID: "never")
        XCTAssertEqual(unknown, .nothing)

        try await applier.discard(worktree: repo.url, runID: "r1")   // already gone: a no-op, not an error
        let gone = try await applier.patch(worktree: repo.url, runID: "r1")
        XCTAssertNil(gone)
    }

    /// Review Focus 1: the user kept editing while the run was in flight. Their edits are the
    /// current tree; the result must merge against *that*, conflict where both touched the same
    /// lines, and overwrite nothing.
    func testApplyAfterLocalEditsConflictsNotOverwrites() async throws {
        let repo = try makeRepo()
        try await delegate(repo, runID: "r1") { host in
            try Data("line1\nHOST\nline3\nline4\nline5\n".utf8).write(to: host.appendingPathComponent("a.txt"))
            try Data("from host\n".utf8).write(to: host.appendingPathComponent("new.txt"))
            try Data("host only\n".utf8).write(to: host.appendingPathComponent("added.txt"))
        }
        // Edits made after the snapshot, while the run was "in flight".
        repo.write("a.txt", "line1\nMINE\nline3\nline4\nMINE TOO\n")
        repo.write("b.txt", "b edited locally\n")
        repo.write("new.txt", "my own new file\n")

        let outcome = try await ResultApplier().apply(worktree: repo.url, runID: "r1")

        XCTAssertEqual(outcome, .conflicts(["a.txt", "new.txt"]))
        let a = try XCTUnwrap(repo.read("a.txt"))
        XCTAssertTrue(a.contains("<<<<<<<"), a)
        XCTAssertTrue(a.contains("MINE\n"), "the local side of the conflict is kept")
        XCTAssertTrue(a.contains("HOST\n"), "the result's side of the conflict is shown")
        XCTAssertTrue(a.contains("MINE TOO\n"), "a non-overlapping local edit in the same file survives")
        XCTAssertTrue(a.contains("refs/flightdeck/results/r1"), "the markers name the run")
        let n = try XCTUnwrap(repo.read("new.txt"))
        XCTAssertTrue(n.contains("my own new file") && n.contains("from host"), n)
        XCTAssertEqual(repo.read("b.txt"), "b edited locally\n", "a file only the user touched is left alone")
        XCTAssertEqual(repo.read("added.txt"), "host only\n", "the non-conflicting part of the result still lands")
        XCTAssertNotEqual(try repo.git("for-each-ref", "refs/flightdeck/results/"), "", "the result stays while conflicts remain")
    }

    // MARK: - Fix round 1

    /// A result commit straight into the controller repo, parented on HEAD (standing in for the
    /// snapshot), with `tree` as given: what a compromised or buggy host could send.
    func forge(_ repo: TempRepo, runID: String, extra: [(mode: String, type: String, sha: String, name: String)]) throws {
        let base = try repo.git("ls-tree", "HEAD")
        let lines = base.split(separator: "\n").map(String.init) + extra.map { "\($0.mode) \($0.type) \($0.sha)\t\($0.name)" }
        let tree = try repo.git("mktree", input: lines.joined(separator: "\n") + "\n")
        let commit = try repo.git("commit-tree", tree, "-p", "HEAD", "-m", "forged")
        try repo.git("update-ref", "refs/flightdeck/results/\(runID)", commit)
    }

    func subtree(_ repo: TempRepo, _ name: String, _ content: String) throws -> String {
        let blob = try repo.git("hash-object", "-w", "--stdin", input: content)
        return try repo.git("mktree", input: "100755 blob \(blob)\t\(name)\n")
    }

    /// The host supplies every path apply writes. A tree with a `..` or `.git` entry would
    /// write outside the worktree or plant a hook that runs on the user's next commit.
    func testHostilePathsRefusedBeforeAnyWrite() async throws {
        let repo = try makeRepo()
        let outside = repo.url.deletingLastPathComponent()
        let hooks = try repo.git("mktree", input: "040000 tree \(try subtree(repo, "pre-commit", "#!/bin/sh\nevil\n"))\thooks\n")
        let cases: [(String, [(mode: String, type: String, sha: String, name: String)])] = [
            ("dotgit", [("040000", "tree", hooks, ".GIT")]),
            ("dotdot", [("040000", "tree", try subtree(repo, "evil", "x"), "..")]),
            ("dot", [("040000", "tree", try subtree(repo, "evil", "x"), ".")]),
        ]
        for (run, extra) in cases {
            try forge(repo, runID: run, extra: extra + [("100644", "blob", try repo.git("hash-object", "-w", "--stdin", input: "benign\n"), "zz-benign.txt")])
            let error = await thrown { try await ResultApplier().apply(worktree: repo.url, runID: run) }
            guard case .unsafePath? = error as? SyncError else { return XCTFail("\(run): \(String(describing: error))") }
            XCTAssertNil(repo.read("zz-benign.txt"), "\(run): nothing is written when any path is unsafe")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.url.appendingPathComponent(".git/hooks/pre-commit").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("evil").path))
    }

    /// A local symlink (here ignored, so not part of "ours") must not carry a write out of the
    /// worktree: `out/payload` would land wherever `out` points.
    func testSymlinkedParentRefused() async throws {
        let repo = try makeRepo()
        repo.write(".gitignore", "out\n")
        try repo.commitAll()
        let elsewhere = TempRepo.scratch()
        try FileManager.default.createSymbolicLink(at: repo.url.appendingPathComponent("out"), withDestinationURL: elsewhere)
        try forge(repo, runID: "r1", extra: [("040000", "tree", try subtree(repo, "payload", "x"), "out")])

        let error = await thrown { try await ResultApplier().apply(worktree: repo.url, runID: "r1") }

        guard case .unsafePath("out/payload")? = error as? SyncError else { return XCTFail(String(describing: error)) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
    }

    /// Symlinks, spaces, unicode and a leading `-` (which a careless argv would read as a
    /// flag) all survive the round trip.
    func testSymlinksAndAwkwardNamesRoundTrip() async throws {
        let repo = try makeRepo()
        try await delegate(repo, runID: "r1") { host in
            try Data("spaced\n".utf8).write(to: host.appendingPathComponent("with space.txt"))
            try Data("unicode\n".utf8).write(to: host.appendingPathComponent("caf\u{e9} \u{1F680}.txt"))
            try Data("dash\n".utf8).write(to: host.appendingPathComponent("-rf"))
            try FileManager.default.createSymbolicLink(atPath: host.appendingPathComponent("link").path, withDestinationPath: "a.txt")
        }
        let outcome = try await ResultApplier().apply(worktree: repo.url, runID: "r1")
        XCTAssertEqual(outcome, .clean)
        XCTAssertEqual(repo.read("with space.txt"), "spaced\n")
        XCTAssertEqual(repo.read("caf\u{e9} \u{1F680}.txt"), "unicode\n")
        XCTAssertEqual(repo.read("-rf"), "dash\n")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: repo.url.appendingPathComponent("link").path), "a.txt")
    }

    /// Both sides changed a binary file: the merge cannot interleave bytes, so the local file
    /// must be kept whole and the path reported, never replaced by the host's version.
    func testBinaryConflictKeepsLocal() async throws {
        let repo = try makeRepo()
        repo.write("blob.bin", Data([0, 1, 2, 3, 0, 255]))
        try repo.commitAll()
        try await delegate(repo, runID: "r1") { host in
            try Data([0, 9, 9, 9, 0, 255]).write(to: host.appendingPathComponent("blob.bin"))
        }
        repo.write("blob.bin", Data([0, 7, 7, 7, 0, 255]))

        let outcome = try await ResultApplier().apply(worktree: repo.url, runID: "r1")

        XCTAssertEqual(outcome, .conflicts(["blob.bin"]))
        XCTAssertEqual(try Data(contentsOf: repo.url.appendingPathComponent("blob.bin")), Data([0, 7, 7, 7, 0, 255]))
    }

    /// The host deleted a file the user edited meanwhile: the edit wins and is reported.
    func testModifyDeleteConflictKeepsLocalEdit() async throws {
        let repo = try makeRepo()
        try await delegate(repo, runID: "r1") { host in
            try FileManager.default.removeItem(at: host.appendingPathComponent("b.txt"))
        }
        repo.write("b.txt", "edited locally\n")

        let outcome = try await ResultApplier().apply(worktree: repo.url, runID: "r1")

        XCTAssertEqual(outcome, .conflicts(["b.txt"]))
        XCTAssertEqual(repo.read("b.txt"), "edited locally\n")
    }

    /// The user saves a file after "ours" was taken but before apply writes it. Writing the
    /// merge would throw that save away, so the path is reported and left alone.
    func testConcurrentSaveIsNotClobbered() async throws {
        let repo = try makeRepo()
        try await delegate(repo, runID: "r1") { host in
            try Data("line1\nHOST\nline3\nline4\nline5\n".utf8).write(to: host.appendingPathComponent("a.txt"))
            try Data("host c\n".utf8).write(to: host.appendingPathComponent("c.txt"))
        }
        let url = repo.url.appendingPathComponent("a.txt")
        let applier = ResultApplier(beforeWrite: { try? Data("saved mid-apply\n".utf8).write(to: url) })

        let outcome = try await applier.apply(worktree: repo.url, runID: "r1")

        XCTAssertEqual(outcome, .conflicts(["a.txt"]))
        XCTAssertEqual(repo.read("a.txt"), "saved mid-apply\n")
        XCTAssertEqual(repo.read("c.txt"), "host c\n")
    }

    /// Written files get the worktree's smudge and eol rules, as a checkout would: a repo that
    /// keeps CRLF in the working tree must not get LF files back.
    func testAppliedFilesGetCheckoutFilters() async throws {
        let repo = try makeRepo()
        repo.write(".gitattributes", "*.crlf text eol=crlf\n")
        try repo.commitAll()
        try await delegate(repo, runID: "r1") { host in
            try Data("a\r\nb\r\n".utf8).write(to: host.appendingPathComponent("new.crlf"))
        }
        let outcome = try await ResultApplier().apply(worktree: repo.url, runID: "r1")
        XCTAssertEqual(outcome, .clean)
        XCTAssertEqual(repo.read("new.crlf"), "a\r\nb\r\n")
    }
}
