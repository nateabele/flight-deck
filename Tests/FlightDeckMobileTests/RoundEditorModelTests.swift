import FleetKit
import XCTest
@testable import FlightDeckMobile

/// The Rounds editor's decisions (`RoundEditor`, `RoundEditing`), against a menu shaped like the
/// Mac's: Claude with a per-account model list and an Account choice, Codex, Gemini, and Grok
/// installed but signed out.
final class RoundEditorModelTests: XCTestCase {
    // MARK: Fixtures

    private let workKey = "account:11111111-1111-1111-1111-111111111111"
    private let poolKey = "pool:team"

    private var menu: WireRoundsMenu {
        let claudeModels = [WireModelOption(id: "opus", name: "Opus 5.5", efforts: ["low", "medium", "high"]),
                            WireModelOption(id: "haiku", name: "Haiku 4.5", efforts: [])]
        let codexModels = [WireModelOption(id: "gpt-6-sol", name: "GPT 6 Sol", efforts: ["medium", "high", "xhigh"]),
                           WireModelOption(id: "gpt-6-mini", name: "GPT 6 Mini", efforts: ["medium", "high"])]
        let geminiModels = [WireModelOption(id: "gemini-3.1-pro-high", name: "Gemini 3.1 Pro (High)", efforts: [])]
        func start(_ agent: String, _ name: String, _ model: WireModelOption, _ effort: String) -> WireModelChoice {
            WireModelChoice(agent: agent, agentName: name, model: model.id, effort: effort, modelName: model.name)
        }
        return WireRoundsMenu(agents: [
            WireAgentOption(
                agent: "claude", name: "Claude", models: claudeModels,
                accountModels: [workKey: [WireModelOption(id: "opus", name: "Opus 5.5", efforts: ["high"])]],
                efforts: ["low", "medium", "high"], planningEffort: "high",
                defaultChoice: start("claude", "Claude", claudeModels[0], "high"),
                accounts: WireAccountMenu(defaultTitle: "Project default — Personal", offersChoice: true, options: [
                    WireAccountOption(key: workKey, title: "Work"),
                    WireAccountOption(key: poolKey, title: "Team pool", isPool: true)])),
            WireAgentOption(
                agent: "codex", name: "Codex", models: codexModels, efforts: ["medium", "high", "xhigh"], planningEffort: "high",
                defaultChoice: start("codex", "Codex", codexModels[0], "high"),
                accounts: WireAccountMenu(defaultTitle: "Project default — Personal", offersChoice: false)),
            WireAgentOption(
                agent: "gemini", name: "Gemini", models: geminiModels, efforts: [], planningEffort: "",
                defaultChoice: start("gemini", "Gemini", geminiModels[0], "")),
            WireAgentOption(agent: "grok", name: "Grok", reason: "Grok: run `grok login`"),
        ])
    }

    private func choice(_ agent: String, _ name: String, _ model: String, _ modelName: String, _ effort: String = "high",
                        accountKey: String? = nil, account: String? = nil) -> WireModelChoice {
        WireModelChoice(agent: agent, agentName: name, model: model, effort: effort, modelName: modelName,
                        account: account, accountKey: accountKey)
    }

    private var claude: WireModelChoice { choice("claude", "Claude", "opus", "Opus 5.5") }
    private var codex: WireModelChoice { choice("codex", "Codex", "gpt-6-sol", "GPT 6 Sol") }

    private var config: WireRoundConfig {
        WireRoundConfig(
            drafters: [WireSeat(choice: codex, persona: "arbiter", fallback: claude),
                       WireSeat(choice: claude, persona: "realist", fallback: codex)],
            synthesizer: WireSeat(choice: codex, persona: "arbiter", fallback: claude),
            reviewer: WireSeat(choice: codex, persona: "general", fallback: claude),
            integrator: WireSeat(choice: claude), encoder: WireSeat(choice: codex),
            polisher: WireSeat(choice: claude), refinementCap: 3, polishCap: 2,
            freshEyesAndDedup: false, defaultPlay: "nextMajor", customized: false)
    }

    private func editor(_ config: WireRoundConfig? = nil, lock: WireRoundsLock? = nil, menu: WireRoundsMenu? = nil) -> RoundEditor {
        RoundEditor(config: config ?? self.config, menu: menu ?? self.menu, lock: lock)
    }

    private func entry(_ e: RoundEditor, _ site: RoundSite) throws -> RoundEditor.Entry {
        for stage in e.stages {
            for role in stage.roles {
                for turn in role.turns {
                    if turn.entry.site == site { return turn.entry }
                    if let fallback = turn.fallback, fallback.site == site { return fallback }
                }
            }
        }
        throw XCTSkip("no entry for \(site)")
    }

    // MARK: Layout

    func testStagesRunInOrderWithTheRolesTheMacEdits() {
        let e = editor()
        XCTAssertEqual(e.stages.map(\.title), ["Draft", "Synthesis", "Refine", "Encode", "Polish"])
        XCTAssertEqual(e.stages[0].roles.map(\.title), ["Drafter", "Drafter"])
        XCTAssertEqual(e.stages[0].roles.map(\.persona), ["arbiter", "realist"])
        XCTAssertEqual(e.stages[2].roles.map(\.title), ["Reviewer", "Integrator"], "no cross-check agent while the policy is off")
        XCTAssertNil(e.stages[2].roles[0].persona, "general says nothing")
    }

    func testTheCrossCheckAgentShowsOnlyWhileThePolicyIsOn() {
        var c = config
        c.crossReviewer = WireSeat(choice: choice("gemini", "Gemini", "gemini-3.1-pro-high", "Gemini 3.1 Pro (High)", ""))
        XCTAssertEqual(editor(c).stages[2].roles.map(\.title), ["Reviewer", "Integrator"])
        c.crossCheck = "firstAndLast"
        XCTAssertEqual(editor(c).stages[2].roles.map(\.title), ["Reviewer", "Cross-check agent", "Integrator"])
        XCTAssertNil(editor(c).stages[2].roles[1].turns[0].fallback, "never a fallback: it would be the reviewer's family")
    }

    func testOnlyAllowedRolesOfferAFallback() {
        let e = editor()
        XCTAssertNotNil(e.stages[0].roles[0].turns[0].fallback)
        XCTAssertNotNil(e.stages[2].roles[0].turns[0].fallback, "reviewer")
        XCTAssertNil(e.stages[2].roles[1].turns[0].fallback, "integrator")
        XCTAssertNil(e.stages[3].roles[0].turns[0].fallback, "encoder")
        XCTAssertNil(e.stages[4].roles[0].turns[0].fallback, "polisher")
    }

    func testASketchHasNoPolishOrSynthesis() {
        var c = config
        c.synthesizer = nil; c.polisher = nil; c.drafters.removeLast()
        XCTAssertEqual(editor(c).stages.map(\.title), ["Draft", "Refine", "Encode"])
    }

    // MARK: The model menu

    func testTheClosedMenuReadsAgentThenModel() throws {
        let e = editor()
        XCTAssertEqual(try entry(e, RoundSite(role: .drafter(0))).modelLabel, "Codex > GPT 6 Sol")
        XCTAssertEqual(try entry(e, RoundSite(role: .drafter(0), fallback: true)).modelLabel, "Claude > Opus 5.5")
    }

    func testAModelNameThatStartsWithItsAgentSaysItOnce() {
        let e = editor()
        XCTAssertEqual(e.modelLabel(choice("gemini", "Gemini", "gemini-3.1-pro-high", "Gemini 3.1 Pro (High)", "")), "Gemini > 3.1 Pro (High)")
    }

    func testAModelTheListDoesNotHoldReadsCustomAndIsKeptInTheMenu() throws {
        var c = config
        c.encoder = WireSeat(choice: choice("codex", "Codex", "gpt-6-experimental", "gpt-6-experimental"))
        let e = editor(c)
        let site = RoundSite(role: .encoder)
        XCTAssertEqual(try entry(e, site).modelLabel, "Codex > gpt-6-experimental (custom)")
        let codexMenu = try XCTUnwrap(e.modelMenu(for: site).first { $0.agent == "codex" })
        XCTAssertEqual(codexMenu.custom?.model, "gpt-6-experimental")
        XCTAssertEqual(codexMenu.models.map(\.checked), [false, false])
    }

    func testTheMenuListsEveryAgentTheCurrentModelChecked() throws {
        let menu = editor().modelMenu(for: RoundSite(role: .drafter(0)))
        XCTAssertEqual(menu.map(\.name), ["Claude", "Codex", "Gemini", "Grok"])
        XCTAssertEqual(menu.first { $0.agent == "codex" }?.models.map(\.checked), [true, false])
        XCTAssertEqual(menu.first { $0.agent == "claude" }?.models.map(\.checked), [false, false])
    }

    func testAnAgentThatCannotBePickedStaysInTheMenuWithItsReason() throws {
        let grok = try XCTUnwrap(editor().modelMenu(for: RoundSite(role: .encoder)).first { $0.agent == "grok" })
        XCTAssertEqual(grok.reason, "Grok: run `grok login`")
        XCTAssertEqual(grok.models, [])
    }

    func testARolesOwnAgentSurvivesDetectionNoLongerOfferingIt() {
        var c = config
        c.encoder = WireSeat(choice: choice("opencode", "OpenCode", "sonnet", "Sonnet"))
        let opencode = editor(c).modelMenu(for: RoundSite(role: .encoder)).last
        XCTAssertEqual(opencode?.agent, "opencode")
        XCTAssertEqual(opencode?.reason, "OpenCode (unavailable)")
    }

    func testPickingAModelWritesAgentAndModelAndNamesThem() throws {
        var e = editor()
        e.select(RoundSite(role: .encoder), agent: "claude", model: "haiku")
        XCTAssertEqual(e.config.encoder.choice.agent, "claude")
        XCTAssertEqual(e.config.encoder.choice.model, "haiku")
        XCTAssertEqual(e.config.encoder.choice.agentName, "Claude")
        XCTAssertEqual(e.config.encoder.choice.modelName, "Haiku 4.5")
        XCTAssertTrue(e.config.customized)
        XCTAssertEqual(try entry(e, RoundSite(role: .encoder)).modelLabel, "Claude > Haiku 4.5")
    }

    func testAModelTypedInIsAcceptedAsItIs() {
        var e = editor()
        e.select(RoundSite(role: .encoder), agent: "codex", model: "gpt-7-preview")
        XCTAssertEqual(e.config.encoder.choice.model, "gpt-7-preview")
        XCTAssertEqual(e.config.encoder.choice.effort, "high", "a model with no list takes the agent's levels, and high still fits")
    }

    // MARK: Effort

    func testEffortIsHiddenWhereTheModelHasNoLevels() throws {
        var e = editor()
        XCTAssertEqual(try entry(e, RoundSite(role: .encoder)).efforts, ["medium", "high", "xhigh"])
        e.select(RoundSite(role: .encoder), agent: "claude", model: "haiku")
        XCTAssertEqual(try entry(e, RoundSite(role: .encoder)).efforts, [])
        XCTAssertEqual(e.config.encoder.choice.effort, "", "an empty effort follows a model that takes none")
        e.select(RoundSite(role: .encoder), agent: "gemini", model: "gemini-3.1-pro-high")
        XCTAssertEqual(try entry(e, RoundSite(role: .encoder)).efforts, [], "gemini's ids carry theirs")
    }

    func testEffortFollowsTheNewModelKeepingWhatStillFits() {
        var e = editor()
        e.setEffort(RoundSite(role: .encoder), "xhigh")
        e.select(RoundSite(role: .encoder), agent: "codex", model: "gpt-6-mini")
        XCTAssertEqual(e.config.encoder.choice.effort, "high", "xhigh is not one of the mini's levels: the planning effort")
        e.setEffort(RoundSite(role: .encoder), "medium")
        e.select(RoundSite(role: .encoder), agent: "codex", model: "gpt-6-sol")
        XCTAssertEqual(e.config.encoder.choice.effort, "medium", "kept: the same agent, and the level fits")
        e.select(RoundSite(role: .encoder), agent: "claude", model: "opus")
        XCTAssertEqual(e.config.encoder.choice.effort, "high", "a different agent starts at its planning effort")
    }

    func testAStoredEffortTheModelNoLongerListsStaysInThePicker() throws {
        var c = config
        c.encoder = WireSeat(choice: choice("codex", "Codex", "gpt-6-sol", "GPT 6 Sol", "max"))
        XCTAssertEqual(try entry(editor(c), RoundSite(role: .encoder)).efforts, ["medium", "high", "xhigh", "max"])
    }

    func testSettingEffortWritesIt() {
        var e = editor()
        e.setEffort(RoundSite(role: .drafter(1)), "low")
        XCTAssertEqual(e.config.drafters[1].choice.effort, "low")
        e.setEffort(RoundSite(role: .drafter(1), fallback: true), "medium")
        XCTAssertEqual(e.config.drafters[1].fallback?.effort, "medium")
    }

    // MARK: Accounts

    func testTheAccountPickerShowsOnlyWhereThereIsAChoice() throws {
        let e = editor()
        let claudeRow = try XCTUnwrap(try entry(e, RoundSite(role: .drafter(1))).account)
        XCTAssertEqual(claudeRow.items.map(\.title), ["Project default — Personal", "Work"])
        XCTAssertEqual(claudeRow.pools.map(\.title), ["Team pool"])
        XCTAssertNil(claudeRow.selection)
        XCTAssertNil(try entry(e, RoundSite(role: .drafter(0))).account, "codex has one account: nothing to pick")
    }

    func testARoleHoldingItsOwnAccountKeepsThePickerSoItCanBePutBack() throws {
        var c = config
        var codexOwn = codex
        codexOwn.accountKey = workKey
        c.encoder = WireSeat(choice: codexOwn)
        let picker = try XCTUnwrap(try entry(editor(c), RoundSite(role: .encoder)).account)
        XCTAssertEqual(picker.selection, workKey)
        XCTAssertEqual(picker.missing?.title, "Missing account", "codex's menu does not hold it")
        var e = editor(c)
        e.setAccount(RoundSite(role: .encoder), key: nil)
        XCTAssertNil(e.config.encoder.choice.accountKey)
        XCTAssertNil(try entry(e, RoundSite(role: .encoder)).account)
    }

    func testPickingAnAccountWritesItsKeyAndName() {
        var e = editor()
        e.setAccount(RoundSite(role: .integrator), key: poolKey)
        XCTAssertEqual(e.config.integrator.choice.accountKey, poolKey)
        XCTAssertEqual(e.config.integrator.choice.account, "Team pool")
    }

    func testAnAccountBelongsToOneAgent() {
        var e = editor()
        e.setAccount(RoundSite(role: .integrator), key: workKey)
        e.select(RoundSite(role: .integrator), agent: "claude", model: "haiku")
        XCTAssertEqual(e.config.integrator.choice.accountKey, workKey, "the same agent keeps it")
        e.select(RoundSite(role: .integrator), agent: "codex", model: "gpt-6-sol")
        XCTAssertNil(e.config.integrator.choice.accountKey)
        XCTAssertNil(e.config.integrator.choice.account)
    }

    func testAnAccountsOwnModelListIsUsed() throws {
        var e = editor()
        e.setAccount(RoundSite(role: .integrator), key: workKey)
        XCTAssertEqual(e.models(agent: "claude", accountKey: workKey).map(\.id), ["opus"], "the work account sees one model")
        XCTAssertEqual(try entry(e, RoundSite(role: .integrator)).efforts, ["high"])
        XCTAssertEqual(e.models(agent: "claude", accountKey: nil).map(\.id), ["opus", "haiku"])
    }

    // MARK: Fallback

    func testFallbackNoneClearsItAndAnAgentSetsIt() {
        var e = editor()
        e.clearFallback(RoundSite(role: .drafter(0)))
        XCTAssertNil(e.config.drafters[0].fallback)
        e.select(RoundSite(role: .drafter(0), fallback: true), agent: "gemini", model: "gemini-3.1-pro-high")
        XCTAssertEqual(e.config.drafters[0].fallback?.agent, "gemini")
        XCTAssertEqual(e.config.drafters[0].choice.agent, "codex", "the role's own agent is untouched")
    }

    func testAFallbackWithNoneReadsNone() throws {
        var e = editor()
        e.clearFallback(RoundSite(role: .drafter(0)))
        let fallback = try entry(e, RoundSite(role: .drafter(0), fallback: true))
        XCTAssertEqual(fallback.modelLabel, "None")
        XCTAssertEqual(fallback.efforts, [])
    }

    // MARK: Rotations

    func testAddingToARotationMakesThePairThenWalksTheFamilies() {
        var e = editor()
        XCTAssertTrue(e.canAddToRotation(.integrator))
        e.addToRotation(.integrator)
        XCTAssertEqual(e.config.integrators?.map(\.choice.agent), ["claude", "codex"])
        e.addToRotation(.integrator)
        XCTAssertEqual(e.config.integrators?.map(\.choice.agent), ["claude", "codex", "gemini"])
        e.addToRotation(.integrator)
        XCTAssertEqual(e.config.integrators?.map(\.choice.agent), ["claude", "codex", "gemini", "claude"], "grok cannot be picked: it wraps")
        XCTAssertEqual(e.config.integrator.choice.agent, "claude", "the single field stays entry 0")
    }

    func testARotationShowsTurnsAndAnAddedReviewerGetsAPersona() throws {
        var e = editor()
        e.addToRotation(.reviewer)
        let reviewer = try XCTUnwrap(e.stages[2].roles.first { $0.role == .reviewer })
        XCTAssertEqual(reviewer.turns.map(\.entry.label), ["Turn 1", "Turn 2"])
        XCTAssertEqual(e.config.reviewers?[1].persona, "general")
        XCTAssertEqual(e.config.reviewers?.map(\.choice.agent), ["codex", "gemini"], "the next family after codex in the menu's order")
        XCTAssertEqual(e.config.reviewer?.choice.agent, "codex")
    }

    func testReorderingARotationMovesTheSingleFieldWithEntryZero() {
        var e = editor()
        e.addToRotation(.polisher)
        XCTAssertEqual(e.config.polishers?.map(\.choice.agent), ["claude", "codex"])
        e.moveInRotation(.polisher, from: 1, to: 0)
        XCTAssertEqual(e.config.polishers?.map(\.choice.agent), ["codex", "claude"])
        XCTAssertEqual(e.config.polisher?.choice.agent, "codex")
        e.moveInRotation(.polisher, from: 0, to: 5)
        XCTAssertEqual(e.config.polishers?.map(\.choice.agent), ["codex", "claude"], "out of range does nothing")
    }

    func testRemovingDownToOneIsNoRotation() {
        var e = editor()
        e.addToRotation(.integrator)
        e.removeFromRotation(.integrator, at: 0)
        XCTAssertNil(e.config.integrators)
        XCTAssertEqual(e.config.integrator.choice.agent, "codex")
        e.removeFromRotation(.integrator, at: 0)
        XCTAssertEqual(e.config.integrator.choice.agent, "codex", "the last agent cannot be taken out")
    }

    func testUseOneAgentCollapsesToTheFirst() {
        var e = editor()
        e.addToRotation(.integrator)
        e.addToRotation(.integrator)
        e.collapseRotation(.integrator)
        XCTAssertNil(e.config.integrators)
        XCTAssertEqual(e.config.integrator.choice.agent, "claude")
    }

    func testEditingATurnEditsThatTurnOnly() {
        var e = editor()
        e.addToRotation(.integrator)
        e.select(RoundSite(role: .integrator, turn: 1), agent: "gemini", model: "gemini-3.1-pro-high")
        XCTAssertEqual(e.config.integrators?.map(\.choice.agent), ["claude", "gemini"])
        XCTAssertEqual(e.config.integrator.choice.agent, "claude")
        e.select(RoundSite(role: .integrator, turn: 0), agent: "codex", model: "gpt-6-sol")
        XCTAssertEqual(e.config.integrator.choice.agent, "codex", "entry 0 is the single field")
    }

    func testAReviewerTurnKeepsItsOwnFallback() {
        var e = editor()
        e.addToRotation(.reviewer)
        e.select(RoundSite(role: .reviewer, turn: 1, fallback: true), agent: "gemini", model: "gemini-3.1-pro-high")
        XCTAssertEqual(e.config.reviewers?[1].fallback?.agent, "gemini")
        XCTAssertEqual(e.config.reviewers?[0].fallback?.agent, "claude")
        e.clearFallback(RoundSite(role: .reviewer, turn: 0))
        XCTAssertNil(e.config.reviewer?.fallback, "the single field follows entry 0")
    }

    func testOneUsableAgentCannotRotate() {
        var m = menu
        m.agents = m.agents.filter { $0.agent == "codex" }
        XCTAssertFalse(editor(menu: m).canAddToRotation(.integrator))
        var e = editor(menu: m)
        e.addToRotation(.integrator)
        XCTAssertNil(e.config.integrators)
    }

    // MARK: Cross-check

    func testTurningCrossCheckOnSeedsAnotherFamily() {
        var e = editor()
        e.setCrossCheck("firstAndLast")
        XCTAssertEqual(e.config.crossCheck, "firstAndLast")
        XCTAssertEqual(e.config.crossReviewer?.choice.agent, "claude", "the first family that is not the reviewer's")
        XCTAssertFalse(e.crossCheckSameFamily)
        XCTAssertEqual(e.stages[2].roles.map(\.title), ["Reviewer", "Cross-check agent", "Integrator"])
    }

    func testCrossCheckOnOneFamilyOnlySaysSo() {
        var m = menu
        m.agents = m.agents.filter { $0.agent == "codex" }
        var e = editor(menu: m)
        e.setCrossCheck("every")
        XCTAssertNil(e.config.crossReviewer)
        XCTAssertTrue(e.crossCheckUnavailable)
    }

    func testASameFamilyCrossCheckSaysItWillNotCrossCheck() {
        var e = editor()
        e.setCrossCheck("every")
        e.select(RoundSite(role: .crossReviewer), agent: "codex", model: "gpt-6-sol")
        XCTAssertTrue(e.crossCheckSameFamily)
        e.setCrossCheck("off")
        XCTAssertEqual(e.crossCheck, "off")
        XCTAssertEqual(e.stages[2].roles.map(\.title), ["Reviewer", "Integrator"])
    }

    // MARK: Rounds, fresh eyes, default play

    func testRoundCountsAreTheCapsBeforeShaping() {
        var e = editor()
        XCTAssertEqual(e.refineRounds, 3)
        e.setRefineRounds(5); e.setPolishRounds(0)
        XCTAssertEqual(e.config.refinementCap, 5)
        XCTAssertEqual(e.config.polishCap, 0)
        XCTAssertEqual(e.refineRange, 0...12)
    }

    func testWhileShapingRoundsAreCapPlusTheTapesCounterAndSaveTheCapThatGivesIt() {
        let lock = WireRoundsLock(editable: true, extraRefinement: 1, extraPolish: 0, refinementFloor: 2, polishFloor: 0)
        var e = editor(lock: lock)
        XCTAssertEqual(e.refineRounds, 4, "cap 3 and one + pressed")
        e.setRefineRounds(6)
        XCTAssertEqual(e.config.refinementCap, 5, "the counter is not counted twice")
        e.setRefineRounds(1)
        XCTAssertEqual(e.config.refinementCap, 1, "never below the rounds already run (2), less the counter")
        XCTAssertEqual(e.refineRange.lowerBound, 2)
    }

    func testFreshEyesReadsOffWithNoPolisher() {
        var c = config
        c.freshEyesAndDedup = true
        XCTAssertTrue(editor(c).freshEyes)
        c.polisher = nil
        XCTAssertFalse(editor(c).freshEyes)
        var e = editor()
        e.setFreshEyes(true)
        XCTAssertTrue(e.config.freshEyesAndDedup)
    }

    func testDefaultPlayIsSet() {
        var e = editor()
        e.setDefaultPlay("toReview")
        XCTAssertEqual(e.config.defaultPlay, "toReview")
        XCTAssertTrue(e.config.customized)
    }

    // MARK: Locks

    func testARoleThatAlreadyRanIsLockedAndSaysSo() {
        let lock = WireRoundsLock(editable: true, locked: ["drafter0", "drafter1", "synthesizer"], refineDone: false)
        let e = editor(lock: lock)
        XCTAssertEqual(e.stages[0].roles.map(\.ran), [true, true])
        XCTAssertEqual(e.stages[1].roles.map(\.ran), [true])
        XCTAssertEqual(e.stages[2].roles.map(\.ran), [false, false])
        XCTAssertEqual(RoundEditor.alreadyRan, "already ran", "the Mac's wording")
        XCTAssertTrue(e.isLocked(.drafter(1)))
        XCTAssertFalse(e.isLocked(.reviewer))
    }

    func testFinishedStagesLockTheirCapsAndFreshEyes() {
        let lock = WireRoundsLock(editable: true, locked: ["reviewer", "integrator"], refineDone: true, polishDone: false, freshEyesDone: true)
        let e = editor(lock: lock)
        XCTAssertTrue(e.refineLocked)
        XCTAssertFalse(e.polishLocked)
        XCTAssertTrue(e.freshEyesLocked)
    }

    func testNothingIsEditableWhileARoundRuns() {
        let lock = WireRoundsLock(editable: false, reason: "Pause to change agents.")
        let e = editor(lock: lock)
        XCTAssertFalse(e.editable)
        XCTAssertEqual(e.lock?.reason, "Pause to change agents.")
        XCTAssertTrue(editor().editable, "choosing a fidelity has no lock")
    }

    // MARK: Whether the inspector edits

    private func detail(state: String = "awaitingChoice", editRounds: Bool? = true, menu: WireRoundsMenu? = nil,
                        lock: WireRoundsLock? = nil, preset: String = "featurePlan") -> WireIntakeDetail {
        let shaping = state == "shaping"
        return WireIntakeDetail(
            etag: "e", project: UUID(),
            summary: WireIntakeSummary(id: UUID(), title: "t", state: state, needsAttention: false, createdAt: Date()),
            intent: "i",
            choice: shaping ? nil : WireChoice(recommended: preset, presets: [
                WirePresetOption(preset: "bead"), WirePresetOption(preset: preset, config: config)]),
            servedAt: Date(), steer: true, choose: true, roundConfig: shaping ? config : nil,
            editRounds: editRounds, roundsMenu: menu ?? self.menu, roundsLock: lock)
    }

    func testAChoosingFidelityIsEditable() throws {
        let editing = try XCTUnwrap(RoundEditing.make(detail: detail(), preset: "featurePlan", drafts: [:]))
        XCTAssertEqual(editing.editor.config, config)
        XCTAssertNil(editing.editor.lock)
        XCTAssertFalse(editing.dirty)
        XCTAssertEqual(editing.key, "featurePlan")
    }

    func testAShapingIntakeIsEditableOnlyWithWhatHasRun() throws {
        XCTAssertNil(RoundEditing.make(detail: detail(state: "shaping"), preset: nil, drafts: [:]), "no lock: the Mac did not say")
        let editing = try XCTUnwrap(RoundEditing.make(detail: detail(state: "shaping", lock: WireRoundsLock(editable: true)), preset: nil, drafts: [:]))
        XCTAssertEqual(editing.key, "shaping")
        XCTAssertNotNil(editing.editor.lock)
    }

    func testAnOlderMacLeavesTheInspectorReadOnly() {
        XCTAssertNil(RoundEditing.make(detail: detail(editRounds: nil), preset: "featurePlan", drafts: [:]))
        XCTAssertNil(RoundEditing.make(detail: detail(editRounds: false), preset: "featurePlan", drafts: [:]))
        var noMenu = detail()
        noMenu.roundsMenu = nil
        XCTAssertNil(RoundEditing.make(detail: noMenu, preset: "featurePlan", drafts: [:]))
        var noSteer = detail()
        noSteer.steer = nil
        XCTAssertNil(RoundEditing.make(detail: noSteer, preset: "featurePlan", drafts: [:]))
    }

    func testNothingEditsOnceTheIntakeMovedOn() {
        XCTAssertNil(RoundEditing.make(detail: detail(state: "review", lock: WireRoundsLock(editable: true)), preset: nil, drafts: [:]))
        XCTAssertNil(RoundEditing.make(detail: detail(state: "shaping"), preset: "featurePlan", drafts: [:]), "a fidelity is not chosen from a shaping intake")
        XCTAssertNil(RoundEditing.make(detail: detail(), preset: "fullPlan", drafts: [:]), "a fidelity the Mac sent no config for")
    }

    func testADraftOverlaysTheMacsConfigAndKnowsWhatItWasMadeFrom() throws {
        var edited = config
        edited.refinementCap = 5
        let editing = try XCTUnwrap(RoundEditing.make(
            detail: detail(), preset: "featurePlan", drafts: ["featurePlan": RoundDraft(base: config, config: edited)]))
        XCTAssertEqual(editing.editor.config.refinementCap, 5)
        XCTAssertTrue(editing.dirty)
        XCTAssertFalse(editing.stale)
        var moved = config
        moved.polishCap = 9
        let stale = try XCTUnwrap(RoundEditing.make(
            detail: detail(), preset: "featurePlan", drafts: ["featurePlan": RoundDraft(base: moved, config: edited)]))
        XCTAssertTrue(stale.stale, "the Mac's config is no longer what the edit began from")
    }

    func testAnEditTakenBackIsNoEdit() {
        var e = editor()
        e.setRefineRounds(5)
        XCTAssertTrue(RoundEditing.differs(RoundDraft(base: config, config: e.config)))
        e.setRefineRounds(3)
        XCTAssertFalse(RoundEditing.differs(RoundDraft(base: config, config: e.config)), "customized alone is not a change")
    }

    func testAnEditedFidelityIsMarkedAndSummarisedAsEdited() throws {
        var edited = config
        edited.refinementCap = 5
        var d = detail()
        d.choose = true
        d.choice?.presets?.append(WirePresetOption(preset: "fullPlan", config: config))
        let drafts = ["featurePlan": RoundDraft(base: config, config: edited)]
        let options = try XCTUnwrap(FidelityChooser.options(detail: d, drafts: drafts))
        let plan = try XCTUnwrap(options.first { $0.preset == "featurePlan" })
        XCTAssertTrue(plan.edited)
        XCTAssertEqual(plan.summary, "2 drafters · refine ×5 · polish ×2")
        XCTAssertEqual(options.filter(\.edited).count, 1)
        let untouched = ["featurePlan": RoundDraft(base: config, config: config)]
        XCTAssertFalse(try XCTUnwrap(FidelityChooser.options(detail: d, drafts: untouched)).contains { $0.edited })
    }

    // MARK: Words

    func testRefusalsComeBackAsPlainSentences() {
        XCTAssertEqual(CommandCopy.message(for: .server(code: "rounds_changed")), "The plan changed — reopen it and try again.")
        XCTAssertEqual(CommandCopy.message(for: .server(code: "invalid_config")), "Your Mac couldn't use those settings.")
        XCTAssertEqual(CommandCopy.message(for: .server(code: RoundsRefusal.prefix + "The reviewer already ran, so it can't change.")),
                       "The reviewer already ran, so it can't change.")
        XCTAssertEqual(CommandCopy.message(for: .server(code: RoundsRefusal.prefix + "Pause to change agents.")), "Pause to change agents.")
    }

    func testNoWordTheMacDoesNotUse() {
        let words = [RoundEditor.alreadyRan, RoundEditor.alternates, RoundEditor.synthesisIntegratorNote]
        for word in words {
            for banned in ["bead", "seat", "harness"] { XCTAssertNil(word.range(of: banned, options: .caseInsensitive)) }
        }
        let e = editor()
        for stage in e.stages {
            for role in stage.roles {
                for banned in ["bead", "seat", "harness"] { XCTAssertNil(role.title.range(of: banned, options: .caseInsensitive)) }
            }
        }
    }
}
