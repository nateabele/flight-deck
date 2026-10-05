import XCTest
import IntakeKit

/// The encode step gets the project's kind registry — ids, descriptions, weights (spec L3-R §4) —
/// and every round that hands back a change set gets the same words, because a polish or
/// cross-check round may change a task's kind.
final class EncodePromptKindsTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_790_000_000)
    private var kinds: [TaskKind] { RoutingTestData.kinds }

    func testWithNoKindsTheRulesSayNothingNew() {
        let t = Triage.changeSetRulesText(observedAt: at)
        XCTAssertFalse(t.contains("taskKind"))
        XCTAssertEqual(Triage.kindsRulesText([]), "")
    }

    func testKindsAreListedWithWeightsAndHowToClassify() {
        let t = Triage.changeSetRulesText(observedAt: at, kinds: kinds)
        XCTAssertTrue(t.contains("- `snapshot-tests` — snapshot-tests: d (agentic-coding 0.3, test-authoring 0.8)"), t)
        XCTAssertTrue(t.contains("`taskKind`"))
        XCTAssertTrue(t.contains("`kindProposal`"))
        XCTAssertFalse(t.contains("`golden-tests`"), "a merged kind is not offered: classify into its target")
        for d in Dimensions.all { XCTAssertTrue(t.contains(d.id), d.id) }
    }

    func testEveryChangeSetRoundCarriesTheKinds() {
        let c = RoundContext(intent: "x", qa: [], graphFile: "/g", agentsFile: nil, readmeFile: nil, observedAt: at, kinds: kinds)
        let prompts = [RoundPrompts.encode(c, planFile: "/p.md"),
                       RoundPrompts.polish(c, planFile: "/p.md", changeSetFile: "/c.json", round: 1),
                       RoundPrompts.freshEyes(c, planFile: "/p.md", changeSetFile: "/c.json"),
                       RoundPrompts.dedup(c, changeSetFile: "/c.json")]
        for p in prompts { XCTAssertTrue(p.contains("`snapshot-tests`")) }
    }

    func testTriageAtSingleTaskFidelityCarriesTheKinds() {
        let p = Triage.initialPrompt(intent: "I", graphFile: "/g", triageFile: "/t", agentsFile: nil, readmeFile: nil,
                                     observedAt: at, kinds: kinds)
        XCTAssertTrue(p.contains("- `tests` — tests"))
    }

    func testAContextBuiltWithoutKindsHasNone() {
        XCTAssertEqual(RoundContext(intent: "x", qa: [], graphFile: "/g", agentsFile: nil, readmeFile: nil, observedAt: at).kinds, [])
    }
}
