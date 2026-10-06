import XCTest
import IntakeKit
@testable import FlightDeck

/// What a rule row and a kind row show and allow, decided outside SwiftUI so it is tested here;
/// the views only lay it out (and `RoutingUITests` drives them).
final class RoutingPresentationTests: XCTestCase {
    private typealias D = RoutingTestData

    private func row(_ rule: RoutingRule, compiling: Bool = false, note: String? = nil) -> RuleRowPresentation {
        RuleRowPresentation(rule: rule, compiling: compiling, note: note, catalogs: D.catalogs, defaultPools: D.defaultPools)
    }

    func testALiveRuleShowsItsPillsAndACheck() {
        let p = row(D.r3(pool: "codex-default"))
        XCTAssertEqual(p.status, .live)
        XCTAssertEqual(p.statusAccessibility, "Live")
        XCTAssertEqual(p.conditions.map(\.text), ["test-authoring ≥ 0.5", "algorithmic-reasoning ≥ 0.6", "kind: tests"])
        XCTAssertEqual(p.joiner, "or")
        XCTAssertEqual(p.target, "Codex · GPT-6-Sol · high", "the default pool goes unsaid, like a default anywhere")
        XCTAssertNil(p.detail)
        XCTAssertEqual(p.tooltip, RuleText.compiled(D.r3(pool: "codex-default").compiled!))
        XCTAssertFalse(p.canUse)
        XCTAssertTrue(p.canAdjust)
    }

    func testANonDefaultPoolAndAFallbackAreNamedOnTheTarget() {
        XCTAssertEqual(row(D.r3(pool: "codex-subs", fallbackPool: "claude-subs")).target,
                       "Codex · GPT-6-Sol · high · codex-subs, else claude-subs")
    }

    func testAnAllRuleJoinsWithAnd() {
        let rule = D.rule("r1", .all([.dimension("debugging", atLeast: 0.7), .kind("docs")]), "claude", "opus", pool: "claude-default")
        XCTAssertEqual(row(rule).joiner, "and")
        XCTAssertEqual(row(rule).target, "Claude · Opus")
    }

    func testACompiledRuleOffersUseAndSaysItIsNotRoutingYet() {
        let p = row(D.r3(state: .compiled))
        XCTAssertEqual(p.status, .awaitingUse)
        XCTAssertTrue(p.canUse)
        XCTAssertEqual(p.statusAccessibility, "Compiled — not routing yet. Use")
    }

    func testAFailedRuleShowsItsReasonInsteadOfPills() {
        let rule = RoutingRule(id: "r1", sentence: "x", state: .failed, failure: "“Sonnet” matched no model in Claude's catalog — try “sonnet”, or reword the rule")
        let p = row(rule)
        XCTAssertEqual(p.status, .failed)
        XCTAssertEqual(p.detail, rule.failure)
        XCTAssertEqual(p.statusAccessibility, "Failed: \(rule.failure!)")
        XCTAssertTrue(p.conditions.isEmpty); XCTAssertNil(p.target)
        XCTAssertFalse(p.canUse); XCTAssertFalse(p.canAdjust)
    }

    func testWhileCompilingTheRowSpinsAndOffersNothing() {
        let p = row(D.r3(state: .compiled), compiling: true)
        XCTAssertEqual(p.status, .compiling)
        XCTAssertEqual(p.statusAccessibility, "Compiling")
        XCTAssertEqual(p.detail, "Compiling…")
        XCTAssertTrue(p.conditions.isEmpty, "the old pills are about to be replaced")
        XCTAssertFalse(p.canUse); XCTAssertFalse(p.canAdjust)
    }

    /// A draft is what an unreachable compiler leaves. It says why, and how to try again,
    /// because there is no Compile button to reach for.
    func testADraftSaysWhyItIsNotCompiledAndHowToRetry() {
        let p = row(RoutingRule(id: "r1", sentence: "x"), note: "Compiler unavailable: offline")
        XCTAssertEqual(p.status, .draft)
        XCTAssertEqual(p.detail, "Compiler unavailable: offline — press Return to try again")
        XCTAssertEqual(row(RoutingRule(id: "r1", sentence: "x")).detail, "Not compiled — press Return to compile")
    }

    func testAnAdjustedRuleSaysSo() {
        var rule = D.r3()
        XCTAssertFalse(row(rule).adjusted)
        rule.adjusted = true
        XCTAssertTrue(row(rule).adjusted)
    }

    func testPillsCarrySpokenLabels() {
        let p = row(D.r3(pool: "codex-default"))
        XCTAssertEqual(p.conditions[0].accessibilityLabel, "Condition: test-authoring at least 0.5")
        XCTAssertEqual(p.conditions[2].accessibilityLabel, "Condition: kind tests")
        XCTAssertEqual(p.targetAccessibility, "Routes to Codex · GPT-6-Sol · high")
    }

    func testKindRowsLabelOriginStatusAndBars() {
        let golden = KindRowPresentation(kind: D.golden, isNew: true, openCount: 3)
        XCTAssertEqual(golden.originLabel, "Planning")
        XCTAssertEqual(golden.statusLabel, "Merged into snapshot-tests")
        XCTAssertEqual(golden.bars.map(\.dimension), Dimensions.all.map(\.id), "one bar per dimension, in a fixed order, so rows compare")
        XCTAssertEqual(golden.bars.first { $0.dimension == "test-authoring" }?.weight, 0.8)
        XCTAssertEqual(golden.openCount, 3); XCTAssertTrue(golden.isNew)
        let tests = KindRowPresentation(kind: D.tests, isNew: false, openCount: 0)
        XCTAssertEqual(tests.originLabel, "Seed"); XCTAssertEqual(tests.statusLabel, "Active")
    }

    func testMergeTargetsAreOtherLiveKinds() {
        XCTAssertEqual(KindRowPresentation.mergeTargets(for: D.snapshot, in: D.kinds).map(\.id), ["tests", "algorithm", "docs"])
    }
}
