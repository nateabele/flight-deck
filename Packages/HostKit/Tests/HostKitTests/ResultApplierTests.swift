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

    // MARK: - Fix round 2 (reviewer's probes, ZProbeTests)

    func blob(_ repo: TempRepo, _ text: String) throws -> String {
        try repo.git("hash-object", "-w", "--stdin", input: text)
    }

    /// APFS folds case: a forged `A -> .git` symlink written first makes `a/hooks/pre-commit`
    /// land in `.git/hooks`. A check that ran once, before the symlink existed, saw nothing.
    func testCaseVariantSymlinkCannotPlantHook() async throws {
        let repo = try makeRepo()
        let hooks = try repo.git("mktree", input: "100755 blob \(try blob(repo, "#!/bin/sh\necho PWNED\n"))\tpre-commit\n")
        let a = try repo.git("mktree", input: "040000 tree \(hooks)\thooks\n")
        try forge(repo, runID: "r1", extra: [("120000", "blob", try blob(repo, ".git"), "A"), ("040000", "tree", a, "a")])

        let error = await thrown { try await ResultApplier().apply(worktree: repo.url, runID: "r1") }

        guard case .unsafePath? = error as? SyncError else { return XCTFail(String(describing: error)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.url.appendingPathComponent(".git/hooks/pre-commit").path))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: repo.url.appendingPathComponent("A").path))
    }

    /// APFS also folds Unicode normalization: NFC `café` and NFD `café` are one directory entry.
    func testNormalizationVariantSymlinkCannotEscape() async throws {
        let repo = try makeRepo()
        let outside = TempRepo.scratch()
        let payload = try repo.git("mktree", input: "100644 blob \(try blob(repo, "evil\n"))\tpayload\n")
        try forge(repo, runID: "r1", extra: [("120000", "blob", try blob(repo, outside.path), "caf\u{e9}"),
                                             ("040000", "tree", payload, "cafe\u{301}")])

        let error = await thrown { try await ResultApplier().apply(worktree: repo.url, runID: "r1") }

        guard case .unsafePath? = error as? SyncError else { return XCTFail(String(describing: error)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("payload").path))
    }

    /// The same collision aimed at an absolute target outside the repository.
    func testAbsoluteTargetSymlinkCollisionRefused() async throws {
        let repo = try makeRepo()
        let outside = TempRepo.scratch()
        let payload = try repo.git("mktree", input: "100644 blob \(try blob(repo, "evil\n"))\tpayload\n")
        try forge(repo, runID: "r1", extra: [("120000", "blob", try blob(repo, outside.path), "Out"),
                                             ("040000", "tree", payload, "out")])

        let error = await thrown { try await ResultApplier().apply(worktree: repo.url, runID: "r1") }

        guard case .unsafePath? = error as? SyncError else { return XCTFail(String(describing: error)) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    /// A symlink planted on disk *during* the apply (after every up-front check) must still
    /// stop the write beneath it: the parent walk is repeated right before each write.
    func testSymlinkAppearingMidApplyStopsTheWrite() async throws {
        let repo = try makeRepo()
        let outside = TempRepo.scratch()
        try forge(repo, runID: "r1", extra: [("040000", "tree", try repo.git("mktree", input: "100644 blob \(try blob(repo, "x\n"))\tpayload\n"), "late")])
        let link = repo.url.appendingPathComponent("late")
        let applier = ResultApplier(beforeWrite: { try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside) })

        let error = await thrown { try await applier.apply(worktree: repo.url, runID: "r1") }

        guard case .unsafePath? = error as? SyncError else { return XCTFail(String(describing: error)) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    /// NSTask refuses more than 4,096 arguments with an exception Swift cannot catch: one argv
    /// carrying every changed path aborted the app on a result with ~4,090 paths.
    func testEightThousandPathsApply() async throws {
        let repo = try makeRepo()
        let b = try blob(repo, "y\n")
        let pad = String(repeating: "p", count: 150)
        let files = (0..<8000).map { "100644 blob \(b)\t\(pad)\($0).txt" }
        let dir = try repo.git("mktree", input: files.joined(separator: "\n") + "\n")
        try forge(repo, runID: "r1", extra: [("040000", "tree", dir, "many")])

        let outcome = try await ResultApplier().apply(worktree: repo.url, runID: "r1")

        XCTAssertEqual(outcome, .clean)
        XCTAssertEqual(repo.read("many/\(pad)7999.txt"), "y\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repo.url.appendingPathComponent("many").path).count, 8000)
    }

    // MARK: - Fix round 3 (reviewer's probes, ZProbe2-4)

    /// A tree with `drop` removed from HEAD's top level and `extra` (mktree lines) added.
    func forgeLines(_ repo: TempRepo, runID: String, extra: [String], drop: Set<String> = []) throws {
        let base = try repo.git("ls-tree", "-z", "HEAD").split(separator: "\0").map(String.init)
            .filter { !drop.contains(String($0.split(separator: "\t", maxSplits: 1)[1])) }
        let tree = try repo.git("mktree", "-z", input: (base + extra).joined(separator: "\0") + "\0")
        try repo.git("update-ref", "refs/flightdeck/results/\(runID)", try repo.git("commit-tree", tree, "-p", "HEAD", "-m", "forged"))
    }

    /// A case-sensitive (Linux) host can return `Notes/bar` and `notes` side by side. On APFS
    /// they are one entry, so one of them cannot be written: that must come back as a conflict
    /// with the result kept, never as `clean` with the result deleted and the content gone.
    func testFoldingCollisionIsAConflictNotSilentLoss() async throws {
        let repo = try makeRepo()
        let dir = try repo.git("mktree", input: "100644 blob \(try blob(repo, "inner\n"))\tbar\n")
        try forgeLines(repo, runID: "r1", extra: ["040000 tree \(dir)\tNotes", "100644 blob \(try blob(repo, "file\n"))\tnotes"])

        let outcome = try await ResultApplier().apply(worktree: repo.url, runID: "r1")

        let sensitive = !FileManager.default.fileExists(atPath: repo.url.appendingPathComponent("A.TXT").path)
        if sensitive {
            XCTAssertEqual(outcome, .clean, "a case-sensitive file system holds both")
        } else {
            guard case .conflicts(let paths) = outcome else { return XCTFail("\(outcome)") }
            XCTAssertFalse(paths.isEmpty)
            XCTAssertNotEqual(try repo.git("for-each-ref", "refs/flightdeck/results/"), "", "the result is kept for the user to recover")
        }
    }

    /// Full case folding, not `lowercased()`: final sigma, sharp s and the fi ligature fold to
    /// σ, ss and fi under APFS's rules but not under lowercasing.
    func testFoldingCoversFullCaseFolding() throws {
        for (link, dir) in [("\u{3c2}", "\u{3c3}"), ("ss", "\u{df}"), ("fi", "\u{fb01}"), ("caf\u{e9}", "CAFE\u{301}")] {
            let changes = [
                ResultApplier.Change(oldMode: "000000", newMode: "120000", oldID: "", newID: "", status: "A", path: link),
                ResultApplier.Change(oldMode: "000000", newMode: "100644", oldID: "", newID: "", status: "A", path: "\(dir)/hooks/pre-commit"),
            ]
            XCTAssertThrowsError(try ResultApplier.refuseFoldingCollisions(changes), "\(link) vs \(dir)")
        }
    }

    /// A directory the result turns into a symlink: its tracked files are deleted and the link
    /// takes its place. The prefix rule must not count the deleted children against the link.
    func testDirectoryBecomesSymlink() async throws {
        let repo = try makeRepo()
        repo.write("d/keep.txt", "k\n")
        try repo.commitAll()
        try forgeLines(repo, runID: "r1", extra: ["120000 blob \(try blob(repo, "a.txt"))\td"], drop: ["d"])

        let outcome = try await ResultApplier().apply(worktree: repo.url, runID: "r1")

        XCTAssertEqual(outcome, .clean)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: repo.url.appendingPathComponent("d").path), "a.txt")
    }

    /// The same change aimed at `.git` is still refused.
    func testDirectoryBecomesSymlinkIntoGitStillRefused() async throws {
        let repo = try makeRepo()
        repo.write("d/keep.txt", "k\n")
        try repo.commitAll()
        let hooks = try repo.git("mktree", input: "100755 blob \(try blob(repo, "evil\n"))\tpre-commit\n")
        let D = try repo.git("mktree", input: "040000 tree \(hooks)\thooks\n")
        try forgeLines(repo, runID: "r1", extra: ["120000 blob \(try blob(repo, ".git"))\td", "040000 tree \(D)\tD"], drop: ["d"])

        let error = await thrown { try await ResultApplier().apply(worktree: repo.url, runID: "r1") }

        guard case .unsafePath? = error as? SyncError else { return XCTFail(String(describing: error)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.url.appendingPathComponent(".git/hooks/pre-commit").path))
    }

    /// `hash-object --stdin-paths` C-unquotes a line that starts with `"` and drops a trailing
    /// CR: unquoted, a tracked `"odd` failed the whole apply, and `cr<CR>` hashed `cr`.
    func testQuotedAndCRNamesHashTheRightFile() async throws {
        let repo = try makeRepo()
        repo.write("\"odd", "1\n"); repo.write("cr\r", "1\n"); repo.write("cr", "1\n")
        try repo.commitAll()
        repo.write("cr\r", "LOCAL EDIT\n")
        try forgeLines(repo, runID: "r1", extra: ["100644 blob \(try blob(repo, "2\n"))\t\"odd", "100644 blob \(try blob(repo, "2\n"))\tcr\r"],
                       drop: ["\"odd", "cr\r"])

        let outcome = try await ResultApplier().apply(worktree: repo.url, runID: "r1")

        XCTAssertEqual(outcome, .conflicts(["cr\r"]), "the local edit to cr<CR> is seen, not cr's content")
        let merged = try XCTUnwrap(repo.read("cr\r"))
        XCTAssertTrue(merged.contains("<<<<<<<") && merged.contains("LOCAL EDIT\n") && merged.contains("2\n"),
                      "a real content conflict: both sides marked, the local edit kept")
        XCTAssertEqual(repo.read("cr"), "1\n", "the look-alike cr is untouched")
        XCTAssertEqual(repo.read("\"odd"), "2\n")
    }

    /// Defense in depth at the real entry point: a result bundle carrying a malformed tree
    /// (duplicate entries, a `.git` entry in any spelling) is refused by `fetch` itself, before
    /// it can become a pending result at all.
    func testFetchRefusesMalformedTrees() async throws {
        let host = try makeRepo()
        // The controller is a clone: it has the snapshot but none of the forged objects, as in
        // real use. (Fetching into the repo that made them transfers, and checks, nothing.)
        let controller = TempRepo.scratch().appendingPathComponent("controller")
        try TempRepo.git(["clone", "-q", host.url.path, controller.path], in: host.url.deletingLastPathComponent())
        let blobID = try blob(host, "x\n")
        let hooks = try host.git("mktree", input: "100755 blob \(blobID)\tpre-commit\n")
        let cases = [
            ("dotgit", "040000 tree \(hooks)\t.GIT"),
            ("duplicate", "100644 blob \(blobID)\ta.txt"),
        ]
        for (name, line) in cases {
            let lines = try host.git("ls-tree", "HEAD").split(separator: "\n").map(String.init) + [line]
            let tree = try host.git("mktree", input: lines.joined(separator: "\n") + "\n")
            let commit = try host.git("commit-tree", tree, "-p", "HEAD", "-m", name)
            try host.git("update-ref", "refs/forged/\(name)", commit)
            let bundle = TempRepo.scratch().appendingPathComponent("\(name).bundle")
            try host.git("bundle", "create", "-q", bundle.path, "refs/forged/\(name)", "--not", "HEAD")

            let error = await thrown { try await ResultApplier().fetch(bundle: bundle, worktree: controller, runID: name) }

            XCTAssertNotNil(error, "\(name) must be refused at fetch")
            XCTAssertEqual(try TempRepo.git(["for-each-ref", "refs/flightdeck/results/"], in: controller), "", name)
        }
    }
}
