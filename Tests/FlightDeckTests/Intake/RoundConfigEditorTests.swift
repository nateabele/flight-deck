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

    // MARK: - switchingHarness

    /// Switching a slot's harness must reset both model AND effort to that harness's default
    /// from `available` — a stale model string paired with the new harness would silently
    /// send e.g. codex a claude model name.
    func testSwitchingHarnessResetsModelAndEffort() throws {
        let config = try fullPlan()
        XCTAssertEqual(config.drafters[0].choice.harness, .codex)

        let updated = RoundConfigEditor.switchingHarness(config, at: .drafter(0), to: .claude, available: available)

        XCTAssertEqual(updated.drafters[0].choice, available.claude)
        XCTAssertTrue(updated.customized)
        // Everything else in the seat (persona, fallback) is untouched by a harness switch.
        XCTAssertEqual(updated.drafters[0].persona, config.drafters[0].persona)
        XCTAssertEqual(updated.drafters[0].fallback, config.drafters[0].fallback)
    }

    func testSwitchingHarnessOnIntegratorSeat() throws {
        let config = try fullPlan()
        let updated = RoundConfigEditor.switchingHarness(config, at: .integrator, to: .codex, available: available)
        XCTAssertEqual(updated.integrator, available.codex)
    }

    // MARK: - harnesses(in:)

    func testHarnessesLimitedToAvailable() {
        let codexOnly = AvailableModels(codex: available.codex, claude: nil)
        XCTAssertEqual(RoundConfigEditor.harnesses(in: codexOnly), [.codex])
        XCTAssertEqual(RoundConfigEditor.harnesses(in: available), [.codex, .claude])
    }

    // MARK: - crossCheckRounds(_:) and summary(preset:config:)

    func testSummaryNamesCrossCheckRounds() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        XCTAssertTrue(RoundConfigEditor.summary(preset: .featurePlan, config: cfg).contains("cross-check R1, R3"))
        var off = cfg; off.crossCheck = .off
        XCTAssertFalse(RoundConfigEditor.summary(preset: .featurePlan, config: off).contains("cross-check"))
        var same = cfg; same.crossReviewer = cfg.reviewer
        XCTAssertEqual(RoundConfigEditor.crossCheckRounds(same), [])
        var every = cfg; every.crossCheck = .every
        XCTAssertEqual(RoundConfigEditor.crossCheckRounds(every), [1, 2, 3])
    }
}
