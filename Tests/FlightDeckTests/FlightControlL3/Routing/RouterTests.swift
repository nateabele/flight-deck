import XCTest
import IntakeKit

/// Table tests over (rules × registry × index × catalogs × pools), spec L3-R §9. The router is a
/// pure function of its context, so every case builds the context it needs and reads the block.
final class RouterTests: XCTestCase {
    private typealias D = RoutingTestData

    private func block(_ outcome: RouteOutcome, file: StaticString = #filePath, line: UInt = #line) -> ExecutionBlock? {
        guard case .routed(let a) = outcome else { XCTFail("unroutable: \(outcome)", file: file, line: line); return nil }
        return a.block
    }

    func testFirstConfirmedRuleMatchesAndRecordsWhy() throws {
        let b = try XCTUnwrap(block(RouterCore.assign(kind: D.snapshot, D.context(global: [D.r3()]))))
        XCTAssertEqual(b.kind, "snapshot-tests")
        XCTAssertEqual(b.harness, "codex"); XCTAssertEqual(b.model, "gpt-6-sol")
        XCTAssertEqual(b.knobs, ["effort": "high"]); XCTAssertEqual(b.pool, "codex-subs")
        XCTAssertEqual(b.source, AssignmentSource(by: .rule, ruleId: "r3", reason: "test-authoring 0.8 → codex", at: D.at))
        XCTAssertFalse(b.pinned); XCTAssertNil(b.host)
    }

    func testProjectRulesAreCheckedBeforeGlobalRules() throws {
        let p1 = D.rule("p1", .any([.dimension("test-authoring", atLeast: 0.5)]), "claude", "opus", pool: "claude-subs")
        let b = try XCTUnwrap(block(RouterCore.assign(kind: D.snapshot, D.context(project: [p1], global: [D.r3()]))))
        XCTAssertEqual(b.source.ruleId, "p1"); XCTAssertEqual(b.pool, "claude-subs")
    }

    func testTheFirstMatchWinsWithinAList() throws {
        let rA = D.rule("rA", .any([.dimension("docs-prose", atLeast: 0.5)]), "claude", "haiku", pool: "claude-default")
        let rB = D.rule("rB", .any([.dimension("test-authoring", atLeast: 0.5)]), "claude", "opus", pool: "claude-default")
        let b = try XCTUnwrap(block(RouterCore.assign(kind: D.snapshot, D.context(global: [rA, rB, D.r3()]))))
        XCTAssertEqual(b.source.ruleId, "rB")
    }

    func testOnlyConfirmedRulesRoute() throws {
        for state in [RuleState.draft, .compiled, .failed] {
            let b = try XCTUnwrap(block(RouterCore.assign(kind: D.snapshot, D.context(global: [D.r3(state: state)]))))
            XCTAssertEqual(b.source.by, .default, "\(state)")
        }
    }

    func testAllNeedsEveryTerm() throws {
        let both = D.rule("both", .all([.dimension("test-authoring", atLeast: 0.5), .dimension("algorithmic-reasoning", atLeast: 0.5)]),
                          "codex", "gpt-6-sol", pool: "codex-default")
        XCTAssertEqual(try XCTUnwrap(block(RouterCore.assign(kind: D.snapshot, D.context(global: [both])))).source.by, .default)
        let fuzz = D.kind("property-tests", ["test-authoring": 0.7, "algorithmic-reasoning": 0.8])
        XCTAssertEqual(try XCTUnwrap(block(RouterCore.assign(kind: fuzz, D.context(global: [both])))).source.ruleId, "both")
    }

    func testAnEmptyMatchNeverMatches() throws {
        let anyNothing = D.rule("e1", .any([]), "codex", "gpt-6-sol", pool: "codex-default")
        let allNothing = D.rule("e2", .all([]), "codex", "gpt-6-sol", pool: "codex-default")
        let b = try XCTUnwrap(block(RouterCore.assign(kind: D.tests, D.context(global: [anyNothing, allNothing]))))
        XCTAssertEqual(b.source.by, .default)
    }

    func testKindTermMatchesMergedKindsButNotTheReverse() throws {
        let toSnapshot = D.rule("k1", .any([.kind("snapshot-tests")]), "codex", "gpt-6-sol", pool: "codex-default")
        let golden = try XCTUnwrap(block(RouterCore.assign(kind: D.golden, D.context(global: [toSnapshot]))))
        XCTAssertEqual(golden.source.ruleId, "k1", "golden-tests was merged into snapshot-tests")
        XCTAssertEqual(golden.source.reason, "kind snapshot-tests → codex")
        XCTAssertEqual(golden.kind, "golden-tests", "the block keeps the task's own kind; resolution happens on read")

        let toGolden = D.rule("k2", .any([.kind("golden-tests")]), "codex", "gpt-6-sol", pool: "codex-default")
        let snapshot = try XCTUnwrap(block(RouterCore.assign(kind: D.snapshot, D.context(global: [toGolden]))))
        XCTAssertEqual(snapshot.source.by, .default, "a merge points one way only")
    }

    func testANewKindRoutesByDimensionWithoutARecompile() throws {
        let proposed = D.kind("property-tests", ["test-authoring": 0.85], origin: .planning)
        let b = try XCTUnwrap(block(RouterCore.assign(kind: proposed, D.context(global: [D.r3()], kinds: D.kinds + [proposed]))))
        XCTAssertEqual(b.source.ruleId, "r3"); XCTAssertEqual(b.harness, "codex")
    }

    func testRuleWhoseModelLeftTheCatalogIsSkipped() throws {
        let retired = D.rule("old", .any([.dimension("test-authoring", atLeast: 0.5)]), "codex", "gpt-5-retired", pool: "codex-default")
        XCTAssertEqual(try XCTUnwrap(block(RouterCore.assign(kind: D.snapshot, D.context(global: [retired, D.r3()])))).source.ruleId, "r3")

        let noPool = D.rule("np", .any([.dimension("test-authoring", atLeast: 0.5)]), "codex", "gpt-6-sol", pool: "deleted-pool")
        XCTAssertEqual(try XCTUnwrap(block(RouterCore.assign(kind: D.snapshot, D.context(global: [noPool, D.r3()])))).source.ruleId, "r3")

        let badKnob = D.rule("bk", .any([.dimension("test-authoring", atLeast: 0.5)]), "codex", "gpt-6-sol",
                             knobs: ["effort": "max"], pool: "codex-default")
        XCTAssertEqual(try XCTUnwrap(block(RouterCore.assign(kind: D.snapshot, D.context(global: [badKnob, D.r3()])))).source.ruleId, "r3")

        let off = D.context(global: [D.r3()], catalogs: D.catalogsDisabling(["codex"]))
        let b = try XCTUnwrap(block(RouterCore.assign(kind: D.snapshot, off)))
        XCTAssertEqual(b.source.by, .default); XCTAssertEqual(b.harness, "claude")
    }

    private func index(_ rows: [(HarnessID, String, Double, Double)]) -> FakeCapabilityIndex {
        let i = FakeCapabilityIndex()
        for (h, m, score, confidence) in rows {
            let ref = ModelRef(harness: h, model: m)
            i.scores[ref] = ScoredModel(model: ref, score: score, confidence: confidence)
        }
        return i
    }

    func testTheIndexTakesTheBestModelAboveTheFloor() throws {
        let i = index([("claude", "haiku", 0.9, 0.4), ("codex", "gpt-6-luna", 0.8, 0.7), ("claude", "opus", 0.7, 0.9)])
        let b = try XCTUnwrap(block(RouterCore.assign(kind: D.docs, D.context(index: i))))
        XCTAssertEqual(b.harness, "codex"); XCTAssertEqual(b.model, "gpt-6-luna"); XCTAssertEqual(b.pool, "codex-default")
        XCTAssertEqual(b.knobs, [:])
        XCTAssertEqual(b.source, AssignmentSource(by: .index, reason: "index: codex/gpt-6-luna scores 0.8 for docs (confidence 0.7)", at: D.at))
    }

    func testAnIndexBelowTheFloorFallsToTheDefault() throws {
        let i = index([("codex", "gpt-6-luna", 0.8, 0.4), ("claude", "opus", 0.7, 0.49)])
        let b = try XCTUnwrap(block(RouterCore.assign(kind: D.docs, D.context(index: i))))
        XCTAssertEqual(b.harness, "claude"); XCTAssertEqual(b.model, "opus"); XCTAssertEqual(b.pool, "claude-default")
        XCTAssertEqual(b.source, AssignmentSource(by: .default, reason: "default agent claude: no rule matched and the index had no confident answer", at: D.at))
    }

    func testTheFloorIsTheContextsToSet() throws {
        var ctx = D.context(index: index([("claude", "haiku", 0.9, 0.4)]))
        ctx.confidenceFloor = 0.3
        XCTAssertEqual(try XCTUnwrap(block(RouterCore.assign(kind: D.docs, ctx))).model, "haiku")
    }

    func testOnlyAgentsWithAPoolAreIndexCandidates() throws {
        let i = index([("codex", "gpt-6-luna", 0.95, 0.9), ("claude", "opus", 0.7, 0.9)])
        let b = try XCTUnwrap(block(RouterCore.assign(kind: D.docs, D.context(defaultPools: ["claude": "claude-default"], index: i))))
        XCTAssertEqual(b.model, "opus", "codex has no pool, so its score is never asked for")
    }

    func testTheDefaultPrefersTheProjectsAgentThenCatalogOrder() throws {
        XCTAssertEqual(try XCTUnwrap(block(RouterCore.assign(kind: D.docs, D.context(defaultHarness: "codex")))).model, "gpt-6-sol")
        XCTAssertEqual(try XCTUnwrap(block(RouterCore.assign(kind: D.docs, D.context(defaultHarness: nil)))).harness, "codex")
        let claudeOff = D.context(catalogs: D.catalogsDisabling(["claude"]), defaultHarness: "claude")
        XCTAssertEqual(try XCTUnwrap(block(RouterCore.assign(kind: D.docs, claudeOff))).harness, "codex")
    }

    func testNothingRunnableIsUnroutable() {
        let none = D.context(catalogs: D.catalogsDisabling(["codex", "claude"]))
        XCTAssertEqual(RouterCore.assign(kind: D.docs, none), .unroutable("no enabled agent has a model and a pool"))
    }

    func testKindChainFollowsMergesAndStopsOnACycle() {
        XCTAssertEqual(KindChain.ids(from: "golden-tests", in: D.kinds), ["golden-tests", "snapshot-tests"])
        XCTAssertEqual(KindChain.ids(from: "unknown", in: D.kinds), ["unknown"])
        let loop = [D.kind("a", [:], status: .merged(into: "b")), D.kind("b", [:], status: .merged(into: "a"))]
        XCTAssertEqual(KindChain.ids(from: "a", in: loop), ["a", "b"])
    }
}
