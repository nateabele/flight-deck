import XCTest
import IntakeKit
@testable import FlightDeck

/// The redesigned Routing pane's write paths (spec L3-R §2): Return adds a rule and compiles it
/// at once, pill popovers adjust a compiled rule in place, rewording recompiles, and drag and
/// ⌫ reorder and delete. Every adjustment goes back through `RuleValidator`, so a popover can
/// never save a rule the compiler path would have refused.
@MainActor
final class RoutingServiceEditingTests: XCTestCase {
    private typealias D = RoutingTestData

    private func make(compiler: ScriptedCompiler? = nil, hints: any RuleHintSource = NoRuleHints(),
                      prefs: PreferencesStore? = nil) -> RoutingService {
        RoutingServiceSupport.make(prefs: prefs, compiler: compiler, hints: hints)
    }

    /// A confirmed copy of the spec rule (`any` of test-authoring ≥ 0.5, algorithmic-reasoning
    /// ≥ 0.6, kind tests → codex · gpt-6-sol · effort high · codex-default), with the catalogs
    /// loaded the way opening the pane loads them.
    private func confirmedRule(_ svc: RoutingService) async throws -> String {
        let id = try XCTUnwrap(svc.addRule(D.specSentence, to: .global))
        await svc.compile(id, in: .global)
        svc.confirm(id, in: .global)
        XCTAssertEqual(svc.rules(.global).first?.state, .confirmed)
        return id
    }

    private func rule(_ svc: RoutingService, _ id: String) throws -> RoutingRule {
        try XCTUnwrap(svc.rules(.global).first { $0.id == id })
    }

    // MARK: - Return adds and compiles

    func testReturnAddsTheRuleAndIsAlreadyCompilingWhenItReturns() async throws {
        let svc = make()
        let id = try XCTUnwrap(svc.submitNewRule("  " + D.specSentence + " ", to: .global))
        // Synchronous, so the new row draws with its spinner on the very first frame rather
        // than flashing an unexplained draft first.
        XCTAssertTrue(svc.compiling.contains(id))
        await svc.waitForCompile(id)
        let r = try rule(svc, id)
        XCTAssertEqual(r.sentence, D.specSentence)
        XCTAssertEqual(r.state, .compiled, "compiled, not confirmed: only a deliberate Use routes")
        XCTAssertFalse(svc.compiling.contains(id))
    }

    func testReturnOnAnEmptyFieldAddsNothing() {
        let svc = make()
        XCTAssertNil(svc.submitNewRule("   ", to: .global))
        XCTAssertEqual(svc.rules(.global), [])
        XCTAssertTrue(svc.compiling.isEmpty)
    }

    // MARK: - Condition pills

    func testChangingAThresholdKeepsTheRuleLiveAndMarksItAdjusted() async throws {
        let svc = make()
        let id = try await confirmedRule(svc)
        XCTAssertNil(svc.adjust(id, in: .global, .setTerm(at: 0, .dimension("test-authoring", atLeast: 0.75))))
        let r = try rule(svc, id)
        XCTAssertEqual(r.state, .confirmed, "a popover tweak must not silently stop a live rule routing")
        XCTAssertTrue(r.adjusted)
        XCTAssertEqual(r.compiled?.match.terms.first, .dimension("test-authoring", atLeast: 0.75))
        XCTAssertEqual(r.sentence, D.specSentence, "the words are the user's; only the pills moved")
        XCTAssertEqual(svc.makeRouter().assign(kind: D.snapshot, project: URL(fileURLWithPath: "/p"), catalogs: D.catalogs,
                                               now: D.at).block.source.by, .rule,
                       "the adjusted rule still routes")
    }

    func testAnInvalidConditionIsRefusedAndTheRuleIsUntouched() async throws {
        let svc = make()
        let id = try await confirmedRule(svc)
        let before = try rule(svc, id)
        XCTAssertNotNil(svc.adjust(id, in: .global, .setTerm(at: 0, .dimension("teleportation", atLeast: 0.5))))
        XCTAssertNotNil(svc.adjust(id, in: .global, .setTerm(at: 0, .dimension("test-authoring", atLeast: 1.5))))
        XCTAssertNotNil(svc.adjust(id, in: .global, .addTerm(.kind("astrology"))))
        XCTAssertEqual(try rule(svc, id), before)
    }

    func testConditionsCanBeAddedAndRemovedButNeverAllOfThem() async throws {
        let svc = make()
        let id = try await confirmedRule(svc)
        XCTAssertNil(svc.adjust(id, in: .global, .addTerm(.kind("algorithm"))))
        XCTAssertEqual(try rule(svc, id).compiled?.match.terms.count, 4)
        XCTAssertNil(svc.adjust(id, in: .global, .removeTerm(at: 3)))
        XCTAssertNil(svc.adjust(id, in: .global, .removeTerm(at: 2)))
        XCTAssertNil(svc.adjust(id, in: .global, .removeTerm(at: 1)))
        XCTAssertEqual(svc.adjust(id, in: .global, .removeTerm(at: 0)), RuleValidationError.emptyMatch.message,
                       "a rule with no conditions would match nothing; delete the rule instead")
        XCTAssertEqual(try rule(svc, id).compiled?.match.terms, [.dimension("test-authoring", atLeast: 0.5)])
    }

    func testTheMatchModeCanBeSwitched() async throws {
        let svc = make()
        let id = try await confirmedRule(svc)
        XCTAssertNil(svc.adjust(id, in: .global, .setMode(all: true)))
        guard case .all(let terms) = try rule(svc, id).compiled?.match else { return XCTFail("still any") }
        XCTAssertEqual(terms.count, 3)
    }

    // MARK: - Target pill

    func testSwitchingAgentTakesItsDefaultModelAndPoolAndKeepsAnEffortItAccepts() async throws {
        let svc = make()
        let id = try await confirmedRule(svc)
        XCTAssertNil(svc.adjust(id, in: .global, .setHarness("claude")))
        let a = try XCTUnwrap(rule(svc, id).compiled?.assign)
        XCTAssertEqual(a.harness, "claude")
        XCTAssertEqual(a.model, "opus")
        XCTAssertEqual(a.pool, "claude-default", "codex's pool cannot serve claude")
        XCTAssertEqual(a.knobs, ["effort": "high"], "claude's opus also declares effort high")
        XCTAssertFalse(a.modelDefaulted, "the user picked the agent, so the model is no longer a silent default")
        XCTAssertTrue(try rule(svc, id).adjusted)
    }

    func testModelEffortAndPoolChangesAreValidated() async throws {
        let svc = make()
        let id = try await confirmedRule(svc)
        XCTAssertNil(svc.adjust(id, in: .global, .setModel("gpt-6-luna")))
        XCTAssertNil(svc.adjust(id, in: .global, .setKnob("effort", "low")))
        XCTAssertNil(svc.adjust(id, in: .global, .setKnob("effort", nil)))
        XCTAssertNotNil(svc.adjust(id, in: .global, .setModel("gpt-9")))
        XCTAssertNotNil(svc.adjust(id, in: .global, .setKnob("effort", "ultra")))
        XCTAssertNotNil(svc.adjust(id, in: .global, .setPool("claude-default")), "a pool must belong to the rule's agent")
        let a = try XCTUnwrap(rule(svc, id).compiled?.assign)
        XCTAssertEqual(a.model, "gpt-6-luna")
        XCTAssertEqual(a.knobs, [:])
        XCTAssertEqual(a.pool, "codex-default")
    }

    func testAnUnchangedAdjustmentDoesNotMarkTheRule() async throws {
        let svc = make()
        let id = try await confirmedRule(svc)
        XCTAssertNil(svc.adjust(id, in: .global, .setModel("gpt-6-sol")))
        XCTAssertFalse(try rule(svc, id).adjusted, "re-picking the same model changes nothing the sentence said")
    }

    func testOnlyACompiledOrLiveRuleCanBeAdjusted() throws {
        let svc = make()
        let id = try XCTUnwrap(svc.addRule("x", to: .global))
        XCTAssertNotNil(svc.adjust(id, in: .global, .setModel("gpt-6-luna")))
        XCTAssertEqual(try rule(svc, id).state, .draft)
    }

    func testTheTargetPopoverOffersOnlyWhatTheAdapterDeclares() async throws {
        let svc = make()
        let id = try await confirmedRule(svc)
        let options = svc.targetOptions(for: try XCTUnwrap(rule(svc, id).compiled?.assign))
        XCTAssertEqual(options.harnesses, ["codex", "claude"])
        XCTAssertEqual(options.models.map(\.id), ["gpt-6-sol", "gpt-6-luna"])
        XCTAssertEqual(options.knobs["effort"], ["low", "medium", "high"])
        XCTAssertEqual(options.pools.map(\.id), ["codex-default"], "only the agent's own pools")
    }

    // MARK: - Hint

    func testSwitchingToAHintsModelAdjustsTheTarget() async throws {
        let hint = RuleHint(ruleID: "r1", text: "opus scores 0.2 higher on test-authoring (confidence 0.8)",
                            snapshotDate: D.at, suggested: ModelRef(harness: "claude", model: "opus"))
        let svc = make(hints: FixedHints(fixed: hint))
        let id = try await confirmedRule(svc)
        XCTAssertNil(svc.applyHint(hint, in: .global))
        let r = try rule(svc, id)
        XCTAssertEqual(r.compiled?.assign.harness, "claude")
        XCTAssertEqual(r.compiled?.assign.model, "opus")
        XCTAssertEqual(r.compiled?.assign.pool, "claude-default")
        XCTAssertEqual(r.state, .confirmed)
        XCTAssertTrue(r.adjusted)
    }

    // MARK: - Rewording

    func testRewordingClearsAdjustedAndRecompilesAtOnce() async throws {
        let svc = make()
        let id = try await confirmedRule(svc)
        XCTAssertNil(svc.adjust(id, in: .global, .setModel("gpt-6-luna")))
        svc.reword(id, "Use Codex for tests and hard algorithms", in: .global)
        XCTAssertTrue(svc.compiling.contains(id))
        XCTAssertFalse(try rule(svc, id).adjusted)
        await svc.waitForCompile(id)
        let r = try rule(svc, id)
        XCTAssertEqual(r.sentence, "Use Codex for tests and hard algorithms")
        XCTAssertEqual(r.state, .compiled, "new words need a new Use")
        XCTAssertEqual(r.compiled?.assign.model, "gpt-6-sol", "compiled from the words, not the old pills")
        XCTAssertFalse(r.adjusted)
    }

    func testRewordingAFailedRuleWithTheSameWordsTriesAgain() async throws {
        var bad = RoutingServiceSupport.serviceWire
        bad.terms[0].dimension = "teleportation"
        let compiler = ScriptedCompiler(.wire(bad))
        let svc = make(compiler: compiler)
        let id = try XCTUnwrap(svc.submitNewRule("Use Codex for teleportation", to: .global))
        await svc.waitForCompile(id)
        XCTAssertEqual(try rule(svc, id).state, .failed)
        compiler.proposal = .wire(RoutingServiceSupport.serviceWire)
        svc.reword(id, "Use Codex for teleportation", in: .global)
        await svc.waitForCompile(id)
        XCTAssertEqual(try rule(svc, id).state, .compiled)
    }

    func testRewordingALiveRuleWithTheSameWordsChangesNothing() async throws {
        let compiler = ScriptedCompiler(.wire(RoutingServiceSupport.serviceWire))
        let svc = make(compiler: compiler)
        let id = try await confirmedRule(svc)
        svc.reword(id, D.specSentence, in: .global)
        XCTAssertFalse(svc.compiling.contains(id))
        XCTAssertEqual(try rule(svc, id).state, .confirmed, "Return without a change must not un-Use a rule")
        XCTAssertEqual(compiler.inputs.count, 1)
    }

    func testRevertingAnAdjustedRuleRecompilesItsSentence() async throws {
        let svc = make()
        let id = try await confirmedRule(svc)
        XCTAssertNil(svc.adjust(id, in: .global, .setModel("gpt-6-luna")))
        svc.revertToSentence(id, in: .global)
        await svc.waitForCompile(id)
        let r = try rule(svc, id)
        XCTAssertFalse(r.adjusted)
        XCTAssertEqual(r.compiled?.assign.model, "gpt-6-sol")
        XCTAssertEqual(r.state, .compiled)
    }

    // MARK: - Reorder and delete

    func testDraggingARuleBeforeAnotherReorders() throws {
        let svc = make()
        let a = try XCTUnwrap(svc.addRule("a", to: .global))
        let b = try XCTUnwrap(svc.addRule("b", to: .global))
        let c = try XCTUnwrap(svc.addRule("c", to: .global))
        svc.moveRule(c, before: a, in: .global)
        XCTAssertEqual(svc.rules(.global).map(\.id), [c, a, b])
        svc.moveRule(c, before: nil, in: .global)
        XCTAssertEqual(svc.rules(.global).map(\.id), [a, b, c], "nil drops it at the end")
        svc.moveRule(a, before: c, in: .global)
        XCTAssertEqual(svc.rules(.global).map(\.id), [b, a, c])
        svc.moveRule(a, before: a, in: .global)
        XCTAssertEqual(svc.rules(.global).map(\.id), [b, a, c], "dropping a rule on itself is a no-op")
        svc.moveRule("nope", before: a, in: .global)
        XCTAssertEqual(svc.rules(.global).map(\.id), [b, a, c])
    }

    func testDeletingARuleRemovesItAndItsNote() async throws {
        let svc = make(compiler: ScriptedCompiler(.unavailable("offline")))
        let a = try XCTUnwrap(svc.submitNewRule("a", to: .global))
        await svc.waitForCompile(a)
        XCTAssertNotNil(svc.notes[a])
        svc.deleteRule(a, in: .global)
        XCTAssertEqual(svc.rules(.global), [])
        XCTAssertNil(svc.notes[a])
    }
}
