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
    /// six roles at once — Sketch/Feature plan leave synthesizer/polisher (Sketch) or nothing
    /// (Feature plan) out, which would silently hide an ordering bug the other presets can't.
    func testSlotsOfFullPlanOrder() throws {
        let config = try fullPlan()
        let roles = RoundConfigEditor.slots(of: config).map(\.role)
        XCTAssertEqual(roles, ["drafter", "drafter", "drafter", "drafter", "synthesizer", "reviewer", "integrator", "encoder", "polisher"])
    }

    func testSlotsOfFullPlanPersonasFollowDrafterOrder() throws {
        let config = try fullPlan()
        let personas = RoundConfigEditor.slots(of: config).map(\.persona)
        // The reviewer seat is a `Slot` too, so it carries `Slot.init`'s default `.general`
        // persona rather than nil — only integrator/encoder/polisher (bare `ModelChoice`, no
        // persona field at all) are genuinely nil here.
        XCTAssertEqual(personas, [.arbiter, .realist, .coverage, .stressTest, .arbiter, .general, nil, nil, nil])
    }

    /// Sketch has no synthesizer and no polisher — `slots(of:)` must skip both rather than
    /// emit a row with nothing to bind to.
    func testSlotsOfSketchOmitsAbsentSeats() throws {
        let config = try XCTUnwrap(PresetExpansion.config(for: .sketch, available: available))
        let roles = RoundConfigEditor.slots(of: config).map(\.role)
        XCTAssertEqual(roles, ["drafter", "reviewer", "integrator", "encoder"])
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
}
