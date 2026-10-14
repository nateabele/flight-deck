import XCTest
import IntakeKit
@testable import FlightDeck

/// Pure-helper coverage for `RoundConfigEditor`. The view body itself is covered by
/// `RoundConfigEditorRenderTests` (offscreen PNG, skipped by default) — SwiftUI layout can't
/// be asserted on headlessly, but the label/slot/mutation logic behind it can.
final class RoundConfigEditorTests: XCTestCase {
    private let available = AvailableModels.defaults

    private func fullPlan() throws -> RoundConfig {
        try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: available))
    }

    // MARK: - label

    func testLabelUncustomized() throws {
        let config = try fullPlan()
        XCTAssertEqual(RoundConfigEditor.label(preset: .fullPlan, config: config), "Full plan")
    }

    func testLabelCustomizedAppendsSuffix() throws {
        var config = try fullPlan()
        config.customized = true
        XCTAssertEqual(RoundConfigEditor.label(preset: .fullPlan, config: config), "Full plan, customized")
    }

    // MARK: - Rotations

    private let threeAgents = AvailableModels(choices: [
        .codex: ModelChoice(agent: .codex, model: "gpt-6-sol", effort: "high"),
        .claude: ModelChoice(agent: .claude, model: "opus", effort: "high"),
        .gemini: ModelChoice(agent: .gemini, model: "gemini-3.1-pro-high", effort: "high")])

    private func fullWithEveryAgent() throws -> RoundConfig {
        try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: threeAgents))
    }

    private func polishers(_ c: RoundConfig) -> [AgentID] { c.polisherRotation.map(\.agent) }

    /// A rotating role is one row that lists its agents in order; the rows stay one per role.
    func testARotatingRoleShowsItsEntriesInOrder() throws {
        let config = try fullWithEveryAgent()
        XCTAssertEqual(RoundConfigEditor.slots(of: config).map(\.role).filter { $0 == "polisher" }.count, 1)
        let polisher = RoundConfigEditor.entries(of: .polisher, in: config)
        XCTAssertEqual(polisher, [.polisher, .polisherEntry(1), .polisherEntry(2)])
        XCTAssertEqual(polisher.compactMap { RoundConfigEditor.choice(for: $0, in: config)?.agent }, [.claude, .gemini, .codex])
        XCTAssertEqual(RoundConfigEditor.entries(of: .reviewer, in: config).compactMap { RoundConfigEditor.choice(for: $0, in: config)?.agent },
                       [.codex, .claude])
        XCTAssertEqual(RoundConfigEditor.entries(of: .encoder, in: config), [.encoder])
        XCTAssertEqual(RoundConfigEditor.fallback(for: .reviewerEntry(1), in: config)?.agent, .codex)
        XCTAssertTrue(RoundConfigEditor.supportsFallback(.reviewerEntry(1)))
        XCTAssertFalse(RoundConfigEditor.supportsFallback(.polisherEntry(1)))
    }

    /// Every rotation edit flags the config customized and keeps the single field equal to entry 0.
    func testEditingARotationMarksItCustomizedAndKeepsEntryZeroInStep() throws {
        let config = try fullWithEveryAgent()
        XCTAssertFalse(config.customized)

        let moved = RoundConfigEditor.movingInRotation(config, .polisher, from: 2, to: 0)
        XCTAssertTrue(moved.customized)
        XCTAssertEqual(polishers(moved), [.codex, .claude, .gemini])
        XCTAssertEqual(moved.polisher, moved.polishers?.first)

        let removed = RoundConfigEditor.removingFromRotation(config, .polisher, at: 0)
        XCTAssertTrue(removed.customized)
        XCTAssertEqual(polishers(removed), [.gemini, .codex])
        XCTAssertEqual(removed.polisher?.agent, .gemini)

        let collapsed = RoundConfigEditor.collapsingRotation(config, .polisher)
        XCTAssertNil(collapsed.polishers, "one agent is no rotation")
        XCTAssertEqual(collapsed.polisher?.agent, .claude)
        XCTAssertEqual(collapsed.polisher(rotation: 5)?.agent, .claude)

        // Removing down to one agent collapses to it, whichever was left.
        let one = RoundConfigEditor.removingFromRotation(RoundConfigEditor.removingFromRotation(config, .polisher, at: 0), .polisher, at: 0)
        XCTAssertNil(one.polishers)
        XCTAssertEqual(one.polisher?.agent, .codex)
        // The last agent can't be taken out.
        XCTAssertEqual(RoundConfigEditor.removingFromRotation(one, .polisher, at: 0).polisher?.agent, .codex)
    }

    func testAddingAnAgentMakesAPairFromASingleAgent() throws {
        let codexOnly = AvailableModels(codex: threeAgents.codex, claude: nil)
        let single = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: codexOnly))
        XCTAssertNil(single.integrators)
        XCTAssertFalse(RoundConfigEditor.canAddToRotation(single, .integrator, available: codexOnly))
        XCTAssertTrue(RoundConfigEditor.canAddToRotation(single, .integrator, available: threeAgents))
        let added = RoundConfigEditor.addingToRotation(single, .integrator, available: threeAgents)
        XCTAssertTrue(added.customized)
        XCTAssertEqual(added.integrators?.map(\.agent), [.codex, .claude])
        XCTAssertEqual(added.integrator.agent, .codex)
        let more = RoundConfigEditor.addingToRotation(added, .integrator, available: threeAgents)
        XCTAssertEqual(more.integrators?.map(\.agent), [.codex, .claude, .gemini])
        let reviewer = RoundConfigEditor.addingToRotation(single, .reviewer, available: threeAgents)
        XCTAssertEqual(reviewer.reviewers?.map(\.choice.agent), [.codex, .claude])
    }

    /// Editing an entry reaches the rotation the engine reads; editing entry 0 reaches the single field too.
    func testEditingAnEntryReachesTheRound() throws {
        let config = try fullWithEveryAgent()
        let second = RoundConfigEditor.selecting(config, at: .init(keyPath: .polisherEntry(1)), agent: .codex, model: "gpt-6-sol", available: threeAgents)
        XCTAssertEqual(second.polisher(rotation: 1)?.agent, .codex)
        XCTAssertEqual(second.polisher?.agent, .claude)
        XCTAssertTrue(second.customized)
        let first = RoundConfigEditor.selecting(config, at: .init(keyPath: .polisher), agent: .gemini, model: GeminiProfile.defaultPlanningModel, available: threeAgents)
        XCTAssertEqual(first.polisher?.agent, .gemini)
        XCTAssertEqual(first.polisher(rotation: 0)?.agent, .gemini)
        XCTAssertEqual(first.polisher(rotation: 3)?.agent, .gemini, "wraps to entry 0")
        let reviewer = RoundConfigEditor.updatingFallback(config, at: .reviewerEntry(1), to: nil)
        XCTAssertNil(reviewer.reviewer(rotation: 1)?.fallback)
        XCTAssertNotNil(reviewer.reviewer(rotation: 0)?.fallback)
        let model = RoundConfigEditor.updatingChoice(config, at: .reviewer) { $0.model = "other" }
        XCTAssertEqual(model.reviewers?.first?.choice.model, "other")
        XCTAssertEqual(model.reviewer(rotation: 2)?.choice.model, "other")
    }

    /// A rotation that holds only the cross-reviewer's family has no round to cross-check; one that
    /// holds another family does.
    func testSameFamilyCaptionFollowsTheWholeRotation() throws {
        var config = try fullWithEveryAgent()
        config.crossReviewer = Slot(config.reviewers![1].choice)
        XCTAssertFalse(RoundConfigEditor.crossCheckSameFamily(config), "codex reviews round 1")
        config.reviewers = nil
        config.reviewer = config.crossReviewer
        XCTAssertTrue(RoundConfigEditor.crossCheckSameFamily(config))
    }

    // MARK: - effortChoices

    /// `ultra` enables delegation and isn't Pro — it must never appear as a choice here even
    /// though `ModelChoice.effort` is a bare `String` that would happily hold it.
    func testEffortChoicesExcludesUltra() {
        XCTAssertEqual(RoundConfigEditor.effortChoices, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertFalse(RoundConfigEditor.effortChoices.contains("ultra"))
    }

    // MARK: - slots(of:)

    /// Full plan fills every seat, so this is the one preset whose row order exercises all
    /// seven roles at once — Sketch/Feature plan leave synthesizer/polisher (Sketch) or nothing
    /// (Feature plan) out, which would silently hide an ordering bug the other presets can't.
    /// Both harnesses are available, so `.firstAndLast` cross-check is live and crossReviewer
    /// sits right after reviewer.
    func testSlotsOfFullPlanOrder() throws {
        let config = try fullPlan()
        let roles = RoundConfigEditor.slots(of: config).map(\.role)
        XCTAssertEqual(roles, ["drafter", "drafter", "drafter", "drafter", "synthesizer", "reviewer", "crossReviewer", "integrator", "encoder", "polisher"])
    }

    func testSlotsOfFullPlanPersonasFollowDrafterOrder() throws {
        let config = try fullPlan()
        let personas = RoundConfigEditor.slots(of: config).map(\.persona)
        // The reviewer and crossReviewer seats are `Slot`s too, so they carry `Slot.init`'s
        // default `.general` persona rather than nil — only integrator/encoder/polisher (bare
        // `ModelChoice`, no persona field at all) are genuinely nil here.
        XCTAssertEqual(personas, [.arbiter, .realist, .coverage, .stressTest, .arbiter, .general, .general, nil, nil, nil])
    }

    /// Sketch has no synthesizer and no polisher — `slots(of:)` must skip both rather than
    /// emit a row with nothing to bind to.
    func testSlotsOfSketchOmitsAbsentSeats() throws {
        let config = try XCTUnwrap(PresetExpansion.config(for: .sketch, available: available))
        let roles = RoundConfigEditor.slots(of: config).map(\.role)
        XCTAssertEqual(roles, ["drafter", "reviewer", "integrator", "encoder"])
    }

    /// Feature plan defaults `crossCheck` to `.firstAndLast` with both harnesses available
    /// (`PresetExpansion`), so the second reviewer's row sits right after the primary's.
    func testSlotsOfFeaturePlanListsCrossReviewerAfterReviewer() throws {
        let config = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: available))
        let roles = RoundConfigEditor.slots(of: config).map(\.role)
        XCTAssertEqual(roles, ["drafter", "drafter", "synthesizer", "reviewer", "crossReviewer", "integrator", "encoder", "polisher"])
    }

    /// Sketch seeds a `crossReviewer` too (so turning cross-check on later needs no extra
    /// step), but its policy defaults to `.off` — the row must stay hidden until a human turns
    /// the picker on, even though the seat underneath it is already filled.
    func testSlotsOfSketchHidesCrossReviewerWhilePolicyIsOff() throws {
        let config = try XCTUnwrap(PresetExpansion.config(for: .sketch, available: available))
        XCTAssertEqual(config.crossCheck, .off)
        XCTAssertNotNil(config.crossReviewer)
        let roles = RoundConfigEditor.slots(of: config).map(\.role)
        XCTAssertFalse(roles.contains("crossReviewer"))
    }

    // MARK: - polish controls

    /// Sketch has no polisher, so its polish cap and fresh-eyes toggle are disabled and say why;
    /// left live, turning fresh eyes on planned rounds nobody could seat.
    func testPolishControlsDisabledWithoutAPolisher() throws {
        let sketch = try XCTUnwrap(PresetExpansion.config(for: .sketch, available: available))
        XCTAssertFalse(RoundConfigEditor.polishControlsEnabled(sketch))
        XCTAssertTrue(RoundConfigEditor.polishControlsHelp(sketch).contains("no polisher"))

        let full = try fullPlan()
        XCTAssertTrue(RoundConfigEditor.polishControlsEnabled(full))
        XCTAssertEqual(RoundConfigEditor.polishControlsHelp(full), "")
    }

    // MARK: - setting

    /// The pure mutation helper every field edit in the view routes through: it applies the
    /// caller's change AND flips `customized`, without touching the config passed in.
    func testSettingAppliesMutationAndMarksCustomized() throws {
        let original = try fullPlan()
        XCTAssertFalse(original.customized)

        let updated = RoundConfigEditor.setting(original) { $0.refinementCap = 9 }

        XCTAssertEqual(updated.refinementCap, 9)
        XCTAssertTrue(updated.customized)
        XCTAssertFalse(original.customized, "setting must not mutate its input")
        XCTAssertEqual(original.refinementCap, 5)
    }

    func testSettingIsIdempotentOnCustomizedFlag() throws {
        var config = try fullPlan()
        config.customized = true
        let updated = RoundConfigEditor.setting(config) { $0.polishCap = 1 }
        XCTAssertTrue(updated.customized)
    }

    // MARK: - choice(for:in:) / fallback(for:in:)

    func testChoiceForKeyPathReadsEachSeat() throws {
        let config = try fullPlan()
        XCTAssertEqual(RoundConfigEditor.choice(for: .drafter(0), in: config), config.drafters[0].choice)
        XCTAssertEqual(RoundConfigEditor.choice(for: .synthesizer, in: config), config.synthesizer?.choice)
        XCTAssertEqual(RoundConfigEditor.choice(for: .reviewer, in: config), config.reviewer?.choice)
        XCTAssertEqual(RoundConfigEditor.choice(for: .integrator, in: config), config.integrator)
        XCTAssertEqual(RoundConfigEditor.choice(for: .encoder, in: config), config.encoder)
        XCTAssertEqual(RoundConfigEditor.choice(for: .polisher, in: config), config.polisher)
    }

    /// `ModelChoice` has no fallback field of its own — the fallback Picker only exists for
    /// drafter/synthesizer/reviewer rows, which are `Slot`s.
    func testFallbackOnlySupportedOnSlotSeats() {
        XCTAssertTrue(RoundConfigEditor.supportsFallback(.drafter(0)))
        XCTAssertTrue(RoundConfigEditor.supportsFallback(.synthesizer))
        XCTAssertTrue(RoundConfigEditor.supportsFallback(.reviewer))
        XCTAssertFalse(RoundConfigEditor.supportsFallback(.integrator))
        XCTAssertFalse(RoundConfigEditor.supportsFallback(.encoder))
        XCTAssertFalse(RoundConfigEditor.supportsFallback(.polisher))
    }

    // MARK: - switchingAgent

    /// Switching a slot's harness must reset both model AND effort to that harness's default
    /// from `available` — a stale model string paired with the new harness would silently
    /// send e.g. codex a claude model name.
    func testSwitchingHarnessResetsModelAndEffort() throws {
        let config = try fullPlan()
        XCTAssertEqual(config.drafters[0].choice.agent, .codex)

        let updated = RoundConfigEditor.selecting(config, at: .init(keyPath: .drafter(0)), agent: .claude, model: "opus", available: available)

        XCTAssertEqual(updated.drafters[0].choice, available.claude)
        XCTAssertTrue(updated.customized)
        // Everything else in the seat (persona, fallback) is untouched by a harness switch.
        XCTAssertEqual(updated.drafters[0].persona, config.drafters[0].persona)
        XCTAssertEqual(updated.drafters[0].fallback, config.drafters[0].fallback)
    }

    func testSwitchingHarnessOnIntegratorSeat() throws {
        let config = try fullPlan()
        let updated = RoundConfigEditor.selecting(config, at: .init(keyPath: .integrator), agent: .codex, model: "gpt-6-sol", available: available)
        XCTAssertEqual(updated.integrator, available.codex)
    }

    // MARK: - agents(in:)

    func testHarnessesLimitedToAvailable() {
        let codexOnly = AvailableModels(codex: available.codex, claude: nil)
        XCTAssertEqual(RoundConfigEditor.agents(in: codexOnly), [.codex])
        XCTAssertEqual(RoundConfigEditor.agents(in: available), [.codex, .claude])
    }

    // MARK: - crossCheckRounds(_:) and summary(preset:config:)

    func testSummaryNamesCrossCheckRounds() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        XCTAssertTrue(RoundConfigEditor.summary(preset: .featurePlan, config: cfg).contains("cross-check R1, R3"))
        var off = cfg; off.crossCheck = .off
        XCTAssertFalse(RoundConfigEditor.summary(preset: .featurePlan, config: off).contains("cross-check"))
        var same = cfg; same.crossReviewer = cfg.reviewer; same.reviewers = nil
        XCTAssertEqual(RoundConfigEditor.crossCheckRounds(same), [])
        var every = cfg; every.crossCheck = .every
        XCTAssertEqual(RoundConfigEditor.crossCheckRounds(every), [1, 2, 3])
    }

    /// Turning cross-checks on with only one harness installed can't seat a cross-check agent;
    /// the inspector says why under the picker instead of silently leaving no row (spec §3).
    func testCrossCheckOnWithOneFamilyExplainsWhy() throws {
        let codexOnly = AvailableModels(codex: available.codex, claude: nil)
        let base = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: codexOnly))
        XCTAssertNil(RoundConfigEditor.crossCheckUnavailableNote(base, available: codexOnly), "nothing to explain while off")
        let on = RoundConfigEditor.settingCrossCheck(base, to: .firstAndLast, available: codexOnly)
        XCTAssertNil(on.crossReviewer)
        XCTAssertEqual(RoundConfigEditor.crossCheckUnavailableNote(on, available: codexOnly),
                       "Cross-checks need a second model family; only one is installed.")
        let both = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        XCTAssertNil(RoundConfigEditor.crossCheckUnavailableNote(both, available: .defaults))
    }
}
