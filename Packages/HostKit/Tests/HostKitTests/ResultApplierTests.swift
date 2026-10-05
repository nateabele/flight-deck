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

        let again = try await applier.apply(worktree: repo.url, runID: "r1")
        XCTAssertEqual(again, .nothing, "an applied result applies as nothing the second time")
        let unknown = try await applier.apply(worktree: repo.url, runID: "never")
        XCTAssertEqual(unknown, .nothing)

        try await applier.discard(worktree: repo.url, runID: "r1")
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
    }
}
