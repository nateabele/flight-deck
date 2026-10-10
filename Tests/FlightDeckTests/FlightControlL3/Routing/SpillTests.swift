import XCTest
import IntakeKit

/// Spill (spec L3-R §5) re-routes ONE spawn around exhausted pools. The rule's own fallback pool
/// goes first, a pinned block waits, and the result always says it was a spill.
final class SpillTests: XCTestCase {
    private typealias D = RoutingTestData

    private func r3Block(pool: PoolID = "codex-subs", pinned: Bool = false) -> ExecutionBlock {
        ExecutionBlock(kind: "snapshot-tests", agent: .codex, model: "gpt-6-sol", knobs: ["effort": "high"], pool: pool,
                       source: AssignmentSource(by: .rule, ruleId: "r3", reason: "test-authoring 0.8 → codex", at: D.at),
                       pinned: pinned)
    }

    func testTheRulesFallbackPoolIsTriedFirst() throws {
        let rule = D.r3(fallbackPool: "claude-subs")
        let s = try XCTUnwrap(RouterCore.spill(r3Block(), kind: D.snapshot, exhausted: ["codex-subs"], D.context(global: [rule])))
        XCTAssertEqual(s.block.pool, "claude-subs"); XCTAssertEqual(s.block.agent, .claude)
        XCTAssertEqual(s.block.model, "opus", "another agent's pool runs that agent's default model")
        XCTAssertEqual(s.block.knobs, [:])
        XCTAssertEqual(s.block.source, AssignmentSource(by: .spill, ruleId: "r3", reason: "codex-subs exhausted → claude-subs/opus", at: D.at))
    }

    func testAFallbackPoolOfTheSameAgentKeepsTheRulesModelAndKnobs() throws {
        let rule = D.r3(fallbackPool: "codex-default")
        let s = try XCTUnwrap(RouterCore.spill(r3Block(), kind: D.snapshot, exhausted: ["codex-subs"], D.context(global: [rule])))
        XCTAssertEqual(s.block.pool, "codex-default"); XCTAssertEqual(s.block.model, "gpt-6-sol")
        XCTAssertEqual(s.block.knobs, ["effort": "high"])
    }

    func testWithoutAFallbackPoolTheRulesRunAgainWithoutTheExhaustedPool() throws {
        let r4 = D.rule("r4", .any([.dimension("test-authoring", atLeast: 0.5)]), .claude, "opus", pool: "claude-default")
        let s = try XCTUnwrap(RouterCore.spill(r3Block(), kind: D.snapshot, exhausted: ["codex-subs"], D.context(global: [D.r3(), r4])))
        XCTAssertEqual(s.block.source, AssignmentSource(by: .spill, ruleId: "r4", reason: "codex-subs exhausted → claude-default/opus", at: D.at))
    }

    func testWhenNoRuleFitsTheDefaultTakesIt() throws {
        let s = try XCTUnwrap(RouterCore.spill(r3Block(), kind: D.snapshot, exhausted: ["codex-subs"], D.context(global: [D.r3()])))
        XCTAssertEqual(s.block.pool, "claude-default"); XCTAssertEqual(s.block.source.by, .spill); XCTAssertNil(s.block.source.ruleId)
    }

    func testAnExhaustedFallbackPoolIsPassedOver() throws {
        let rule = D.r3(fallbackPool: "claude-subs")
        let s = try XCTUnwrap(RouterCore.spill(r3Block(), kind: D.snapshot, exhausted: ["codex-subs", "claude-subs"],
                                               D.context(global: [rule])))
        XCTAssertEqual(s.block.pool, "claude-default")
    }

    func testAPinnedBlockNeverSpills() {
        XCTAssertNil(RouterCore.spill(r3Block(pinned: true), kind: D.snapshot, exhausted: ["codex-subs"],
                                      D.context(global: [D.r3(fallbackPool: "claude-subs")])))
    }

    func testNothingLeftIsNil() {
        let all: Set<PoolID> = ["codex-default", "codex-subs", "claude-default", "claude-subs"]
        XCTAssertNil(RouterCore.spill(r3Block(), kind: D.snapshot, exhausted: all, D.context(global: [D.r3()])))
    }

    func testSpillKeepsTheTasksKind() throws {
        let s = try XCTUnwrap(RouterCore.spill(r3Block(), kind: D.snapshot, exhausted: ["codex-subs"], D.context()))
        XCTAssertEqual(s.block.kind, "snapshot-tests")
    }
}
