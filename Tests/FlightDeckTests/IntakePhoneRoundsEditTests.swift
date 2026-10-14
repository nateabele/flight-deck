import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

@MainActor
private final class FakeRunnerController: IntakeRunnerControlling {
    var running: Set<UUID> = []
    var socketDirectory: URL = FileManager.default.temporaryDirectory
    func ensureRunning(_ id: UUID) -> Result<Void, RunnerStartError> { .success(()) }
    func isRunning(_ id: UUID, tape: Tape?) -> Bool { running.contains(id) }
    func reap(_ id: UUID) {}
    func socketPath(for id: UUID) -> String {
        socketDirectory.appendingPathComponent("intake-\(id.uuidString.lowercased()).sock").path
    }
}

private final class SilentProcessRunner: FlywheelProcessRunner, @unchecked Sendable {
    func run(_ exe: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) { ("", 127) }
}

private final class InertHeadlessRunner: HeadlessRunner, @unchecked Sendable {
    func run(_ command: (executable: String, arguments: [String], unsetEnvironment: [String]),
             cwd: URL) async throws -> (stdout: Data, stderr: String, exitCode: Int32) {
        (Data(), "", 1)
    }
}

/// The phone's Rounds edits as the Mac applies them: an edited fidelity starts exactly as the
/// Mac's own Start does, a shaping edit goes through the Mac editor's save (so a stage that already
/// ran, or a round in flight, refuses it with the Mac's own sentence), and an edit made from a
/// config the Mac has since changed is refused rather than laid over it.
@MainActor
final class IntakePhoneRoundsEditTests: XCTestCase {
    private var root: URL!
    private var runner: FakeRunnerController!
    private var clockNow = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntakePhoneRoundsEditTests-\(UUID())", isDirectory: true)
        runner = FakeRunnerController()
        runner.socketDirectory = root
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: fixtures

    private func makeService(available: AvailableModels = .defaults) async -> IntakeService {
        let svc = IntakeService(store: IntakeStore(root: root), headless: InertHeadlessRunner(),
                                processRunner: SilentProcessRunner(),
                                triageSettings: TriageSettings(agent: .codex, model: "m1", effort: "high"),
                                availableModels: available, runner: runner,
                                inject: { _, _, _, _ in true }, hasSession: { _, _ in false },
                                now: { [unowned self] in self.clockNow },
                                readFile: { try? Data(contentsOf: $0) },
                                announce: { _ in })
        await svc.launchRecovery?.value
        for i in svc.intakes { await svc.convergenceFold(for: i.id)?.value }
        svc.pollTapes()
        return svc
    }

    private func seedChoice(_ state: IntakeState = .awaitingChoice) throws -> Intake {
        var i = Intake(projectPath: "/p", intent: "Plan the thing")
        i.state = state
        i.recommended = .featurePlan
        try IntakeStore(root: root).save(i)
        return i
    }

    /// Shaping, on the Full plan preset; `status` is the tape's.
    private func seedShaping(_ status: RunnerStatus = .paused, checkpoints: [Checkpoint] = []) throws -> Intake {
        var i = Intake(projectPath: "/p", intent: "Plan the thing")
        i.state = .shaping
        i.recommended = .fullPlan
        i.chosenPreset = .fullPlan
        i.roundConfig = PresetExpansion.config(for: .fullPlan, available: .defaults)
        try IntakeStore(root: root).save(i)
        let store = TapeStore(intakeDirectory: IntakeStore(root: root).directory(for: i.id))
        var tape = store.loadTape()
        tape.status = status
        tape.checkpoints = checkpoints
        try store.saveTape(tape)
        return i
    }

    private func checkpoint(_ id: Int, _ stage: Stage, round: Int = 0) -> Checkpoint {
        Checkpoint(id: id, stage: stage, round: round, major: true, createdAt: clockNow)
    }

    private func stock(_ preset: Preset) throws -> RoundConfig {
        try XCTUnwrap(PresetExpansion.config(for: preset, available: .defaults))
    }

    private func wire(_ config: RoundConfig) -> WireRoundConfig { IntakeDetailProjection.wireConfig(config) }

    private func edited(_ config: RoundConfig, _ change: (inout RoundConfig) -> Void) -> WireRoundConfig {
        var c = config
        change(&c)
        return wire(c)
    }

    private func intake(_ svc: IntakeService, _ id: UUID) throws -> Intake {
        try XCTUnwrap(svc.intakes.first { $0.id == id })
    }

    // MARK: choosing: an edited start

    func testAnEditedFidelityStartsWithTheEditAndIsMarkedCustomized() async throws {
        let i = try seedChoice()
        let svc = await makeService()
        let base = try stock(.featurePlan)
        var edit = base
        edit.refinementCap = 5
        edit.encoder.effort = "low"
        edit.crossCheck = .every
        XCTAssertNil(svc.phoneStart(i.id, token: UUID(), preset: "featurePlan", config: wire(edit), base: wire(base)))
        let after = try intake(svc, i.id)
        XCTAssertEqual(after.state, .shaping)
        XCTAssertEqual(after.chosenPreset, .featurePlan)
        XCTAssertEqual(after.roundConfig?.refinementCap, 5)
        XCTAssertEqual(after.roundConfig?.encoder.effort, "low")
        XCTAssertEqual(after.roundConfig?.crossCheck, .every)
        XCTAssertEqual(after.roundConfig?.customized, true)
    }

    func testAnUneditedStartIsTheStockConfig() async throws {
        let i = try seedChoice()
        let svc = await makeService()
        let base = try stock(.sketch)
        XCTAssertNil(svc.phoneStart(i.id, token: UUID(), preset: "sketch", config: wire(base), base: wire(base)))
        XCTAssertEqual(try intake(svc, i.id).roundConfig, base)
    }

    func testAnEditedStartKeepsAnAccountAndARotation() async throws {
        let i = try seedChoice()
        let svc = await makeService()
        let base = try stock(.featurePlan)
        let pool = AccountChoice.pool(PoolID("team"))
        var edit = base
        edit.integrator.account = pool
        edit.integrators = [edit.integrator, base.encoder]
        XCTAssertNil(svc.phoneStart(i.id, token: UUID(), preset: "featurePlan", config: wire(edit), base: wire(base)))
        let after = try XCTUnwrap(try intake(svc, i.id).roundConfig)
        XCTAssertEqual(after.integrator.account, pool)
        XCTAssertEqual(after.integrators?.first?.account, pool)
        XCTAssertEqual(after.integrators?.count, 2)
    }

    func testAStartFromAStaleBaseIsRefusedAndStartsNothing() async throws {
        let i = try seedChoice()
        let svc = await makeService()
        let base = try stock(.featurePlan)
        var old = base
        old.polishCap = 9
        let token = UUID()
        XCTAssertEqual(svc.phoneStart(i.id, token: token, preset: "featurePlan", config: wire(base), base: wire(old)), "rounds_changed")
        XCTAssertEqual(try intake(svc, i.id).state, .awaitingChoice)
        XCTAssertNil(svc.phoneStart(i.id, token: token, preset: "featurePlan", config: wire(base), base: wire(base)),
                     "a refusal does not burn the token")
    }

    func testAStartTheEditorCouldNotHaveMadeIsRefused() async throws {
        let i = try seedChoice()
        let svc = await makeService()
        let base = try stock(.featurePlan)
        let b = wire(base)

        var unknownAgent = b
        unknownAgent.encoder.choice.agent = "nonesuch"
        XCTAssertEqual(svc.phoneStart(i.id, token: UUID(), preset: "featurePlan", config: unknownAgent, base: b), "invalid_config")

        var badAccount = b
        badAccount.integrator.choice.accountKey = "somewhere:else"
        XCTAssertEqual(svc.phoneStart(i.id, token: UUID(), preset: "featurePlan", config: badAccount, base: b), "invalid_config")

        var fewerDrafters = b
        fewerDrafters.drafters.removeLast()
        XCTAssertEqual(svc.phoneStart(i.id, token: UUID(), preset: "featurePlan", config: fewerDrafters, base: b), "invalid_config")

        var noPolisher = b
        noPolisher.polisher = nil
        XCTAssertEqual(svc.phoneStart(i.id, token: UUID(), preset: "featurePlan", config: noPolisher, base: b), "invalid_config")

        var hugeCap = b
        hugeCap.refinementCap = PhoneRoundsEdit.maxRounds + 1
        XCTAssertEqual(svc.phoneStart(i.id, token: UUID(), preset: "featurePlan", config: hugeCap, base: b), "invalid_config")

        var negative = b
        negative.polishCap = -1
        XCTAssertEqual(svc.phoneStart(i.id, token: UUID(), preset: "featurePlan", config: negative, base: b), "invalid_config")

        var play = b
        play.defaultPlay = "sideways"
        XCTAssertEqual(svc.phoneStart(i.id, token: UUID(), preset: "featurePlan", config: play, base: b), "invalid_config")

        var persona = b
        persona.drafters[0].persona = "villain"
        XCTAssertEqual(svc.phoneStart(i.id, token: UUID(), preset: "featurePlan", config: persona, base: b), "invalid_config")

        XCTAssertEqual(try intake(svc, i.id).state, .awaitingChoice)
    }

    func testAStartOnAnAgentThatCannotRunIsRefused() async throws {
        let i = try seedChoice()
        let svc = await makeService(available: AvailableModels(codex: CodexProfile().defaultPlanningChoice, claude: nil))
        let base = try XCTUnwrap(PresetExpansion.config(for: .sketch, available: svc.availableModels()))
        var edit = base
        edit.encoder = ModelChoice(agent: .claude, model: "opus", effort: "high")
        XCTAssertEqual(svc.phoneStart(i.id, token: UUID(), preset: "sketch", config: wire(edit), base: wire(base)), "invalid_config",
                       "claude is not signed in: the reference ran codex alone")
    }

    func testAStartIsRefusedOnceTheIntakeMovedOnOrForSingleTask() async throws {
        let shaping = try seedShaping()
        let choice = try seedChoice()
        let svc = await makeService()
        let b = wire(try stock(.sketch))
        XCTAssertEqual(svc.phoneStart(shaping.id, token: UUID(), preset: "sketch", config: b, base: b), "intake_moved_on")
        XCTAssertEqual(svc.phoneStart(UUID(), token: UUID(), preset: "sketch", config: b, base: b), "unknown_intake")
        XCTAssertEqual(svc.phoneStart(choice.id, token: UUID(), preset: "bead", config: b, base: b), "unknown_preset")
        XCTAssertEqual(svc.phoneStart(choice.id, token: UUID(), preset: "enormous", config: b, base: b), "unknown_preset")
    }

    func testARetriedStartIsAckedOnce() async throws {
        let i = try seedChoice()
        let svc = await makeService()
        let b = wire(try stock(.sketch))
        let token = UUID()
        XCTAssertNil(svc.phoneStart(i.id, token: token, preset: "sketch", config: b, base: b))
        XCTAssertNil(svc.phoneStart(i.id, token: token, preset: "sketch", config: b, base: b))
        XCTAssertEqual(try intake(svc, i.id).state, .shaping)
    }

    // MARK: shaping: an edit saved

    func testAShapingEditIsSavedThroughTheMacsOwnSave() async throws {
        let i = try seedShaping()
        let svc = await makeService()
        let base = try XCTUnwrap(try intake(svc, i.id).roundConfig)
        var edit = base
        edit.polishCap = 3
        edit.refinementCap = 4
        edit.defaultPlay = .toReview
        edit.reviewer?.choice.effort = "low"
        edit.reviewers = nil
        XCTAssertNil(svc.phoneRounds(i.id, token: UUID(), config: wire(edit), base: wire(base)))
        let after = try XCTUnwrap(try intake(svc, i.id).roundConfig)
        XCTAssertEqual(after.polishCap, 3)
        XCTAssertEqual(after.refinementCap, 4)
        XCTAssertEqual(after.defaultPlay, .toReview)
        XCTAssertEqual(after.reviewer?.choice.effort, "low")
        XCTAssertNil(after.reviewers, "a role set back to one agent is no rotation")
        XCTAssertTrue(after.customized)
    }

    func testAnEditWithNothingChangedWritesNothing() async throws {
        let i = try seedShaping()
        let svc = await makeService()
        let base = try XCTUnwrap(try intake(svc, i.id).roundConfig)
        XCTAssertNil(svc.phoneRounds(i.id, token: UUID(), config: wire(base), base: wire(base)))
        XCTAssertFalse(try intake(svc, i.id).roundConfig?.customized ?? true)
    }

    func testAStageThatAlreadyRanIsRefusedWithTheMacsSentence() async throws {
        // A polish checkpoint is the furthest: draft, synthesis and refine are over.
        let i = try seedShaping(checkpoints: [checkpoint(1, .draft), checkpoint(2, .synthesis),
                                              checkpoint(3, .refine, round: 1), checkpoint(4, .encode),
                                              checkpoint(5, .polish, round: 1)])
        let svc = await makeService()
        let base = try XCTUnwrap(try intake(svc, i.id).roundConfig)

        var drafter = base
        drafter.drafters[0].choice.effort = "low"
        XCTAssertEqual(svc.phoneRounds(i.id, token: UUID(), config: wire(drafter), base: wire(base)),
                       RoundsRefusal.prefix + "The drafter already ran, so it can't change.")

        var reviewer = base
        reviewer.reviewer?.choice.effort = "low"
        reviewer.reviewers?[0].choice.effort = "low"   // a rotation's first entry is the single field
        XCTAssertEqual(svc.phoneRounds(i.id, token: UUID(), config: wire(reviewer), base: wire(base)),
                       RoundsRefusal.prefix + "The reviewer already ran, so it can't change.")

        var rotation = base
        rotation.integrators = [base.integrator, base.integrator]
        XCTAssertEqual(svc.phoneRounds(i.id, token: UUID(), config: wire(rotation), base: wire(base)),
                       RoundsRefusal.prefix + "The integrator already ran, so it can't change.", "the rotation lists compare too")

        var rounds = base
        rounds.refinementCap = base.refinementCap + 1
        XCTAssertEqual(svc.phoneRounds(i.id, token: UUID(), config: wire(rounds), base: wire(base)),
                       RoundsRefusal.prefix + "Refinement already ran, so its rounds can't change.")

        XCTAssertEqual(try intake(svc, i.id).roundConfig, base, "nothing was written")
    }

    func testWhatHasNotRunYetStillTakesAnEdit() async throws {
        let i = try seedShaping(checkpoints: [checkpoint(1, .draft)])
        let svc = await makeService()
        let base = try XCTUnwrap(try intake(svc, i.id).roundConfig)
        var edit = base
        edit.encoder.effort = "low"
        XCTAssertNil(svc.phoneRounds(i.id, token: UUID(), config: wire(edit), base: wire(base)))
        XCTAssertEqual(try intake(svc, i.id).roundConfig?.encoder.effort, "low")
    }

    func testNothingChangesWhileARoundRuns() async throws {
        let i = try seedShaping(.running)
        let svc = await makeService()
        let base = try XCTUnwrap(try intake(svc, i.id).roundConfig)
        var edit = base
        edit.polishCap = 1
        XCTAssertEqual(svc.phoneRounds(i.id, token: UUID(), config: wire(edit), base: wire(base)),
                       RoundsRefusal.prefix + "Pause to change agents.")
        XCTAssertEqual(try intake(svc, i.id).roundConfig, base)
    }

    func testAnEditFromAConfigTheMacHasSinceChangedIsRefused() async throws {
        let i = try seedShaping()
        let svc = await makeService()
        let seen = try XCTUnwrap(try intake(svc, i.id).roundConfig)
        svc.setDefaultPlay(i.id, .step)   // the Mac changed it after the phone loaded the rounds
        var edit = seen
        edit.polishCap = 1
        let token = UUID()
        XCTAssertEqual(svc.phoneRounds(i.id, token: token, config: wire(edit), base: wire(seen)), "rounds_changed")
        XCTAssertEqual(try intake(svc, i.id).roundConfig?.defaultPlay, .step)
        XCTAssertEqual(try intake(svc, i.id).roundConfig?.polishCap, seen.polishCap, "the stale edit was not applied")
        let current = try XCTUnwrap(try intake(svc, i.id).roundConfig)
        edit.defaultPlay = .step
        XCTAssertNil(svc.phoneRounds(i.id, token: token, config: wire(edit), base: wire(current)), "the corrected retry applies")
    }

    func testAnEditIsRefusedWhileTheMacHoldsAnUnsavedOne() async throws {
        let i = try seedShaping()
        let svc = await makeService()
        let base = try XCTUnwrap(try intake(svc, i.id).roundConfig)
        var held = base
        held.polishCap = 1
        svc.setRoundConfigDraft(i.id, held)
        var edit = base
        edit.encoder.effort = "low"
        XCTAssertEqual(svc.phoneRounds(i.id, token: UUID(), config: wire(edit), base: wire(base)),
                       RoundsRefusal.prefix + "These rounds are being edited on your Mac.")
    }

    func testAnEditNoOneCouldHaveMadeIsRefused() async throws {
        let i = try seedShaping()
        let svc = await makeService()
        let base = try XCTUnwrap(try intake(svc, i.id).roundConfig)
        var edit = wire(base)
        edit.drafters.removeLast()
        XCTAssertEqual(svc.phoneRounds(i.id, token: UUID(), config: edit, base: wire(base)), "invalid_config")
    }

    func testAShapingEditIsRefusedOnceTheIntakeMovedOn() async throws {
        var review = try seedShaping()
        review.state = .review
        try IntakeStore(root: root).save(review)
        let choice = try seedChoice()
        let svc = await makeService()
        let b = wire(try stock(.fullPlan))
        XCTAssertEqual(svc.phoneRounds(review.id, token: UUID(), config: b, base: b), "intake_moved_on")
        XCTAssertEqual(svc.phoneRounds(choice.id, token: UUID(), config: b, base: b), "intake_moved_on")
        XCTAssertEqual(svc.phoneRounds(UUID(), token: UUID(), config: b, base: b), "unknown_intake")
    }

    func testARetriedEditIsAckedOnce() async throws {
        let i = try seedShaping()
        let svc = await makeService()
        let base = try XCTUnwrap(try intake(svc, i.id).roundConfig)
        var edit = base
        edit.polishCap = 3
        let token = UUID()
        XCTAssertNil(svc.phoneRounds(i.id, token: token, config: wire(edit), base: wire(base)))
        XCTAssertNil(svc.phoneRounds(i.id, token: token, config: wire(edit), base: wire(base)),
                     "the retry meets the config its first delivery changed, and is still acked")
    }

    // MARK: what the phone is sent

    func testTheMenuListsEveryAgentWithItsModelsEffortsAndWhyNot() throws {
        var available = AvailableModels.defaults
        available.unavailable[.grok] = "Grok: run `grok login`"
        available.options[.claude] = [ModelOption(id: "opus", name: "Opus 5.5", efforts: ["low", "high"]),
                                      ModelOption(id: "haiku", name: "Haiku 4.5", efforts: [])]
        let menu = PhoneRoundsEdit.menu(available: available, accounts: [:], naming: .init(available: available))
        XCTAssertTrue(["claude", "codex", "grok"].allSatisfy { id in menu.agents.contains { $0.agent == id } })
        let claude = try XCTUnwrap(menu.agents.first { $0.agent == "claude" })
        XCTAssertNil(claude.reason)
        XCTAssertEqual(claude.models.map(\.name), ["Opus 5.5", "Haiku 4.5"])
        XCTAssertEqual(claude.models.map(\.efforts), [["low", "high"], []], "a model with no levels hides the picker")
        XCTAssertEqual(claude.defaultChoice?.agent, "claude")
        XCTAssertFalse(claude.planningEffort.isEmpty)
        let grok = try XCTUnwrap(menu.agents.first { $0.agent == "grok" })
        XCTAssertEqual(grok.reason, "Grok: run `grok login`")
        XCTAssertEqual(grok.models, [])
        XCTAssertNil(grok.defaultChoice)
    }

    func testTheMenuCarriesAccountsAndOnlyTheModelListsThatDiffer() throws {
        var available = AvailableModels.defaults
        let work = AccountChoice.account(UUID())
        let pool = AccountChoice.pool(PoolID("team"))
        available.options[.claude] = [ModelOption(id: "opus", name: "Opus 5.5")]
        available.optionsByAccount[work.key] = [ModelOption(id: "sonnet", name: "Sonnet 5")]
        available.optionsByAccount[pool.key] = [ModelOption(id: "opus", name: "Opus 5.5")]
        let accounts: [AgentID: AccountMenu] = [.claude: AccountMenu(
            projectDefault: "Personal", options: [.init(choice: work, title: "Work", isPool: false),
                                                  .init(choice: pool, title: "Team pool", isPool: true)],
            offersChoice: true)]
        let menu = PhoneRoundsEdit.menu(available: available, accounts: accounts, naming: .init(available: available))
        let claude = try XCTUnwrap(menu.agents.first { $0.agent == "claude" })
        XCTAssertEqual(claude.accounts?.defaultTitle, "Project default — Personal")
        XCTAssertEqual(claude.accounts?.offersChoice, true)
        XCTAssertEqual(claude.accounts?.options.map(\.title), ["Work", "Team pool"])
        XCTAssertEqual(claude.accounts?.options.map(\.isPool), [false, true])
        XCTAssertEqual(claude.accountModels?[work.key]?.map(\.id), ["sonnet"])
        XCTAssertNil(claude.accountModels?[pool.key], "the same list as the project's is not sent twice")
        XCTAssertNil(menu.agents.first { $0.agent == "codex" }?.accounts, "no menu for an agent with none")
    }

    func testTheLockNamesWhatHasRunAndWhetherAnEditWouldBeTaken() throws {
        let config = try stock(.fullPlan)
        var tape = Tape(checkpoints: [checkpoint(1, .draft), checkpoint(2, .synthesis), checkpoint(3, .refine, round: 2)],
                        status: .paused, extraRefinement: 1)
        let lock = PhoneRoundsEdit.lock(ShapingEdit(tape: tape), config: config, editing: .editable)
        XCTAssertEqual(lock.locked, ["drafter0", "drafter1", "drafter2", "drafter3", "synthesizer"])
        XCTAssertTrue(lock.editable)
        XCTAssertNil(lock.reason)
        XCTAssertFalse(lock.refineDone, "a raised cap still adds refine rounds until a later stage runs")
        XCTAssertEqual(lock.extraRefinement, 1)
        XCTAssertEqual(lock.refinementFloor, 2)

        tape.checkpoints.append(checkpoint(4, .encode))
        let later = PhoneRoundsEdit.lock(ShapingEdit(tape: tape), config: config, editing: .readOnly)
        XCTAssertEqual(later.locked, ["drafter0", "drafter1", "drafter2", "drafter3", "synthesizer", "reviewer", "crossReviewer", "integrator", "encoder"])
        XCTAssertTrue(later.refineDone)
        XCTAssertFalse(later.editable)
        XCTAssertEqual(later.reason, "Pause to change agents.")
    }

    func testTheDetailCarriesTheEditorsLicenceMenuAndLockOnlyWhereTheyApply() async throws {
        let choice = try seedChoice()
        let shaping = try seedShaping(.paused, checkpoints: [checkpoint(1, .draft)])
        var review = try seedShaping()
        review.state = .review
        try IntakeStore(root: root).save(review)
        let svc = await makeService()

        let choosing = try XCTUnwrap(IntakeDetailProjection.detail(choice.id, project: UUID(), service: svc, servedAt: Date()))
        XCTAssertEqual(choosing.editRounds, true)
        XCTAssertNotNil(choosing.roundsMenu)
        XCTAssertNil(choosing.roundsLock, "nothing has run")

        let running = try XCTUnwrap(IntakeDetailProjection.detail(shaping.id, project: UUID(), service: svc, servedAt: Date()))
        XCTAssertEqual(running.editRounds, true)
        XCTAssertNotNil(running.roundsMenu)
        XCTAssertEqual(running.roundsLock?.editable, true)
        XCTAssertEqual(running.roundsLock?.locked.contains("drafter0"), true)

        let done = try XCTUnwrap(IntakeDetailProjection.detail(review.id, project: UUID(), service: svc, servedAt: Date()))
        XCTAssertNil(done.roundsMenu)
        XCTAssertNil(done.roundsLock)
        XCTAssertNotNil(done.roundConfig)
    }

    func testTheWireCarriesAnAccountAsAKeyTheMacReadsBack() throws {
        let pool = AccountChoice.pool(PoolID("team"))
        var config = try stock(.featurePlan)
        config.integrator.account = pool
        config.integrators?[0] = config.integrator   // a rotation's first entry is the single field
        let wired = wire(config)
        XCTAssertEqual(wired.integrator.choice.accountKey, pool.key)
        XCTAssertNil(wired.encoder.choice.accountKey)
        let back = try XCTUnwrap(PhoneRoundsEdit.roundConfig(wired))
        XCTAssertEqual(back.integrator.account, pool)
        XCTAssertTrue(PhoneRoundsEdit.sameRounds(back, config))
    }

    func testEveryStockConfigSurvivesTheRoundTrip() throws {
        for preset in [Preset.sketch, .featurePlan, .fullPlan] {
            let config = try stock(preset)
            let back = try XCTUnwrap(PhoneRoundsEdit.roundConfig(wire(config)), "\(preset)")
            XCTAssertEqual(back, config, "\(preset)")
        }
        let gemini = AvailableModels(choices: [
            .codex: CodexProfile().defaultPlanningChoice, .claude: ClaudeProfile().defaultPlanningChoice,
            .gemini: GeminiProfile().defaultPlanningChoice, .grok: GrokProfile().defaultPlanningChoice])
        for preset in [Preset.featurePlan, .fullPlan] {
            let config = try XCTUnwrap(PresetExpansion.config(for: preset, available: gemini))
            XCTAssertEqual(PhoneRoundsEdit.roundConfig(wire(config)), config, "four families: \(preset)")
        }
    }
}
