import FleetKit
import UIKit
import XCTest
@testable import FlightDeckMobile

final class RoundInspectorModelTests: XCTestCase {
    private func choice(_ agent: String, _ name: String, _ model: String, _ effort: String = "high") -> WireModelChoice {
        WireModelChoice(agent: agent, agentName: name, model: model, effort: effort)
    }

    private var codex: WireModelChoice { choice("codex", "Codex", "gpt-6-sol") }
    private var claude: WireModelChoice { choice("claude", "Claude", "opus") }

    private func full(customized: Bool = false) -> WireRoundConfig {
        WireRoundConfig(
            drafters: [WireSeat(choice: codex, persona: "arbiter", fallback: claude),
                       WireSeat(choice: claude, persona: "realist", fallback: codex)],
            synthesizer: WireSeat(choice: codex, persona: "arbiter"),
            reviewer: WireSeat(choice: codex, persona: "general", fallback: claude),
            crossReviewer: WireSeat(choice: claude, persona: "general"), crossCheck: "firstAndLast",
            integrator: WireSeat(choice: claude), encoder: WireSeat(choice: codex),
            polisher: WireSeat(choice: claude), refinementCap: 3, polishCap: 2,
            freshEyesAndDedup: true, defaultPlay: "nextMajor", customized: customized)
    }

    func testStagesRunInOrderWithEveryAgent() {
        let m = RoundInspectorModel.make(preset: "featurePlan", config: full())
        XCTAssertEqual(m.title, "Feature plan")
        XCTAssertEqual(m.stages.map(\.title), ["Draft", "Synthesis", "Refine", "Encode", "Polish"])
        XCTAssertEqual(m.stages[0].agents.map(\.role), ["Drafter", "Drafter"])
        XCTAssertEqual(m.stages[0].agents.map(\.persona), ["arbiter", "realist"])
        XCTAssertEqual(m.stages[0].agents[0].line, "Codex · gpt-6-sol · high")
        XCTAssertEqual(m.stages[0].agents[0].fallback, "Falls back to Claude · opus · high")
        XCTAssertEqual(m.stages[2].agents.map(\.role), ["Reviewer", "Cross-check agent", "Integrator"])
        XCTAssertNil(m.stages[2].agents[0].persona, "general says nothing")
    }

    /// Each agent row and its fallback carry the agent's id, and every agent the Mac can seat
    /// has an icon in this app's catalog; an id this build doesn't know draws none.
    func testEveryAgentHasAnIcon() {
        let m = RoundInspectorModel.make(preset: "featurePlan", config: full())
        XCTAssertEqual(m.stages[0].agents.map(\.agent), ["codex", "claude"])
        XCTAssertEqual(m.stages[0].agents.map(\.fallbackAgent), ["claude", "codex"])
        XCTAssertNil(m.stages[1].agents[0].fallbackAgent)
        for agent in ["claude", "codex", "grok", "gemini", "opencode"] {
            XCTAssertTrue(AgentIcon.known(agent), agent)
            XCTAssertNotNil(UIImage(named: "Agent\(agent == "opencode" ? "OpenCode" : agent.capitalized)"), agent)
        }
        XCTAssertFalse(AgentIcon.known("newagent"))
    }

    /// A rotating role reads as its agents in order, each with its icon; a role with one agent, or
    /// from a Mac that predates rotations, is unchanged.
    func testARotatingRoleListsItsAgentsInOrder() {
        let gemini = choice("gemini", "Gemini", "gemini-3.1-pro-high")
        var c = full()
        c.reviewers = [WireSeat(choice: codex, persona: "general", fallback: claude), WireSeat(choice: claude, persona: "general", fallback: codex)]
        c.integrators = [WireSeat(choice: claude), WireSeat(choice: codex)]
        c.polishers = [WireSeat(choice: claude), WireSeat(choice: gemini), WireSeat(choice: codex)]
        let m = RoundInspectorModel.make(preset: "fullPlan", config: c)
        let refine = m.stages[2].agents
        XCTAssertEqual(refine.map(\.role), ["Reviewer", "Cross-check agent", "Integrator"])
        XCTAssertEqual(refine[0].line, "Alternates: Codex → Claude")
        XCTAssertEqual(refine[0].rotation.map(\.agent), ["codex", "claude"])
        XCTAssertEqual(refine[2].line, "Alternates: Claude → Codex")
        let polish = m.stages[4].agents[0]
        XCTAssertEqual(polish.line, "Alternates: Claude → Gemini → Codex")
        XCTAssertEqual(polish.rotation.map(\.agent), ["claude", "gemini", "codex"])
        XCTAssertEqual(polish.rotation.map(\.line), ["Claude · opus · high", "Gemini · gemini-3.1-pro-high · high", "Codex · gpt-6-sol · high"])
        XCTAssertEqual(polish.agent, "claude", "the first agent")
        XCTAssertNil(polish.fallback)

        var one = full()
        one.integrators = [WireSeat(choice: claude)]
        let plain = RoundInspectorModel.make(preset: "fullPlan", config: one).stages[2].agents[2]
        XCTAssertEqual(plain.line, "Claude · opus · high")
        XCTAssertEqual(plain.rotation, [])
        XCTAssertEqual(RoundInspectorModel.make(preset: "fullPlan", config: full()).stages[2].agents[0].rotation, [])
    }

    func testCapsPolicyAndDefaultPlay() {
        let m = RoundInspectorModel.make(preset: "featurePlan", config: full())
        XCTAssertEqual(m.stages[2].facts, [.init(label: "Rounds", value: "3"), .init(label: "Cross-check", value: "First and last")])
        XCTAssertEqual(m.stages[4].facts, [.init(label: "Rounds", value: "2"), .init(label: "Fresh eyes + dedup", value: "On")])
        XCTAssertEqual(m.settings, [.init(label: "Default play", value: "Next major")])
    }

    func testASketchHasNoSynthesisOrPolishAndACustomizedConfigSaysSo() {
        var c = full(customized: true)
        c.synthesizer = nil; c.polisher = nil; c.crossReviewer = nil; c.crossCheck = "off"
        let m = RoundInspectorModel.make(preset: "sketch", config: c)
        XCTAssertEqual(m.title, "Sketch, customized")
        XCTAssertEqual(m.stages.map(\.title), ["Draft", "Refine", "Encode"])
        XCTAssertEqual(m.stages[1].agents.map(\.role), ["Reviewer", "Integrator"])
    }

    func testNoReviewerMeansNoRefineCapsAndAnUnknownWordShowsAsSent() {
        var c = full()
        c.reviewer = nil; c.crossCheck = "someNewPolicy"; c.defaultPlay = "someNewPlay"
        let m = RoundInspectorModel.make(preset: nil, config: c)
        XCTAssertEqual(m.title, "Rounds")
        XCTAssertEqual(m.stages.first { $0.id == "refine" }?.facts, [])
        XCTAssertEqual(m.settings.first?.value, "someNewPlay")
        XCTAssertEqual(RoundInspectorModel.crossCheckName("someNewPolicy"), "someNewPolicy")
    }

    func testAnAgentWithoutADisplayNameFallsBackToItsId() {
        XCTAssertEqual(RoundInspectorModel.describe(WireModelChoice(agent: "grok", model: "m", effort: "low")), "grok · m · low")
    }
}

final class FidelityChooserTests: XCTestCase {
    private func detail(state: String = "awaitingChoice", choose: Bool? = true, steer: Bool? = true,
                        presets: [WirePresetOption]? = nil) -> WireIntakeDetail {
        let seat = WireSeat(choice: WireModelChoice(agent: "codex", model: "m", effort: "high"))
        let config = WireRoundConfig(drafters: [seat, seat], reviewer: seat, integrator: seat, encoder: seat,
                                     polisher: seat, refinementCap: 3, polishCap: 2, freshEyesAndDedup: false,
                                     defaultPlay: "nextMajor", customized: false)
        return WireIntakeDetail(
            etag: "e", project: UUID(),
            summary: WireIntakeSummary(id: UUID(), title: "t", state: state, needsAttention: true, createdAt: Date()),
            intent: "i",
            choice: WireChoice(recommended: "featurePlan", reason: "r", presets: presets ?? [
                WirePresetOption(preset: "bead"), WirePresetOption(preset: "sketch", config: config),
                WirePresetOption(preset: "featurePlan", config: config), WirePresetOption(preset: "fullPlan", config: config)]),
            servedAt: Date(), steer: steer, choose: choose)
    }

    func testOffersTheFourFidelitiesWithTheRecommendationMarked() throws {
        let options = try XCTUnwrap(FidelityChooser.options(detail: detail()))
        XCTAssertEqual(options.map(\.name), ["Single task", "Sketch", "Feature plan", "Full plan"])
        XCTAssertEqual(options.map(\.recommended), [false, false, true, false])
        XCTAssertEqual(options[2].summary, "2 drafters · refine ×3 · polish ×2")
        XCTAssertFalse(options[0].hasRounds)
        XCTAssertTrue(options[1].hasRounds)
    }

    func testParkedOffersTheChoiceToo() {
        XCTAssertNotNil(FidelityChooser.options(detail: detail(state: "parked")))
    }

    func testAnOlderMacOffersNothing() {
        XCTAssertNil(FidelityChooser.options(detail: detail(choose: nil)))
        XCTAssertNil(FidelityChooser.options(detail: detail(steer: nil)))
        XCTAssertNil(FidelityChooser.options(detail: detail(presets: [])))
    }

    func testNothingIsOfferedOnceTheIntakeMovedOn() {
        XCTAssertNil(FidelityChooser.options(detail: detail(state: "shaping")))
    }

    func testConfirmationWarnsThatPlanningCostsMoney() throws {
        let options = try XCTUnwrap(FidelityChooser.options(detail: detail()))
        let plan = FidelityChooser.confirmation(for: options[3])
        XCTAssertEqual(plan.title, "Start with Full plan?")
        XCTAssertTrue(plan.message.contains("paid agent rounds"))
        let single = FidelityChooser.confirmation(for: options[0])
        XCTAssertEqual(single.title, "Start with Single task?")
        for text in [plan.title, plan.message, single.title, single.message] {
            XCTAssertNil(text.range(of: "bead", options: .caseInsensitive))
            XCTAssertNil(text.range(of: "seat", options: .caseInsensitive))
        }
    }
}
