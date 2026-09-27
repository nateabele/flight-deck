import XCTest
import IntakeKit

final class RoundConfigTests: XCTestCase {
    private let codexOnly = AvailableModels(codex: .init(harness: .codex, model: "gpt-6-sol", effort: "high"), claude: nil)
    private let claudeOnly = AvailableModels(codex: nil, claude: .init(harness: .claude, model: "opus", effort: "high"))

    // MARK: - Bead

    func testBeadHasNoRoundConfig() {
        XCTAssertNil(PresetExpansion.config(for: .bead, available: .defaults))
        XCTAssertNil(PresetExpansion.config(for: .bead, available: codexOnly))
        XCTAssertNil(PresetExpansion.config(for: .bead, available: claudeOnly))
    }

    // MARK: - Sketch

    func testSketchBothModelsPresent() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .sketch, available: .defaults))
        XCTAssertEqual(cfg.drafters.count, 1)
        XCTAssertEqual(cfg.drafters[0].choice.harness, .codex)
        XCTAssertEqual(cfg.drafters[0].persona, .general)
        XCTAssertEqual(cfg.drafters[0].fallback?.harness, .claude)
        XCTAssertNil(cfg.synthesizer)
        XCTAssertEqual(cfg.reviewer?.choice.harness, .codex)
        XCTAssertEqual(cfg.reviewer?.fallback?.harness, .claude)
        XCTAssertEqual(cfg.integrator.harness, .claude)
        XCTAssertEqual(cfg.encoder.harness, .codex)
        XCTAssertNil(cfg.polisher)
        XCTAssertEqual(cfg.refinementCap, 2)
        XCTAssertEqual(cfg.polishCap, 0)
        XCTAssertFalse(cfg.freshEyesAndDedup)
        XCTAssertEqual(cfg.defaultPlay, .toReview)
        XCTAssertFalse(cfg.customized)
    }

    func testSketchSingleModelHasNoFallback() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .sketch, available: claudeOnly))
        XCTAssertEqual(cfg.drafters.count, 1)
        XCTAssertNil(cfg.drafters[0].fallback)
        XCTAssertNil(cfg.synthesizer)
        XCTAssertNil(cfg.reviewer?.fallback)
        XCTAssertNil(cfg.polisher)
        XCTAssertEqual(cfg.defaultPlay, .toReview)
        XCTAssertEqual(cfg.integrator.harness, .claude)
        XCTAssertEqual(cfg.encoder.harness, .claude)
    }

    func testSketchCodexOnly() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .sketch, available: codexOnly))
        XCTAssertEqual(cfg.drafters[0].choice.harness, .codex)
        XCTAssertNil(cfg.drafters[0].fallback)
        XCTAssertEqual(cfg.reviewer?.choice.harness, .codex)
        XCTAssertNil(cfg.reviewer?.fallback)
        // No claude to integrate with, so A stands in.
        XCTAssertEqual(cfg.integrator.harness, .codex)
    }

    // MARK: - Feature plan

    func testFeaturePlanBothModelsPresent() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        XCTAssertEqual(cfg.drafters.map(\.persona), [.arbiter, .realist])
        XCTAssertEqual(cfg.drafters.map(\.choice.harness), [.codex, .claude])
        XCTAssertEqual(cfg.drafters[0].fallback?.harness, .claude)
        XCTAssertEqual(cfg.drafters[1].fallback?.harness, .codex)
        XCTAssertEqual(cfg.synthesizer?.choice.harness, .codex)
        XCTAssertEqual(cfg.synthesizer?.persona, .arbiter)
        XCTAssertEqual(cfg.synthesizer?.fallback?.harness, .claude)
        XCTAssertEqual(cfg.reviewer?.choice.harness, .codex)
        XCTAssertEqual(cfg.reviewer?.fallback?.harness, .claude)
        XCTAssertEqual(cfg.refinementCap, 3)
        XCTAssertEqual(cfg.polisher?.harness, .claude)
        XCTAssertEqual(cfg.polishCap, 2)
        XCTAssertFalse(cfg.freshEyesAndDedup)
        XCTAssertEqual(cfg.defaultPlay, .nextMajor)
        XCTAssertEqual(cfg.integrator.harness, .claude)
        XCTAssertEqual(cfg.encoder.harness, .codex)
    }

    func testFeaturePlanCodexOnly() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: codexOnly))
        XCTAssertEqual(cfg.drafters.map(\.choice.harness), [.codex, .codex])
        XCTAssertNil(cfg.drafters[0].fallback)
        XCTAssertNil(cfg.drafters[1].fallback)
        XCTAssertNil(cfg.synthesizer?.fallback)
        XCTAssertNil(cfg.reviewer?.fallback)
        // Claude isn't installed, so the polisher (which defaults to claude) falls back to A.
        XCTAssertEqual(cfg.polisher?.harness, .codex)
        XCTAssertEqual(cfg.integrator.harness, .codex)
    }

    func testFeaturePlanClaudeOnly() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: claudeOnly))
        XCTAssertEqual(cfg.drafters.map(\.choice.harness), [.claude, .claude])
        XCTAssertNil(cfg.drafters[0].fallback)
        XCTAssertNil(cfg.synthesizer?.fallback)
        XCTAssertNil(cfg.reviewer?.fallback)
        XCTAssertEqual(cfg.polisher?.harness, .claude)
        XCTAssertEqual(cfg.integrator.harness, .claude)
    }

    // MARK: - Full plan

    func testFullPlanPersonasAndFallbacks() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: .defaults))
        XCTAssertEqual(cfg.drafters.map(\.persona), [.arbiter, .realist, .coverage, .stressTest])
        XCTAssertEqual(cfg.drafters.map(\.choice.harness), [.codex, .claude, .codex, .claude])
        XCTAssertEqual(cfg.drafters[0].fallback?.harness, .claude)
        XCTAssertEqual(cfg.drafters[1].fallback?.harness, .codex)
        XCTAssertEqual(cfg.drafters[2].fallback?.harness, .claude)
        XCTAssertEqual(cfg.drafters[3].fallback?.harness, .codex)
        XCTAssertEqual(cfg.refinementCap, 5)
        XCTAssertEqual(cfg.polishCap, 6)
        XCTAssertTrue(cfg.freshEyesAndDedup)
        XCTAssertEqual(cfg.polisher?.harness, .claude)
        XCTAssertEqual(cfg.integrator.harness, .claude)
        XCTAssertEqual(cfg.defaultPlay, .nextMajor)
        XCTAssertEqual(cfg.synthesizer?.choice.harness, .codex)
        XCTAssertEqual(cfg.synthesizer?.persona, .arbiter)
        XCTAssertEqual(cfg.synthesizer?.fallback?.harness, .claude)
        XCTAssertEqual(cfg.reviewer?.choice.harness, .codex)
        XCTAssertEqual(cfg.reviewer?.fallback?.harness, .claude)
    }

    func testFullPlanSingleModelHasNoFallbacks() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: claudeOnly))
        XCTAssertEqual(cfg.drafters.count, 4)
        for slot in cfg.drafters { XCTAssertNil(slot.fallback) }
        XCTAssertTrue(cfg.drafters.allSatisfy { $0.choice.harness == .claude })
        XCTAssertNil(cfg.synthesizer?.fallback)
        XCTAssertNil(cfg.reviewer?.fallback)
    }

    /// The brief's expansion table applies equally when only codex is installed — every seat
    /// (drafters, synthesizer, reviewer, polisher, integrator, encoder) collapses onto codex,
    /// with no fallback pointing at a claude that doesn't exist.
    func testFullPlanCodexOnly() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: codexOnly))
        XCTAssertEqual(cfg.drafters.map(\.persona), [.arbiter, .realist, .coverage, .stressTest])
        XCTAssertTrue(cfg.drafters.allSatisfy { $0.choice.harness == .codex })
        for slot in cfg.drafters { XCTAssertNil(slot.fallback) }
        XCTAssertEqual(cfg.synthesizer?.choice.harness, .codex)
        XCTAssertEqual(cfg.synthesizer?.persona, .arbiter)
        XCTAssertNil(cfg.synthesizer?.fallback)
        XCTAssertEqual(cfg.reviewer?.choice.harness, .codex)
        XCTAssertNil(cfg.reviewer?.fallback)
        XCTAssertEqual(cfg.polisher?.harness, .codex)
        XCTAssertEqual(cfg.integrator.harness, .codex)
        XCTAssertEqual(cfg.encoder.harness, .codex)
        XCTAssertEqual(cfg.refinementCap, 5)
        XCTAssertEqual(cfg.polishCap, 6)
        XCTAssertTrue(cfg.freshEyesAndDedup)
    }

    // MARK: - Round-trip

    func testRoundConfigJSONRoundTrips() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: .defaults))
        let encoded = try IntakeJSON.encoder.encode(cfg)
        let decoded = try IntakeJSON.decoder.decode(RoundConfig.self, from: encoded)
        XCTAssertEqual(decoded, cfg)
    }

    func testIntakeWithChosenPresetAndRoundConfigRoundTrips() throws {
        var intake = Intake(projectPath: "/p", intent: "test")
        intake.state = .shaping
        intake.chosenPreset = .fullPlan
        intake.roundConfig = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: .defaults))
        let encoded = try IntakeJSON.encoder.encode(intake)
        let decoded = try IntakeJSON.decoder.decode(Intake.self, from: encoded)
        XCTAssertEqual(decoded, intake)
        XCTAssertEqual(decoded.state, .shaping)
        XCTAssertEqual(decoded.chosenPreset, .fullPlan)
    }

    // MARK: - Backward compatibility

    /// An `Intake` persisted before `chosenPreset`/`roundConfig` existed must still decode,
    /// with both new fields coming back nil rather than throwing.
    func testPreRoundsIntakeStillDecodes() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "intake-pre-rounds", withExtension: "json", subdirectory: "Fixtures/Intake"))
        let data = try Data(contentsOf: url)
        let decoded = try IntakeJSON.decoder.decode(Intake.self, from: data)
        XCTAssertEqual(decoded.intent, "add a tooltip to the send button")
        XCTAssertEqual(decoded.state, .awaitingChoice)
        XCTAssertEqual(decoded.recommended, .sketch)
        XCTAssertNil(decoded.chosenPreset)
        XCTAssertNil(decoded.roundConfig)
    }
}
