import XCTest
import IntakeKit
@testable import FlightDeck

/// `AgentStackModel` decides which agents a round's avatar stack shows — in the main view's round
/// cards and live round header, and in the Rounds inspector's section headings — so a round on
/// screen and its config in the inspector can't be drawn from two different readings.
final class AgentStackModelTests: XCTestCase {
    private let codex = ModelChoice(agent: .codex, model: "gpt-6-sol", effort: "high")
    private let claude = ModelChoice(agent: .claude, model: "opus", effort: "high")
    private let grok = ModelChoice(agent: .grok, model: "grok-4.7", effort: "high")
    private let gemini = ModelChoice(agent: .gemini, model: "gemini-3.1-pro-high", effort: "high")
    private let opencode = ModelChoice(agent: .opencode, model: "big-pickle", effort: "")

    private var config: RoundConfig {
        RoundConfig(drafters: [Slot(codex, persona: .arbiter), Slot(claude, persona: .realist), Slot(codex, persona: .coverage)],
                    synthesizer: Slot(claude), reviewer: Slot(grok), integrator: claude,
                    encoder: codex, polisher: gemini, refinementCap: 3, polishCap: 2, freshEyesAndDedup: true,
                    defaultPlay: .nextMajor, customized: false,
                    crossReviewer: Slot(gemini), crossCheck: .firstAndLast)
    }

    /// A planned round's agents are the seats the engine will start for it, in run order — the
    /// same list the live card's seat rows are built from (`LiveSeats.expected`).
    func testPlannedRoundListsItsSeatsInRunOrder() {
        let draft = AgentStackModel.planned(stage: .draft, crossCheck: false, config: config)
        XCTAssertEqual(draft.map(\.role), ["drafter", "drafter", "drafter"])
        XCTAssertEqual(draft.map(\.choice.agent), [.codex, .claude, .codex])

        let refine = AgentStackModel.planned(stage: .refine, crossCheck: false, config: config)
        XCTAssertEqual(refine.map(\.role), ["reviewer", "integrator"])
        let crossed = AgentStackModel.planned(stage: .refine, crossCheck: true, config: config)
        XCTAssertEqual(crossed.map(\.role), ["reviewer", "crossReviewer", "integrator"])
        XCTAssertEqual(crossed.map(\.choice.agent), [.grok, .gemini, .claude])

        XCTAssertEqual(AgentStackModel.planned(stage: .synthesis, crossCheck: false, config: config).map(\.role),
                       ["synthesizer", "integrator"])
        XCTAssertEqual(AgentStackModel.planned(stage: .dedup, crossCheck: false, config: config).map(\.choice.agent), [.gemini])
    }

    /// A seat the config has no slot for (no polisher in Sketch) is left out, never drawn blank.
    func testAMissingSlotIsLeftOut() {
        var sketch = config
        sketch.polisher = nil
        XCTAssertEqual(AgentStackModel.planned(stage: .polish, crossCheck: false, config: sketch), [])
    }

    /// A finished round shows who actually ran — a fallback's model, not the one asked for.
    func testFinishedRoundShowsWhatRan() {
        let record = RoundRecord(slots: [
            SlotOutcome(role: "drafter", persona: .arbiter, used: codex, requested: codex, status: .ok),
            SlotOutcome(role: "drafter", persona: .realist, used: codex, requested: claude, status: .substituted),
        ])
        let ran = AgentStackModel.ran(record)
        XCTAssertEqual(ran.map(\.choice.agent), [.codex, .codex])
        XCTAssertEqual(AgentStackModel.agents(ran), [.codex], "distinct: one bubble per agent")
    }

    /// Distinct agents keep the order they first appear in, so the stack reads in run order and
    /// doesn't reshuffle between a round's card and its section heading.
    func testDistinctAgentsKeepFirstAppearanceOrder() {
        let entries = AgentStackModel.planned(stage: .draft, crossCheck: false, config: config)
        XCTAssertEqual(AgentStackModel.agents(entries), [.codex, .claude])
        XCTAssertEqual(AgentStackModel.agents([]), [])
    }

    /// Up to three bubbles; past three, the first three and a "+N" for the rest.
    func testOverflowPastThree() {
        let three: [AgentID] = [.codex, .claude, .grok]
        XCTAssertEqual(AgentStackModel.layout(three).shown, three)
        XCTAssertEqual(AgentStackModel.layout(three).overflow, 0)
        let five: [AgentID] = [.codex, .claude, .grok, .gemini, .opencode]
        XCTAssertEqual(AgentStackModel.layout(five).shown, [.codex, .claude, .grok])
        XCTAssertEqual(AgentStackModel.layout(five).overflow, 2)
        XCTAssertEqual(AgentStackModel.overflowText(2), "+2")
    }

    /// The tooltip names each role's agent and model, one line each, in the words the rest of the
    /// planning UI uses ("cross-check agent", never the engine's internal role name).
    func testHelpListsEveryRoleWithItsModel() {
        let crossed = AgentStackModel.planned(stage: .refine, crossCheck: true, config: config)
        XCTAssertEqual(AgentStackModel.help(crossed),
                       "Reviewer: Grok grok-4.7\nCross-check agent: Gemini gemini-3.1-pro-high\nIntegrator: Claude opus")
        XCTAssertEqual(AgentStackModel.accessibilityLabel(crossed), "Agents: Grok, Gemini, Claude")
    }

    /// Each stage lands in the Rounds inspector's section that configures it: polish, fresh eyes
    /// and dedup all run on the polisher.
    func testStagesMapToTheirInspectorSection() {
        XCTAssertEqual(RoundsSection.of(.draft), .draft)
        XCTAssertEqual(RoundsSection.of(.synthesis), .synthesis)
        XCTAssertEqual(RoundsSection.of(.refine), .refine)
        XCTAssertEqual(RoundsSection.of(.encode), .encode)
        for stage in [Stage.polish, .freshEyes, .dedup] { XCTAssertEqual(RoundsSection.of(stage), .polish) }
    }

    /// A section heading's stack is every agent its rounds can run — the refine section's
    /// includes the cross-check agent whenever the policy can seat one — so any round's stack in
    /// the main view is a subset of its section's in the inspector.
    func testSectionAgentsCoverEveryRoundOfTheSection() {
        XCTAssertEqual(AgentStackModel.section(.refine, config: config).map(\.role), ["reviewer", "crossReviewer", "integrator"])
        var off = config
        off.crossCheck = .off
        XCTAssertEqual(AgentStackModel.section(.refine, config: off).map(\.role), ["reviewer", "integrator"])
        XCTAssertEqual(AgentStackModel.section(.synthesis, config: config).map(\.role), ["synthesizer", "integrator"])
        XCTAssertEqual(AgentStackModel.section(.polish, config: config).map(\.choice.agent), [.gemini])
        for stage in Stage.allCases {
            for crossCheck in [false, true] {
                let round = Set(AgentStackModel.agents(AgentStackModel.planned(stage: stage, crossCheck: crossCheck, config: config)))
                let section = Set(AgentStackModel.agents(AgentStackModel.section(.of(stage), config: config)))
                XCTAssertTrue(round.isSubset(of: section), "\(stage) crossCheck=\(crossCheck)")
            }
        }
    }

    /// The editor's rows grouped under the sections the inspector scrolls to — every row once.
    func testEditorRowsGroupIntoSections() {
        let sections = RoundConfigEditor.sections(of: config)
        XCTAssertEqual(sections.map(\.section), [.draft, .synthesis, .refine, .encode, .polish])
        XCTAssertEqual(sections.flatMap(\.rows).map(\.keyPath), RoundConfigEditor.slots(of: config).map(\.keyPath))
        XCTAssertEqual(sections[2].rows.map(\.keyPath), [.reviewer, .crossReviewer, .integrator])

        var sketch = config
        sketch.synthesizer = nil
        sketch.polisher = nil
        XCTAssertEqual(RoundConfigEditor.sections(of: sketch).map(\.section), [.draft, .refine, .encode])
    }

    /// Every agent has its own provider icon in the app bundle, a vector that loads, and no two
    /// agents share one, so two agents in one stack are told apart.
    func testEveryAgentHasALoadableIcon() {
        let bundle = Bundle(for: SessionStore.self)
        for agent in AgentID.allCases {
            XCTAssertNotNil(bundle.image(forResource: agent.iconAsset), "\(agent)")
        }
        XCTAssertEqual(Set(AgentID.allCases.map(\.iconAsset)).count, AgentID.allCases.count)
    }
}
