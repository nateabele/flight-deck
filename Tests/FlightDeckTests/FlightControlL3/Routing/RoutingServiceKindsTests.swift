import XCTest
import IntakeKit
@testable import FlightDeck

/// Settings → Task kinds (spec L3-R §6) through the service: new badges, rename, re-weight and
/// merge — the last two re-routing the kind's open, unpinned tasks (§5) — and the release seam.
@MainActor
final class RoutingServiceKindsTests: XCTestCase {
    private typealias D = RoutingTestData
    private var project: URL!
    private var path: String { project.path }

    override func setUp() {
        super.setUp()
        project = FileManager.default.temporaryDirectory.appendingPathComponent("RoutingServiceKindsTests-\(UUID())", isDirectory: true)
        let file = KindRegistryStore.fileURL(project: project)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? L3Fixtures.data("kinds").write(to: file)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: project); super.tearDown() }

    private func row(_ id: String, kind: KindID, pinned: Bool = false) throws -> TaskContextRow {
        let b = ExecutionBlock(kind: kind, agent: .claude, model: "opus", pool: "claude-default",
                               source: AssignmentSource(by: .default, reason: "r", at: D.at), pinned: pinned)
        return TaskContextRow(id: id, agentContext: try ExecutionBlockCodec.encode(b, into: nil))
    }

    private func loaded(_ svc: RoutingService) -> [TaskKind] {
        guard case .loaded(let kinds) = svc.kinds(project: path) else { XCTFail("kinds did not load"); return [] }
        return kinds
    }

    func testPlanningKindsAreNewUntilSeen() throws {
        let svc = RoutingServiceSupport.make()
        let kinds = loaded(svc)
        let snapshot = try XCTUnwrap(kinds.first { $0.id == "snapshot-tests" })
        let tests = try XCTUnwrap(kinds.first { $0.id == "tests" })
        XCTAssertTrue(svc.isNew(snapshot, project: path))
        XCTAssertFalse(svc.isNew(tests, project: path), "seed kinds are never new")
        svc.markSeen("snapshot-tests", project: path)
        XCTAssertFalse(svc.isNew(snapshot, project: path))
    }

    func testRenameKeepsTheIdAndReportsErrors() {
        let svc = RoutingServiceSupport.make()
        XCTAssertNil(svc.rename("algorithm", to: "Algorithms and data structures", project: path))
        XCTAssertEqual(loaded(svc).first { $0.id == "algorithm" }?.name, "Algorithms and data structures")
        XCTAssertEqual(svc.rename("nope", to: "x", project: path), "unknown task kind nope")
    }

    func testMergeReRoutesUnpinnedOpenTasksOfThatKind() async throws {
        let prefs = PreferencesStore(persistence: nil)
        prefs.globalRoutingRules = [D.rule("g1", .any([.kind("tests")]), .codex, "gpt-6-sol", knobs: ["effort": "high"], pool: "codex-default")]
        let tasks = FakeOpenTasks()
        tasks.result = .success([try row("t1", kind: "snapshot-tests"), try row("t2", kind: "snapshot-tests", pinned: true),
                                 try row("t3", kind: "algorithm")])
        let writer = RecordingBlockWriter()
        let svc = RoutingServiceSupport.make(prefs: prefs, tasks: tasks, writer: writer)
        let error = await svc.merge("snapshot-tests", into: "tests", project: path)
        XCTAssertNil(error)
        XCTAssertEqual(loaded(svc).first { $0.id == "snapshot-tests" }?.status, .merged(into: "tests"))
        XCTAssertEqual(writer.writes.map(\.id), ["t1"])
        XCTAssertEqual(writer.writes.first?.block.agent, .codex)
        XCTAssertEqual(writer.writes.first?.block.kind, "snapshot-tests")
        XCTAssertEqual(writer.writes.first?.project, path)
        XCTAssertEqual(svc.kindNote, "Re-routed 1 open task; 1 pinned left alone")
    }

    func testReweightReRoutesTheKindAndKindsMergedIntoIt() async throws {
        let prefs = PreferencesStore(persistence: nil)
        prefs.globalRoutingRules = [D.rule("g3", .any([.dimension("docs-prose", atLeast: 0.5)]), .codex, "gpt-6-sol", pool: "codex-default")]
        let tasks = FakeOpenTasks()
        tasks.result = .success([try row("t1", kind: "golden-tests"), try row("t3", kind: "algorithm")])
        let writer = RecordingBlockWriter()
        let svc = RoutingServiceSupport.make(prefs: prefs, tasks: tasks, writer: writer)
        let error = await svc.reweight("snapshot-tests", dimensions: ["docs-prose": 0.9], project: path)
        XCTAssertNil(error)
        XCTAssertEqual(writer.writes.map(\.id), ["t1"], "golden-tests is merged into snapshot-tests; algorithm is untouched")
    }

    func testWriterSideSkipsAndFailuresAreAccountedAndDoNotAbortTheRest() async throws {
        let prefs = PreferencesStore(persistence: nil)
        prefs.globalRoutingRules = [D.rule("g1", .any([.kind("tests")]), .codex, "gpt-6-sol", knobs: ["effort": "high"], pool: "codex-default")]
        let tasks = FakeOpenTasks()
        tasks.result = .success([try row("t1", kind: "snapshot-tests"), try row("t2", kind: "snapshot-tests"),
                                 try row("t3", kind: "snapshot-tests")])
        let writer = RecordingBlockWriter()
        writer.outcomes = ["t2": .failed("br update exited 1"), "t3": .skippedPinned]
        let svc = RoutingServiceSupport.make(prefs: prefs, tasks: tasks, writer: writer)
        let error = await svc.merge("snapshot-tests", into: "tests", project: path)
        XCTAssertNil(error)
        XCTAssertEqual(writer.writes.map(\.id), ["t1", "t2", "t3"], "a failed write must not stop the rest")
        XCTAssertEqual(svc.kindNote, "Re-routed 1 open task; 1 pinned left alone; 1 failed (t2): br update exited 1")
    }

    func testAFailedReadIsReportedNotSwallowed() async {
        let tasks = FakeOpenTasks()
        tasks.result = .failure(OpenTaskReadError(message: "br list exited 1: x"))
        let svc = RoutingServiceSupport.make(tasks: tasks)
        let error = await svc.merge("snapshot-tests", into: "tests", project: path)
        XCTAssertNil(error, "the merge itself succeeded")
        XCTAssertEqual(svc.kindNote, "Could not read open tasks: br list exited 1: x")
    }

    func testAMergeTheRegistryRefusesChangesNothing() async {
        let writer = RecordingBlockWriter()
        let svc = RoutingServiceSupport.make(writer: writer)
        let error = await svc.merge("tests", into: "tests", project: path)
        XCTAssertEqual(error, "tests cannot be merged into itself")
        XCTAssertTrue(writer.writes.isEmpty)
        XCTAssertNil(svc.kindNote)
    }

    func testOpenCountsResolveMergedKinds() async throws {
        let tasks = FakeOpenTasks()
        tasks.result = .success([try row("t1", kind: "golden-tests"), try row("t2", kind: "snapshot-tests"),
                                 try row("t3", kind: "tests"), TaskContextRow(id: "t4", agentContext: nil)])
        let svc = RoutingServiceSupport.make(tasks: tasks)
        let counts = await svc.openCounts(project: path)
        XCTAssertEqual(counts, ["snapshot-tests": 2, "tests": 1])
    }

    func testReleaseRoutesThroughTheService() async throws {
        let prefs = PreferencesStore(persistence: nil)
        prefs.globalRoutingRules = [D.r3(pool: "codex-default")]
        let svc = RoutingServiceSupport.make(prefs: prefs)
        let contexts = await svc.agentContexts(for: try RoutingFixtures.encodeSteps(), project: path)
        XCTAssertEqual(Set(contexts.keys), ["n1", "n2", "n3"])
        let n2 = try XCTUnwrap(ExecutionBlockCodec.decode(agentContext: contexts["n2"]).get())
        XCTAssertEqual(n2.kind, "snapshot-tests")
        XCTAssertEqual(n2.agent, .codex)
    }

    func testAnEditOnlyReleaseNeverLoadsCatalogs() async {
        var loads = 0
        let svc = RoutingServiceSupport.make(loadCatalogs: { loads += 1; return RoutingTestData.catalogs })
        let contexts = await svc.agentContexts(for: [.update(id: "b1", set: FieldSet(title: "x"))], project: path)
        XCTAssertEqual(contexts, [:])
        XCTAssertEqual(loads, 0, "codex's catalog spawns a process; a release with no creates must not pay for it")
    }

    /// Integration ruling 1: the hand-off driver spills through `kind(for:project:)`, so a
    /// block naming a merged kind must resolve to the kind it was merged into — the same answer
    /// the swarm's own launch gets — and an unknown kind is nil (no spill), never a guess.
    func testKindForABlockResolvesThroughTheProjectRegistry() throws {
        let svc = RoutingServiceSupport.make()
        func block(_ kind: KindID) -> ExecutionBlock {
            ExecutionBlock(kind: kind, agent: .claude, model: "opus", pool: "claude-default",
                           source: AssignmentSource(by: .default, reason: "r", at: D.at))
        }
        XCTAssertEqual(svc.kind(for: block("tests"), project: project)?.id, "tests")
        XCTAssertEqual(svc.kind(for: block("golden-tests"), project: project)?.id, "snapshot-tests")
        XCTAssertNil(svc.kind(for: block("no-such-kind"), project: project))
    }
}
