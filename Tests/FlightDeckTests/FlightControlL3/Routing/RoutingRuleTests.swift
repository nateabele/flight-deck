import XCTest
import IntakeKit

/// A rule is two things that must never drift apart: the sentence you wrote and the compiled
/// form that routes. These tests pin the JSON both storage places use (spec L3-R §2), the
/// rule that editing the sentence throws the compiled form away, and the plain-words line
/// Settings shows under each rule.
final class RoutingRuleTests: XCTestCase {
    private let specJSON = #"""
    {"id": "r3", "sentence": "Use Codex for unit and integration tests, and for complex algorithms",
     "compiled": {
       "match": {"any": [
         {"dimension": "test-authoring", "atLeast": 0.5},
         {"dimension": "algorithmic-reasoning", "atLeast": 0.6},
         {"kind": "tests"}]},
       "assign": {"harness": "codex", "model": "gpt-6-sol", "knobs": {"effort": "high"},
                  "pool": "codex-subs", "fallbackPool": null}},
     "state": "confirmed", "compiledAt": "2026-10-04T18:00:00Z", "compiler": {"harness": "claude", "model": "haiku"}}
    """#

    private var specRule: RoutingRule {
        RoutingRule(id: "r3", sentence: "Use Codex for unit and integration tests, and for complex algorithms",
                    compiled: CompiledRule(
                        match: .any([.dimension("test-authoring", atLeast: 0.5),
                                     .dimension("algorithmic-reasoning", atLeast: 0.6),
                                     .kind("tests")]),
                        assign: RuleAssign(agent: .codex, model: "gpt-6-sol", knobs: ["effort": "high"],
                                           pool: "codex-subs")),
                    state: .confirmed, compiledAt: Date(timeIntervalSince1970: 1_790_964_000),
                    compiler: CompilerRef(agent: .claude, model: "haiku"))
    }

    private func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    private func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }

    func testTheSpecsExampleDecodes() throws {
        let rule = try decoder().decode(RoutingRule.self, from: Data(specJSON.utf8))
        XCTAssertEqual(rule.compiled, specRule.compiled)
        XCTAssertEqual(rule.state, .confirmed)
        XCTAssertEqual(rule.compiler, CompilerRef(agent: .claude, model: "haiku"))
        XCTAssertFalse(rule.compiled?.assign.modelDefaulted ?? true)
    }

    func testRoundTripsThroughTheRuleFile() throws {
        let file = RoutingRuleFile(rules: [specRule, RoutingRule(id: "r4", sentence: "Use Claude for docs")])
        let back = try decoder().decode(RoutingRuleFile.self, from: encoder().encode(file))
        XCTAssertEqual(back, file)
        XCTAssertEqual(back.v, 1)
    }

    func testAKindTermEncodesOnlyItsKind() throws {
        let data = try JSONEncoder().encode(MatchTerm.kind("tests"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"kind":"tests"}"#)
    }

    func testCompiledTextIsTheSpecsSentence() {
        XCTAssertEqual(RuleText.compiled(specRule.compiled!),
                       "matches test-authoring ≥ 0.5, algorithmic-reasoning ≥ 0.6, or kind *tests* → codex · gpt-6-sol · effort high · pool codex-subs")
    }

    func testCompiledTextForAllWithADefaultedModelAndFallback() {
        let c = CompiledRule(match: .all([.dimension("debugging", atLeast: 0.7), .kind("investigate")]),
                             assign: RuleAssign(agent: .claude, model: "opus", pool: "claude-default",
                                                fallbackPool: "codex-default", modelDefaulted: true))
        XCTAssertEqual(RuleText.compiled(c),
                       "matches debugging ≥ 0.7 and kind *investigate* → claude · opus (default model) · pool claude-default · else pool codex-default")
    }

    func testEditingTheSentenceReturnsToDraftAndDropsTheCompiledForm() {
        var rule = specRule
        rule.edit(sentence: "Use Codex for tests only")
        XCTAssertEqual(rule.state, .draft)
        XCTAssertNil(rule.compiled); XCTAssertNil(rule.compiledAt); XCTAssertNil(rule.compiler); XCTAssertNil(rule.failure)
        var same = specRule
        same.edit(sentence: specRule.sentence)
        XCTAssertEqual(same, specRule, "re-entering the same sentence is not an edit")
    }

    func testOnlyACompiledRuleCanBeConfirmed() {
        var draft = RoutingRule(id: "r1", sentence: "x")
        XCTAssertFalse(draft.confirm()); XCTAssertEqual(draft.state, .draft)
        var compiled = specRule; compiled.state = .compiled
        XCTAssertTrue(compiled.confirm()); XCTAssertEqual(compiled.state, .confirmed)
        var failed = specRule; failed.state = .failed; failed.compiled = nil
        XCTAssertFalse(failed.confirm())
    }

    func testMatchHoldsOverWeightsAndTheMergeChain() {
        let any = RuleMatch.any([.dimension("test-authoring", atLeast: 0.5), .kind("tests")])
        XCTAssertTrue(any.holds(weights: ["test-authoring": 0.5], chain: ["x"]), "the threshold is inclusive")
        XCTAssertTrue(any.holds(weights: [:], chain: ["golden-tests", "tests"]))
        XCTAssertFalse(any.holds(weights: ["test-authoring": 0.49], chain: ["x"]))
        let all = RuleMatch.all([.dimension("test-authoring", atLeast: 0.5), .dimension("debugging", atLeast: 0.5)])
        XCTAssertFalse(all.holds(weights: ["test-authoring": 0.9], chain: []))
        XCTAssertTrue(all.holds(weights: ["test-authoring": 0.9, "debugging": 0.5], chain: []))
    }

    func testEmptyMatchesNeverHold() {
        XCTAssertFalse(RuleMatch.any([]).holds(weights: ["test-authoring": 1], chain: ["tests"]))
        XCTAssertFalse(RuleMatch.all([]).holds(weights: ["test-authoring": 1], chain: ["tests"]))
    }

    // MARK: - adjusted (a pill popover changed the compiled form)

    /// Every `routing.json` and preferences blob written before pill adjustments existed has no
    /// `adjusted` key. If that stopped decoding, a user's whole rule list would vanish on update.
    func testARuleWrittenBeforeAdjustmentsDecodesAsNotAdjusted() throws {
        let rule = try decoder().decode(RoutingRule.self, from: Data(specJSON.utf8))
        XCTAssertFalse(rule.adjusted)
        let file = try decoder().decode(RoutingRuleFile.self, from: Data(#"{"v":1,"rules":[\#(specJSON)]}"#.utf8))
        XCTAssertEqual(file.rules.first?.adjusted, false)
    }

    /// Only an adjusted rule writes the key, so a file nobody adjusted stays byte-for-byte what
    /// an older Flight Deck wrote and reads back the same in it.
    func testAdjustedIsWrittenOnlyWhenTrueAndRoundTrips() throws {
        let plain = String(decoding: try encoder().encode(specRule), as: UTF8.self)
        XCTAssertFalse(plain.contains("adjusted"))
        var adjusted = specRule
        adjusted.adjusted = true
        XCTAssertEqual(try decoder().decode(RoutingRule.self, from: encoder().encode(adjusted)), adjusted)
    }

    func testRewordingOrRecompilingClearsAdjusted() {
        var rule = specRule
        rule.adjusted = true
        rule.edit(sentence: "Use Codex for tests only")
        XCTAssertFalse(rule.adjusted, "the pills are gone with the old compiled form")
        var recompiled = specRule
        recompiled.adjusted = true
        recompiled.record(.compiled(specRule.compiled!), by: CompilerRef(agent: .claude, model: "haiku"), at: Date())
        XCTAssertFalse(recompiled.adjusted, "a fresh compile matches the sentence again")
    }

    func testCompilerDefaultsToHeadlessHaiku() {
        XCTAssertEqual(RuleCompilerSettings.default, RuleCompilerSettings(agent: .claude, model: "haiku", effort: "low"))
        XCTAssertEqual(RuleCompilerSettings.default.ref, CompilerRef(agent: .claude, model: "haiku"))
    }
}
