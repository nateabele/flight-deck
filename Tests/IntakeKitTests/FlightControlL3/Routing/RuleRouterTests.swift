import XCTest
import IntakeKit

/// `RuleRouter` is what L3-S calls through the contract's `Router`. These tests drive it only
/// through that protocol and L3-0's fakes, the way the other branches will.
final class RuleRouterTests: XCTestCase {
    private typealias D = RoutingTestData
    private let project = URL(fileURLWithPath: "/w/project", isDirectory: true)

    private func router(global: [RoutingRule] = [], projectRules: [RoutingRule] = []) -> RuleRouter {
        let kinds = FakeKindRegistry()
        kinds.byProject[project] = D.kinds
        return RuleRouter(rules: StaticRuleSource(global: global, byProject: ["/w/project": projectRules]), kinds: kinds,
                          index: NullCapabilityIndex(), pools: DefaultPoolDirectory(agents: [.codex, .claude]),
                          defaultAgent: { _ in .claude })
    }

    func testAssignRoutesThroughTheContractProtocol() {
        let r: any Router = router(global: [D.r3(pool: "codex-default")])
        let a = r.assign(kind: D.snapshot, project: project, catalogs: D.catalogs, now: D.at)
        XCTAssertEqual(a.block.source.ruleId, "r3"); XCTAssertEqual(a.block.pool, "codex-default")
    }

    func testProjectRulesComeFromTheSourceForThatProject() {
        let p1 = D.rule("p1", .any([.dimension("test-authoring", atLeast: 0.5)]), .claude, "opus", pool: "claude-default")
        let a = router(global: [D.r3(pool: "codex-default")], projectRules: [p1])
            .assign(kind: D.snapshot, project: project, catalogs: D.catalogs, now: D.at)
        XCTAssertEqual(a.block.source.ruleId, "p1")
    }

    func testMergedKindsResolveThroughTheRegistry() {
        let k1 = D.rule("k1", .any([.kind("snapshot-tests")]), .codex, "gpt-6-sol", pool: "codex-default")
        let a = router(global: [k1]).assign(kind: D.golden, project: project, catalogs: D.catalogs, now: D.at)
        XCTAssertEqual(a.block.source.ruleId, "k1")
    }

    func testAnUnroutableTaskGetsABlockTheCodecRefuses() throws {
        let a = router().assign(kind: D.docs, project: project, catalogs: D.catalogsDisabling([.codex, .claude]), now: D.at)
        XCTAssertEqual(a.block.model, "")
        XCTAssertEqual(a.block.source.reason, "unroutable: no enabled agent has a model and a pool")
        let json = try ExecutionBlockCodec.encode(a.block, into: nil)
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: json), .failure(.invalidField("model", "empty")))
    }

    func testSpillGoesThroughTheProtocolAndRefusesPinned() {
        let r: any Router = router(global: [D.r3(pool: "codex-default", fallbackPool: "claude-default")])
        let b = ExecutionBlock(kind: "snapshot-tests", agent: .codex, model: "gpt-6-sol", knobs: ["effort": "high"],
                               pool: "codex-default", source: AssignmentSource(by: .rule, ruleId: "r3", reason: "r", at: D.at))
        XCTAssertEqual(r.spill(b, kind: D.snapshot, project: project, exhausted: ["codex-default"], catalogs: D.catalogs, now: D.at)?.block.pool,
                       "claude-default")
        var pinned = b
        pinned.pinned = true
        XCTAssertNil(r.spill(pinned, kind: D.snapshot, project: project, exhausted: ["codex-default"], catalogs: D.catalogs, now: D.at))
    }

    func testDefaultPoolsForHarnessesSkipsAgentsWithoutOne() {
        let d = DefaultPoolDirectory(agents: [.codex, .claude])
        XCTAssertEqual(d.defaultPools(for: [.claude, .grok, .codex]), [.claude: "claude-default", .codex: "codex-default"])
    }

    func testTheFileRuleSourceReadsTheProjectFileAtRoutingTime() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RuleRouterTests-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = ProjectFileRuleSource(global: [])
        XCTAssertEqual(source.rules(project: dir).project, [])
        try ProjectRoutingStore().save([D.r3()], project: dir)
        XCTAssertEqual(source.rules(project: dir).project.map(\.id), ["r3"])
    }
}
