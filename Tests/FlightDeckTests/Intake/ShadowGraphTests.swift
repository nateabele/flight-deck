import XCTest
import IntakeKit

/// Records every argv/cwd pair `ShadowGraph` hands to the runner and answers a canned reply
/// keyed by the subcommand token right after `--db <path>` — a class, not a struct, because
/// `calls` has to accumulate across several sequential awaits within one `build()`.
private final class ShadowGraphRunnerSpy: CommandRunner, @unchecked Sendable {
    private(set) var calls: [(arguments: [String], cwd: URL)] = []
    private let reply: @Sendable ([String]) -> (Data, Int32)
    init(reply: @escaping @Sendable ([String]) -> (Data, Int32)) { self.reply = reply }

    func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
             processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?) async throws -> CommandResult {
        calls.append((arguments, cwd))
        let (stdout, exitCode) = reply(arguments)
        return CommandResult(stdout: stdout, stderr: "", exitCode: exitCode)
    }
}

/// `ShadowGraph`'s argv/cwd discipline against a fake `br` — every call must carry `--db`
/// pointing inside the shadow directory, and none may run with `cwd` = the real project
/// (see the doc comment on `ShadowGraph.build`: `br` auto-discovers `.beads` from `cwd`, so
/// either slip would reach the real graph).
final class ShadowGraphTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ShadowGraphTests-\(UUID())", isDirectory: true)
    }
    override func tearDown() { if let root { try? FileManager.default.removeItem(at: root) } }

    /// A minimal real `.beads` directory to copy from — `ShadowGraph.build` copies this with
    /// `FileManager`, not through the (fake) runner, so a test proving the runner's argv still
    /// needs a real directory on disk for that step to succeed.
    private func makeProject() throws -> URL {
        let project = root.appendingPathComponent("project", isDirectory: true)
        let beads = project.appendingPathComponent(".beads", isDirectory: true)
        try FileManager.default.createDirectory(at: beads, withIntermediateDirectories: true)
        try Data("placeholder\n".utf8).write(to: beads.appendingPathComponent("marker.txt"))
        return project
    }

    private static let listFixture = Data(#"{"issues":[{"id":"b1","title":"B1","status":"open"},{"id":"b2","title":"B2","status":"open"}]}"#.utf8)
    private static let graphFixture = Data(#"{"components":[{"edges":[]}]}"#.utf8)

    private func fakeReply(_ arguments: [String]) -> (Data, Int32) {
        // `arguments` is always `["--db", <path>, <subcommand>, …]` here — `ShadowGraph`
        // never calls the runner any other way (see its own `run(_:dbPath:cwd:label:)`).
        guard arguments.count >= 3 else { return (Data(), 127) }
        switch arguments[2] {
        case "list": return (Self.listFixture, 0)
        case "graph": return (Self.graphFixture, 0)
        case "create":
            let titleIndex = arguments.firstIndex(of: "--title")! + 1
            let id = arguments[titleIndex] == "New A" ? "shadow-n1" : "shadow-n2"
            return (Data(#"{"id":"\#(id)"}"#.utf8), 0)
        case "update", "dep": return (Data(), 0)
        default: return (Data(), 127)
        }
    }

    func testEveryCallCarriesDbAndNeverRunsWithProjectAsCwd() async throws {
        let project = try makeProject()
        let dir = root.appendingPathComponent("work/shadow", isDirectory: true)
        let recorder = ShadowGraphRunnerSpy(reply: fakeReply)
        let changeSet = ChangeSet(graphObservedAt: Date(), ops: [
            .createBead(NewBead(tempId: "n1", title: "New A", description: "d")),
            .createBead(NewBead(tempId: "n2", title: "New B", description: "d")),
            // dependent (b1) existing, dependency (n1) new: a HELD edge (ApplyPlanner runs it last).
            .addEdge(from: .existing("b1"), to: .new("n1"), kind: .blocks),
            .editBead(id: "b2", set: FieldSet(title: "b2 renamed"),
                     pre: Precondition(status: "open", assignee: nil), delivery: nil),
        ])

        let shadow = ShadowGraph(runner: recorder, environment: [:])
        let result = try await shadow.build(project: project, changeSet: changeSet, in: dir)

        let shadowBeads = dir.appendingPathComponent(".beads", isDirectory: true)
        XCTAssertEqual(result, shadowBeads)
        let dbPath = shadowBeads.appendingPathComponent("beads.db").path

        XCTAssertFalse(recorder.calls.isEmpty)
        for call in recorder.calls {
            XCTAssertEqual(Array(call.arguments.prefix(2)), ["--db", dbPath])
            XCTAssertNotEqual(call.cwd.standardizedFileURL.path, project.standardizedFileURL.path,
                              "argv \(call.arguments) ran with cwd = project")
        }

        // `recheck` never reaches the runner at all (no `br show` call) — it exists only to
        // order the plan; `.reopen` is filtered the same way, but this change set has none.
        XCTAssertFalse(recorder.calls.contains { $0.arguments.contains("show") })

        // create(n1), create(n2), update(b2), dep add(b1, n1) — the two `.recheck` steps
        // `ApplyPlanner.plan` inserts around the edit and the held edge are the ones skipped.
        let subcommands = recorder.calls.dropFirst(2).map { $0.arguments[2] }   // drop list/graph
        XCTAssertEqual(subcommands, ["create", "create", "update", "dep"])
    }

    func testUnvalidatableChangeSetThrowsRatherThanWritingAnything() async throws {
        let project = try makeProject()
        let dir = root.appendingPathComponent("work/shadow", isDirectory: true)
        let recorder = ShadowGraphRunnerSpy(reply: fakeReply)
        // `no-such-bead` isn't in the fixture graph — `ChangeSetValidator` rejects this before
        // `ApplyPlanner` ever runs, so no create/dep/update call should happen either.
        let changeSet = ChangeSet(graphObservedAt: Date(), ops: [
            .editBead(id: "no-such-bead", set: FieldSet(title: "x"),
                     pre: Precondition(status: "open", assignee: nil), delivery: nil),
        ])
        let shadow = ShadowGraph(runner: recorder, environment: [:])
        do {
            _ = try await shadow.build(project: project, changeSet: changeSet, in: dir)
            XCTFail("expected ShadowGraphBuildFailed")
        } catch let error as ShadowGraphBuildFailed {
            XCTAssertTrue(error.detail.contains("no-such-bead"), error.detail)
        }
        // Only the two reads (list, graph) that built the validation snapshot — nothing else.
        XCTAssertEqual(recorder.calls.map { $0.arguments[2] }, ["list", "graph"])
    }

    /// `build()`'s contract is that it throws exactly one type — a raw `CocoaError` from
    /// `FileManager` (here: no `.beads` under `project` to copy) must not leak through as
    /// itself, or a caller that only catches `ShadowGraphBuildFailed` would crash instead of
    /// folding the failure into the round record.
    func testMissingSourceBeadsWrapsRatherThanLeakingARawFileManagerError() async throws {
        let project = root.appendingPathComponent("no-beads-here", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let dir = root.appendingPathComponent("work/shadow", isDirectory: true)
        let shadow = ShadowGraph(runner: ShadowGraphRunnerSpy(reply: fakeReply), environment: [:])
        do {
            _ = try await shadow.build(project: project, changeSet: ChangeSet(graphObservedAt: Date(), ops: []), in: dir)
            XCTFail("expected ShadowGraphBuildFailed")
        } catch is ShadowGraphBuildFailed {
            // expected
        } catch {
            XCTFail("expected ShadowGraphBuildFailed, got \(type(of: error)): \(error)")
        }
    }

    /// `copyBeads` copies non-db files with `FileManager` but snapshots `beads.db` through
    /// `sqlite3 -readonly … VACUUM INTO …` — proved here with a REAL (if tiny) sqlite
    /// database standing in for `beads.db`, not just a byte-for-byte file copy, so a
    /// corrupted/truncated source would actually fail this rather than silently pass.
    func testCopiesNonDbFilesAndSnapshotsTheDatabaseWithVacuumInto() async throws {
        let project = try makeProject()
        let beads = project.appendingPathComponent(".beads", isDirectory: true)
        let sourceDB = beads.appendingPathComponent("beads.db")
        let sqlite = SystemCommandRunner()
        let createResult = try await sqlite.run(
            executable: "/usr/bin/sqlite3",
            arguments: [sourceDB.path, "CREATE TABLE t(x); INSERT INTO t VALUES(42);"],
            cwd: root, environment: [:])
        XCTAssertEqual(createResult.exitCode, 0, createResult.stderr)
        // A non-db file that must ride along, same as `config.yaml` would in a real `.beads`.
        try Data("actor: shadow\n".utf8).write(to: beads.appendingPathComponent("config.yaml"))

        let dir = root.appendingPathComponent("work/shadow", isDirectory: true)
        let shadow = ShadowGraph(runner: ShadowGraphRunnerSpy(reply: fakeReply), environment: [:])
        let shadowBeads = try await shadow.build(project: project, changeSet: ChangeSet(graphObservedAt: Date(), ops: []), in: dir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: shadowBeads.appendingPathComponent("config.yaml").path),
                      "non-db file wasn't copied into the shadow")

        let shadowDB = shadowBeads.appendingPathComponent("beads.db")
        let queryResult = try await sqlite.run(executable: "/usr/bin/sqlite3", arguments: [shadowDB.path, "SELECT x FROM t;"],
                                               cwd: root, environment: [:])
        XCTAssertEqual(queryResult.exitCode, 0, queryResult.stderr)
        XCTAssertEqual(String(decoding: queryResult.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "42")

        // `VACUUM INTO` materializes one self-contained file — no leftover `-wal`/`-shm`
        // sidecars the way a naive three-file copy could leave.
        XCTAssertFalse(FileManager.default.fileExists(atPath: shadowDB.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shadowDB.path + "-shm"))
    }
}

/// The same build against a REAL `br`, in a scratch repo under `$HOME` (never `/tmp` — `am`
/// treats it as ephemeral, see `AGENTS.md`). Skipped when `br` isn't resolvable, so a clean
/// clone/CI host degrades rather than fails; the scratch repo is created fresh in `setUp` and
/// removed in `tearDown` on every path, pass or fail.
final class ShadowGraphLiveTests: XCTestCase {
    private var brPath = ""
    private var scratchRoot: URL!
    private var projectDir: URL!
    private let runner = SystemCommandRunner()
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    /// `~/.local/bin/br` first — where `br` actually lives in this environment, and a
    /// headless `xcodebuild test` process's PATH is not guaranteed to include it — then the
    /// process's own PATH, mirroring `BeadWriterLiveTests.resolveBrPath`.
    private static func resolveBrPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let localBin = "\(home)/.local/bin/br"
        if FileManager.default.isExecutableFile(atPath: localBin) { return localBin }
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/br"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    override func setUp() async throws {
        guard let brPath = Self.resolveBrPath() else {
            throw XCTSkip("br not found at ~/.local/bin/br or on PATH")
        }
        self.brPath = brPath
        let home = FileManager.default.homeDirectoryForCurrentUser
        scratchRoot = home.appendingPathComponent(".fd-shadowgraph-test-\(UUID().uuidString)", isDirectory: true)
        projectDir = scratchRoot.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let initResult = try await runner.run(executable: brPath, arguments: ["init"], cwd: projectDir, environment: env)
        XCTAssertEqual(initResult.exitCode, 0, String(decoding: initResult.stdout, as: UTF8.self))
    }

    override func tearDown() async throws {
        if let scratchRoot { try? FileManager.default.removeItem(at: scratchRoot) }
    }

    private struct CreateReply: Decodable { let id: String }
    private struct ListEnvelope: Decodable { struct Issue: Decodable { let id: String; let title: String }
                                             let issues: [Issue]; let total: Int }

    private func create(_ title: String) async throws -> String {
        let r = try await runner.run(executable: brPath, arguments:
            ["create", "--title", title, "-t", "task", "-p", "2", "--description", "d", "--json"],
            cwd: projectDir, environment: env)
        XCTAssertEqual(r.exitCode, 0, String(decoding: r.stdout, as: UTF8.self))
        return try JSONDecoder().decode(CreateReply.self, from: r.stdout).id
    }

    /// `br init`, 2 beads with an edge; a shadow build that creates 2 more and adds 1 held
    /// edge; the shadow shows all 4 plus the held edge, the real repo still shows only its
    /// original 2, and rebuilding into the same `dir` replaces rather than accumulates.
    func testBuildsAShadowWithoutTouchingTheRealGraph() async throws {
        let b1 = try await create("Existing 1")
        let b2 = try await create("Existing 2")
        let depResult = try await runner.run(executable: brPath,
            arguments: ["dep", "add", b1, b2, "--type", "blocks"], cwd: projectDir, environment: env)
        XCTAssertEqual(depResult.exitCode, 0, String(decoding: depResult.stdout, as: UTF8.self))

        let changeSet = ChangeSet(graphObservedAt: Date(), ops: [
            .createBead(NewBead(tempId: "n1", title: "Shadow new 1", description: "d")),
            .createBead(NewBead(tempId: "n2", title: "Shadow new 2", description: "d")),
            // b1 (existing) depends on n1 (new) — held: the edge that must wait for release
            // against a live bead, per `ValidatedChangeSet.heldOpIndices`'s doc comment.
            .addEdge(from: .existing(b1), to: .new("n1"), kind: .blocks),
        ])
        let dir = scratchRoot.appendingPathComponent("work/shadow", isDirectory: true)
        let shadow = ShadowGraph(runner: runner, brPath: brPath, environment: env)

        // The real database's own mtime must never move — `copyBeads` opens it `-readonly`
        // for the `VACUUM INTO` snapshot, so nothing about this build should touch it.
        let realDBPath = projectDir.appendingPathComponent(".beads/beads.db").path
        let mtimeBefore = try FileManager.default.attributesOfItem(atPath: realDBPath)[.modificationDate] as? Date

        let shadowBeads = try await shadow.build(project: projectDir, changeSet: changeSet, in: dir)
        XCTAssertEqual(shadowBeads, dir.appendingPathComponent(".beads", isDirectory: true))
        let dbPath = shadowBeads.appendingPathComponent("beads.db").path

        let listResult = try await runner.run(executable: brPath,
            arguments: ["--db", dbPath, "list", "--all", "--json"], cwd: dir, environment: env)
        let listed = try JSONDecoder().decode(ListEnvelope.self, from: listResult.stdout)
        XCTAssertEqual(listed.total, 4)
        guard let n1 = listed.issues.first(where: { $0.title == "Shadow new 1" })?.id else {
            return XCTFail("shadow new bead n1 not found in shadow listing")
        }

        let graphResult = try await runner.run(executable: brPath,
            arguments: ["--db", dbPath, "graph", "--all", "--json"], cwd: dir, environment: env)
        let graph = try GraphSnapshot.decode(list: listResult.stdout, graph: graphResult.stdout)
        XCTAssertTrue(graph.edges.contains(DepEdge(dependent: b1, dependency: n1)))

        // The real repo's own graph never moved.
        let realList = try await runner.run(executable: brPath,
            arguments: ["list", "--all", "--json"], cwd: projectDir, environment: env)
        let realListed = try JSONDecoder().decode(ListEnvelope.self, from: realList.stdout)
        XCTAssertEqual(realListed.total, 2)

        // Rebuilding into the same `dir` replaces the old shadow rather than adding to it —
        // if the earlier copy had survived, this would show 6 beads, not 4.
        let shadowBeadsAgain = try await shadow.build(project: projectDir, changeSet: changeSet, in: dir)
        XCTAssertEqual(shadowBeadsAgain, shadowBeads)
        let listAgain = try await runner.run(executable: brPath,
            arguments: ["--db", dbPath, "list", "--all", "--json"], cwd: dir, environment: env)
        let listedAgain = try JSONDecoder().decode(ListEnvelope.self, from: listAgain.stdout)
        XCTAssertEqual(listedAgain.total, 4)

        let mtimeAfter = try FileManager.default.attributesOfItem(atPath: realDBPath)[.modificationDate] as? Date
        XCTAssertEqual(mtimeBefore, mtimeAfter, "the real beads.db was written to by the shadow build")
    }
}
