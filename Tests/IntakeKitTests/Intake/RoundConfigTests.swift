import XCTest
import IntakeKit

final class RoundConfigTests: XCTestCase {
    private let codexOnly = AvailableModels(codex: .init(agent: .codex, model: "gpt-6-sol", effort: "high"), claude: nil)
    private let claudeOnly = AvailableModels(codex: nil, claude: .init(agent: .claude, model: "opus", effort: "high"))

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
        XCTAssertEqual(cfg.drafters[0].choice.agent, .codex)
        XCTAssertEqual(cfg.drafters[0].persona, .general)
        XCTAssertEqual(cfg.drafters[0].fallback?.agent, .claude)
        XCTAssertNil(cfg.synthesizer)
        XCTAssertEqual(cfg.reviewer?.choice.agent, .codex)
        XCTAssertEqual(cfg.reviewer?.fallback?.agent, .claude)
        XCTAssertEqual(cfg.integrator.agent, .claude)
        XCTAssertEqual(cfg.encoder.agent, .codex)
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
        XCTAssertEqual(cfg.integrator.agent, .claude)
        XCTAssertEqual(cfg.encoder.agent, .claude)
    }

    func testSketchCodexOnly() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .sketch, available: codexOnly))
        XCTAssertEqual(cfg.drafters[0].choice.agent, .codex)
        XCTAssertNil(cfg.drafters[0].fallback)
        XCTAssertEqual(cfg.reviewer?.choice.agent, .codex)
        XCTAssertNil(cfg.reviewer?.fallback)
        // No claude to integrate with, so A stands in.
        XCTAssertEqual(cfg.integrator.agent, .codex)
    }

    // MARK: - Feature plan

    func testFeaturePlanBothModelsPresent() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        XCTAssertEqual(cfg.drafters.map(\.persona), [.arbiter, .realist])
        XCTAssertEqual(cfg.drafters.map(\.choice.agent), [.codex, .claude])
        XCTAssertEqual(cfg.drafters[0].fallback?.agent, .claude)
        XCTAssertEqual(cfg.drafters[1].fallback?.agent, .codex)
        XCTAssertEqual(cfg.synthesizer?.choice.agent, .codex)
        XCTAssertEqual(cfg.synthesizer?.persona, .arbiter)
        XCTAssertEqual(cfg.synthesizer?.fallback?.agent, .claude)
        XCTAssertEqual(cfg.reviewer?.choice.agent, .codex)
        XCTAssertEqual(cfg.reviewer?.fallback?.agent, .claude)
        XCTAssertEqual(cfg.refinementCap, 3)
        XCTAssertEqual(cfg.polisher?.agent, .claude)
        XCTAssertEqual(cfg.polishCap, 2)
        XCTAssertFalse(cfg.freshEyesAndDedup)
        XCTAssertEqual(cfg.defaultPlay, .nextMajor)
        XCTAssertEqual(cfg.integrator.agent, .claude)
        XCTAssertEqual(cfg.encoder.agent, .codex)
    }

    func testFeaturePlanCodexOnly() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: codexOnly))
        XCTAssertEqual(cfg.drafters.map(\.choice.agent), [.codex, .codex])
        XCTAssertNil(cfg.drafters[0].fallback)
        XCTAssertNil(cfg.drafters[1].fallback)
        XCTAssertNil(cfg.synthesizer?.fallback)
        XCTAssertNil(cfg.reviewer?.fallback)
        // Claude isn't installed, so the polisher (which defaults to claude) falls back to A.
        XCTAssertEqual(cfg.polisher?.agent, .codex)
        XCTAssertEqual(cfg.integrator.agent, .codex)
    }

    func testFeaturePlanClaudeOnly() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: claudeOnly))
        XCTAssertEqual(cfg.drafters.map(\.choice.agent), [.claude, .claude])
        XCTAssertNil(cfg.drafters[0].fallback)
        XCTAssertNil(cfg.synthesizer?.fallback)
        XCTAssertNil(cfg.reviewer?.fallback)
        XCTAssertEqual(cfg.polisher?.agent, .claude)
        XCTAssertEqual(cfg.integrator.agent, .claude)
    }

    // MARK: - Full plan

    func testFullPlanPersonasAndFallbacks() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: .defaults))
        XCTAssertEqual(cfg.drafters.map(\.persona), [.arbiter, .realist, .coverage, .stressTest])
        XCTAssertEqual(cfg.drafters.map(\.choice.agent), [.codex, .claude, .codex, .claude])
        XCTAssertEqual(cfg.drafters[0].fallback?.agent, .claude)
        XCTAssertEqual(cfg.drafters[1].fallback?.agent, .codex)
        XCTAssertEqual(cfg.drafters[2].fallback?.agent, .claude)
        XCTAssertEqual(cfg.drafters[3].fallback?.agent, .codex)
        XCTAssertEqual(cfg.refinementCap, 5)
        XCTAssertEqual(cfg.polishCap, 6)
        XCTAssertTrue(cfg.freshEyesAndDedup)
        XCTAssertEqual(cfg.polisher?.agent, .claude)
        XCTAssertEqual(cfg.integrator.agent, .claude)
        XCTAssertEqual(cfg.defaultPlay, .nextMajor)
        XCTAssertEqual(cfg.synthesizer?.choice.agent, .codex)
        XCTAssertEqual(cfg.synthesizer?.persona, .arbiter)
        XCTAssertEqual(cfg.synthesizer?.fallback?.agent, .claude)
        XCTAssertEqual(cfg.reviewer?.choice.agent, .codex)
        XCTAssertEqual(cfg.reviewer?.fallback?.agent, .claude)
    }

    func testFullPlanSingleModelHasNoFallbacks() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: claudeOnly))
        XCTAssertEqual(cfg.drafters.count, 4)
        for slot in cfg.drafters { XCTAssertNil(slot.fallback) }
        XCTAssertTrue(cfg.drafters.allSatisfy { $0.choice.agent == .claude })
        XCTAssertNil(cfg.synthesizer?.fallback)
        XCTAssertNil(cfg.reviewer?.fallback)
    }

    /// The brief's expansion table applies equally when only codex is installed — every seat
    /// (drafters, synthesizer, reviewer, polisher, integrator, encoder) collapses onto codex,
    /// with no fallback pointing at a claude that doesn't exist.
    func testFullPlanCodexOnly() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: codexOnly))
        XCTAssertEqual(cfg.drafters.map(\.persona), [.arbiter, .realist, .coverage, .stressTest])
        XCTAssertTrue(cfg.drafters.allSatisfy { $0.choice.agent == .codex })
        for slot in cfg.drafters { XCTAssertNil(slot.fallback) }
        XCTAssertEqual(cfg.synthesizer?.choice.agent, .codex)
        XCTAssertEqual(cfg.synthesizer?.persona, .arbiter)
        XCTAssertNil(cfg.synthesizer?.fallback)
        XCTAssertEqual(cfg.reviewer?.choice.agent, .codex)
        XCTAssertNil(cfg.reviewer?.fallback)
        XCTAssertEqual(cfg.polisher?.agent, .codex)
        XCTAssertEqual(cfg.integrator.agent, .codex)
        XCTAssertEqual(cfg.encoder.agent, .codex)
        XCTAssertEqual(cfg.refinementCap, 5)
        XCTAssertEqual(cfg.polishCap, 6)
        XCTAssertTrue(cfg.freshEyesAndDedup)
    }

    // MARK: - Grok, Gemini and OpenCode

    private func choice(_ agent: AgentID, _ model: String) -> ModelChoice { .init(agent: agent, model: model, effort: "high") }

    private var everyAgent: AvailableModels {
        AvailableModels(choices: [.codex: choice(.codex, "gpt-6-sol"), .claude: choice(.claude, "opus"),
                                  .grok: choice(.grok, "grok-4.7"), .gemini: choice(.gemini, "gemini-3.1-pro-high"),
                                  .opencode: choice(.opencode, "anthropic/claude-sonnet-5-5")])
    }

    /// Every seat a config fills, fallbacks included.
    private func seats(_ cfg: RoundConfig) -> [ModelChoice] {
        let slots = cfg.drafters + [cfg.synthesizer, cfg.reviewer, cfg.crossReviewer].compactMap { $0 }
        return slots.flatMap { [$0.choice] + [$0.fallback].compactMap { $0 } }
            + [cfg.integrator, cfg.encoder] + [cfg.polisher].compactMap { $0 }
            + cfg.reviewerRotation.flatMap { [$0.choice] + [$0.fallback].compactMap { $0 } }
            + cfg.integratorRotation + cfg.polisherRotation
    }

    /// Detected Gemini and Grok get seats by default (the maintainer, 2026-10-13): Gemini cross-checks
    /// every preset, and a Full plan's coverage and stress-test drafters go to Gemini and Grok.
    /// Codex and Claude keep the seats that run every round.
    func testDetectedGeminiAndGrokTakeTheirSeats() throws {
        let sketch = try XCTUnwrap(PresetExpansion.config(for: .sketch, available: everyAgent))
        XCTAssertEqual(sketch.drafters.map(\.choice.agent), [.codex])
        XCTAssertEqual(sketch.crossReviewer?.choice.agent, .gemini)
        XCTAssertEqual(sketch.crossCheck, .off)

        let feature = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: everyAgent))
        XCTAssertEqual(feature.drafters.map(\.choice.agent), [.codex, .claude])
        XCTAssertEqual(feature.crossReviewer?.choice.agent, .gemini)
        XCTAssertEqual(feature.crossCheck, .firstAndLast)
        XCTAssertTrue(feature.crossChecks)

        let full = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: everyAgent))
        XCTAssertEqual(full.drafters.map(\.persona), [.arbiter, .realist, .coverage, .stressTest])
        XCTAssertEqual(full.drafters.map(\.choice.agent), [.codex, .claude, .gemini, .grok])
        XCTAssertEqual(full.drafters.map(\.fallback?.agent), [.claude, .codex, .codex, .claude])
        XCTAssertEqual(full.drafters[2].choice.model, "gemini-3.1-pro-high", "the detected model, not a stock one")
        XCTAssertEqual(full.crossReviewer?.choice.agent, .gemini)
        XCTAssertTrue(full.crossChecks)

        for cfg in [sketch, feature, full] {
            XCTAssertEqual(cfg.reviewer?.choice.agent, .codex, "Grok never reviews by default: it is the slow seat")
            XCTAssertEqual(cfg.integrator.agent, .claude)
            XCTAssertEqual(cfg.encoder.agent, .codex)
        }
    }

    /// Offered in the editor, never seated by a preset.
    func testOpenCodeIsNeverADefaultSeat() throws {
        let onlyOpenCodeExtra = AvailableModels(choices: [.codex: choice(.codex, "gpt-6-sol"), .claude: choice(.claude, "opus"),
                                                          .opencode: choice(.opencode, "anthropic/claude-sonnet-5-5")])
        for available in [everyAgent, onlyOpenCodeExtra] {
            XCTAssertTrue(available.agents.contains(.opencode), "available to pick")
            for preset in [Preset.sketch, .featurePlan, .fullPlan] {
                let cfg = try XCTUnwrap(PresetExpansion.config(for: preset, available: available))
                XCTAssertFalse(seats(cfg).contains { $0.agent == .opencode }, "\(preset)")
            }
        }
        XCTAssertEqual(PresetExpansion.config(for: .fullPlan, available: onlyOpenCodeExtra),
                       PresetExpansion.config(for: .fullPlan, available: .defaults))
    }

    /// Without Gemini, Grok cross-checks; it still never reviews.
    func testGrokCrossChecksWhenThereIsNoGemini() throws {
        var available = AvailableModels.defaults
        available = AvailableModels(choices: available.choices.merging([.grok: choice(.grok, "grok-4.7")]) { a, _ in a })
        let full = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: available))
        XCTAssertEqual(full.crossReviewer?.choice.agent, .grok)
        XCTAssertEqual(full.drafters.map(\.choice.agent), [.codex, .claude, .codex, .grok])
        XCTAssertEqual(full.reviewer?.choice.agent, .codex)
    }

    /// One primary harness plus Gemini still cross-checks: Gemini is a second family.
    func testASingleHarnessCrossChecksWithGemini() throws {
        let available = AvailableModels(choices: [.claude: choice(.claude, "opus"), .gemini: choice(.gemini, "gemini-3.1-pro-high")])
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: available))
        XCTAssertEqual(cfg.drafters.map(\.choice.agent), [.claude, .claude])
        XCTAssertNil(cfg.reviewer?.fallback)
        XCTAssertEqual(cfg.crossReviewer?.choice.agent, .gemini)
        XCTAssertTrue(cfg.crossChecks)
    }


    // MARK: - Rotations

    private var noGemini: AvailableModels {
        AvailableModels(choices: [.codex: choice(.codex, "gpt-6-sol"), .claude: choice(.claude, "opus"),
                                  .grok: choice(.grok, "grok-4.7")])
    }

    private func agents(_ list: [ModelChoice]?) -> [AgentID]? { list?.map(\.agent) }

    /// A Full plan with every agent: the reviewer alternates codex and claude (each falling back
    /// to the other), the integrator claude and codex, and the polisher claude, gemini, codex.
    /// Grok and OpenCode are in no rotation. Entry 0 is the single field an older reader sees.
    func testFullPlanRotatesWithEveryAgent() throws {
        let full = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: everyAgent))
        XCTAssertEqual(full.reviewers?.map(\.choice.agent), [.codex, .claude])
        XCTAssertEqual(full.reviewers?.map(\.fallback?.agent), [.claude, .codex])
        XCTAssertEqual(agents(full.integrators), [.claude, .codex])
        XCTAssertEqual(agents(full.polishers), [.claude, .gemini, .codex])
        XCTAssertEqual(full.reviewers?.first, full.reviewer)
        XCTAssertEqual(full.integrators?.first, full.integrator)
        XCTAssertEqual(full.polishers?.first, full.polisher)
        XCTAssertEqual(full.polishers?[1].model, "gemini-3.1-pro-high", "the detected model")
        XCTAssertEqual(full.crossReviewer?.choice.agent, .gemini, "the cross-reviewer stays Gemini")
        XCTAssertEqual(full.drafters.map(\.choice.agent), [.codex, .claude, .gemini, .grok], "drafters unchanged")
        let feature = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: everyAgent))
        XCTAssertEqual(feature.reviewers?.map(\.choice.agent), [.codex, .claude])
        XCTAssertEqual(agents(feature.integrators), [.claude, .codex])
        XCTAssertEqual(agents(feature.polishers), [.claude, .gemini, .codex])
        for cfg in [full, feature] {
            XCTAssertFalse(seats(cfg).contains { $0.agent == .grok && $0 != cfg.drafters.last?.choice }, "Grok only drafts")
            XCTAssertFalse(seats(cfg).contains { $0.agent == .opencode })
            XCTAssertFalse((cfg.reviewerRotation.map(\.choice) + cfg.integratorRotation + cfg.polisherRotation).contains { $0.agent == .grok })
        }
    }

    /// Without Gemini the polisher goes claude, codex; Sketch rotates its reviewer and integrator
    /// and has no polisher.
    func testRotationsWithoutGeminiAndInSketch() throws {
        let full = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: noGemini))
        XCTAssertEqual(agents(full.polishers), [.claude, .codex])
        XCTAssertEqual(full.reviewers?.map(\.choice.agent), [.codex, .claude])
        let sketch = try XCTUnwrap(PresetExpansion.config(for: .sketch, available: everyAgent))
        XCTAssertEqual(sketch.reviewers?.map(\.choice.agent), [.codex, .claude])
        XCTAssertEqual(agents(sketch.integrators), [.claude, .codex])
        XCTAssertNil(sketch.polishers)
        XCTAssertNil(sketch.polisher)
    }

    /// One family on the machine, Gemini or not: no rotations, exactly as before.
    func testASingleFamilyHasNoRotations() throws {
        let geminiToo = AvailableModels(choices: [.claude: choice(.claude, "opus"), .gemini: choice(.gemini, "gemini-3.1-pro-high")])
        let codexGemini = AvailableModels(choices: [.codex: choice(.codex, "gpt-6-sol"), .gemini: choice(.gemini, "gemini-3.1-pro-high")])
        for available in [codexOnly, claudeOnly, geminiToo, codexGemini] {
            for preset in [Preset.sketch, .featurePlan, .fullPlan] {
                let cfg = try XCTUnwrap(PresetExpansion.config(for: preset, available: available))
                XCTAssertNil(cfg.reviewers); XCTAssertNil(cfg.integrators); XCTAssertNil(cfg.polishers)
            }
        }
    }

    /// The headline: every agent detected, no one family runs more than half of a Full plan's
    /// post-encode rounds, and Claude no longer runs every integrator round.
    func testNoFamilyRunsMoreThanHalfOfFullPlansPostEncodeRounds() throws {
        let full = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: everyAgent))
        let rounds = TapePlanner.plannedRounds(config: full, tape: .empty)
        let afterEncode = rounds.drop(while: { $0.stage != .encode }).dropFirst()
        XCTAssertEqual(afterEncode.count, 8)
        let polishers = afterEncode.map { RoundParticipants.of($0, config: full).first!.slot!.choice.agent }
        XCTAssertEqual(polishers, [.claude, .gemini, .codex, .claude, .gemini, .codex, .claude, .gemini])
        for family in Set(polishers) {
            XCTAssertLessThanOrEqual(polishers.filter { $0 == family }.count, afterEncode.count / 2, "\(family)")
        }
        let integrators = rounds.filter { $0.stage == .refine }.map {
            RoundParticipants.of($0, config: full).first { $0.role == "integrator" }!.slot!.choice.agent
        }
        XCTAssertEqual(integrators, [.claude, .codex, .claude, .codex, .claude])
        // Fresh eyes is never the family that ran the round just before it.
        XCTAssertNotEqual(polishers[6], polishers[5])
        // No refine round pairs a family with itself.
        for round in rounds where round.stage == .refine {
            let seats = RoundParticipants.of(round, config: full)
            let reviewer = seats.first { $0.role == "reviewer" }!.slot!.choice.agent
            let integrator = seats.first { $0.role == "integrator" }!.slot!.choice.agent
            XCTAssertNotEqual(reviewer, integrator, "refine \(round.round)")
        }
    }

    /// An intake.json from before rotations has none of the three keys and keeps its one agent
    /// for every round; a rotation round-trips.
    func testRotationsDecodeAbsentAndRoundTrip() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: everyAgent))
        let again = try IntakeJSON.decoder.decode(RoundConfig.self, from: IntakeJSON.encoder.encode(cfg))
        XCTAssertEqual(again, cfg)
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: IntakeJSON.encoder.encode(cfg)) as? [String: Any])
        for key in ["reviewers", "integrators", "polishers"] { XCTAssertNotNil(dict.removeValue(forKey: key), key) }
        let old = try IntakeJSON.decoder.decode(RoundConfig.self, from: JSONSerialization.data(withJSONObject: dict))
        XCTAssertNil(old.reviewers); XCTAssertNil(old.integrators); XCTAssertNil(old.polishers)
        for i in 0..<6 {
            XCTAssertEqual(old.reviewer(rotation: i), cfg.reviewer)
            XCTAssertEqual(old.integrator(rotation: i), cfg.integrator)
            XCTAssertEqual(old.polisher(rotation: i), cfg.polisher)
        }
    }

    /// An empty rotation reads as none.
    func testAnEmptyRotationIsTheSingleAgent() throws {
        var cfg = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: .defaults))
        cfg.reviewers = []; cfg.integrators = []; cfg.polishers = []
        XCTAssertEqual(cfg.reviewer(rotation: 3), cfg.reviewer)
        XCTAssertEqual(cfg.integrator(rotation: 3), cfg.integrator)
        XCTAssertEqual(cfg.polisher(rotation: 3), cfg.polisher)
        XCTAssertEqual(cfg.integratorRotation, [cfg.integrator])
    }

    /// Every agent a rotation can run has its account resolved up front.
    func testAgentsIncludeEveryRotationEntry() {
        var cfg = RoundConfig(drafters: [Slot(choice(.codex, "x"))], synthesizer: nil, reviewer: Slot(choice(.codex, "x")),
                              integrator: choice(.codex, "x"), encoder: choice(.codex, "x"), polisher: choice(.codex, "x"),
                              refinementCap: 1, polishCap: 1, freshEyesAndDedup: false, defaultPlay: .step, customized: false)
        XCTAssertEqual(cfg.agents, [.codex])
        cfg.reviewers = [Slot(choice(.codex, "x")), Slot(choice(.claude, "y"))]
        cfg.integrators = [choice(.codex, "x"), choice(.grok, "g")]
        cfg.polishers = [choice(.codex, "x"), choice(.gemini, "z")]
        XCTAssertEqual(cfg.agents, [.codex, .claude, .grok, .gemini])
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

    // MARK: - Cross-check (coverage spec §3)

    func testCrossCheckDefaultsPerPreset() throws {
        let sketch = try XCTUnwrap(PresetExpansion.config(for: .sketch, available: .defaults))
        XCTAssertEqual(sketch.crossCheck, .off)
        XCTAssertEqual(sketch.crossReviewer?.choice.agent, .claude)
        XCTAssertNil(sketch.crossReviewer?.fallback, "a same-family fallback is not a cross-check")
        for preset in [Preset.featurePlan, .fullPlan] {
            let cfg = try XCTUnwrap(PresetExpansion.config(for: preset, available: .defaults))
            XCTAssertEqual(cfg.crossCheck, .firstAndLast, "\(preset)")
            XCTAssertEqual(cfg.crossReviewer?.choice.agent, .claude, "\(preset)")
            XCTAssertTrue(cfg.crossChecks, "\(preset)")
        }
    }

    func testSingleHarnessNeverCrossChecks() throws {
        for available in [codexOnly, claudeOnly] {
            let cfg = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: available))
            XCTAssertNil(cfg.crossReviewer)
            XCTAssertNil(cfg.crossCheck)
            XCTAssertFalse(cfg.crossChecks)
        }
    }

    func testSameFamilyCrossReviewerDoesNotCrossCheck() throws {
        var cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        cfg.crossReviewer = cfg.reviewer
        cfg.reviewers = nil
        XCTAssertFalse(cfg.crossChecks)
        // With a rotation that has another family, the other round still cross-checks.
        let rotating = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        var same = rotating
        same.crossReviewer = rotating.reviewer
        XCTAssertTrue(same.crossChecks)
        XCTAssertEqual(same.crossReviewer(rotation: 0)?.choice.agent, .claude, "the rotation's other family")
    }

    /// An intake.json written before cross-checks existed decodes to "off" (Review Focus 1).
    func testOldConfigDecodesWithCrossCheckOff() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: IntakeJSON.encoder.encode(cfg)) as? [String: Any])
        dict.removeValue(forKey: "crossCheck"); dict.removeValue(forKey: "crossReviewer")
        let old = try IntakeJSON.decoder.decode(RoundConfig.self, from: JSONSerialization.data(withJSONObject: dict))
        XCTAssertNil(old.crossCheck)
        XCTAssertFalse(old.crossChecks)
    }

    func testModelFamilyFollowsHarness() {
        XCTAssertEqual(AgentID.claude.displayName, "Claude")
    }
}
