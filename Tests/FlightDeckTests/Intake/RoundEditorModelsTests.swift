import Foundation
import FleetKit
import IntakeKit
import XCTest
@testable import FlightDeck

/// The Rounds editor's model menu, effort and account rows; the refresher that fills the menus
/// from each CLI; and the phone's wire. No test spawns a CLI: every source is a fake.
@MainActor
final class RoundEditorModelsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("RoundEditorModelsTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ModelNaming.resetRegistry()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        ModelNaming.resetRegistry()
    }

    private var opus: ModelOption { opusOption }
    private var haiku: ModelOption { haikuOption }
    private var luna: ModelOption { lunaOption }

    private func available() -> AvailableModels {
        var a = AvailableModels(choices: [.claude: ClaudeProfile().defaultPlanningChoice, .codex: CodexProfile().defaultPlanningChoice,
                                          .gemini: GeminiProfile().defaultPlanningChoice])
        a.options = [.claude: [opus, haiku], .codex: [luna]]
        a.unavailable[.grok] = "Grok: run `grok login`"
        a.unavailable[.opencode] = "OpenCode: not installed"
        return a
    }

    private func config() throws -> RoundConfig {
        try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: available()))
    }

    // MARK: - The model menu

    func testEveryAgentIsListedAndTheUnusableOnesAreDisabledWithTheirReason() {
        let a = available()
        let agents = RoundConfigEditor.menuAgents(in: a, chosen: .codex)
        XCTAssertEqual(agents, AgentID.planningOrder.filter { [.codex, .claude, .grok, .gemini, .opencode].contains($0) })
        XCTAssertNil(RoundConfigEditor.unavailableReason(.claude, available: a))
        XCTAssertEqual(RoundConfigEditor.unavailableReason(.grok, available: a), "Grok: run `grok login`")
        XCTAssertEqual(RoundConfigEditor.unavailableReason(.opencode, available: a), "OpenCode: not installed")
        // An agent a role holds but detection no longer offers stays, so a re-check never blanks it.
        var lost = a
        lost.unavailable[.grok] = nil
        XCTAssertTrue(RoundConfigEditor.menuAgents(in: lost, chosen: .grok).contains(.grok))
        XCTAssertEqual(RoundConfigEditor.unavailableReason(.grok, available: lost), "Grok (unavailable)")
    }

    func testPickingAModelMovesTheAgentModelAndEffortTogether() throws {
        let a = available()
        let cfg = try config()
        let site = RoundConfigEditor.ChoiceSite(keyPath: .drafter(0))
        let toHaiku = RoundConfigEditor.selecting(cfg, at: site, agent: .claude, model: haiku.id, available: a)
        XCTAssertEqual(toHaiku.drafters[0].choice, ModelChoice(agent: .claude, model: haiku.id, effort: ""), "no levels: empty, like gemini")
        XCTAssertTrue(toHaiku.customized)
        let toLuna = RoundConfigEditor.selecting(toHaiku, at: site, agent: .codex, model: luna.id, available: a)
        XCTAssertEqual(toLuna.drafters[0].choice, ModelChoice(agent: .codex, model: luna.id, effort: "medium"),
                       "levels again: the planning effort when the model has it, else the nearest")
    }

    func testAFallbackIsPickedLikeAnyRoleAndKeepsItsOwnAccount() throws {
        let a = available()
        let work = AccountChoice.account(UUID())
        var cfg = try config()
        cfg.drafters[0].fallback = nil
        let site = RoundConfigEditor.ChoiceSite(keyPath: .drafter(0), isFallback: true)
        XCTAssertNil(RoundConfigEditor.choice(at: site, in: cfg))
        cfg = RoundConfigEditor.selecting(cfg, at: site, agent: .claude, model: opus.id, available: a)
        XCTAssertEqual(cfg.drafters[0].fallback?.model, opus.id)
        cfg = RoundConfigEditor.updatingChoice(cfg, at: site) { $0.account = work }
        XCTAssertEqual(cfg.drafters[0].fallback?.account, work)
        XCTAssertNil(cfg.drafters[0].choice.account, "the role's own account is a separate choice")
        cfg = RoundConfigEditor.selecting(cfg, at: site, agent: .claude, model: haiku.id, available: a)
        XCTAssertEqual(cfg.drafters[0].fallback?.account, work, "same agent: the account stays")
        cfg = RoundConfigEditor.updatingFallback(cfg, at: .drafter(0), to: nil)
        XCTAssertNil(cfg.drafters[0].fallback, "None")
    }

    func testARotationEntryHoldsItsOwnAccount() throws {
        let work = AccountChoice.pool("team")
        var cfg = try config()
        cfg = RoundConfigEditor.updatingChoice(cfg, at: RoundConfigEditor.ChoiceSite(keyPath: .reviewerEntry(1))) { $0.account = work }
        XCTAssertEqual(cfg.reviewer(rotation: 1)?.choice.account, work)
        XCTAssertNil(cfg.reviewer(rotation: 0)?.choice.account)
    }

    // MARK: - Effort

    func testEffortIsShownOnlyForModelsThatHaveLevels() {
        let a = available()
        XCTAssertEqual(RoundConfigEditor.effortLevels(for: ModelChoice(agent: .claude, model: opus.id, effort: "high"), available: a), opus.efforts)
        XCTAssertEqual(RoundConfigEditor.effortLevels(for: ModelChoice(agent: .claude, model: haiku.id, effort: ""), available: a), [])
        XCTAssertEqual(RoundConfigEditor.effortLevels(for: ModelChoice(agent: .gemini, model: GeminiProfile.defaultPlanningModel, effort: ""), available: a), [])
        XCTAssertEqual(RoundConfigEditor.effortLevels(for: ModelChoice(agent: .opencode, model: "opencode/big-pickle", effort: ""), available: a), [])
        XCTAssertEqual(RoundConfigEditor.effortLevels(for: ModelChoice(agent: .codex, model: luna.id, effort: "medium"), available: a), ["low", "medium"])
        // A saved level the model no longer lists stays selectable, so the picker never reads blank.
        XCTAssertEqual(RoundConfigEditor.effortLevels(for: ModelChoice(agent: .codex, model: luna.id, effort: "xhigh"), available: a),
                       ["low", "medium", "xhigh"])
    }

    // MARK: - The Account row

    func testTheAccountRowIsAPickerOnlyWhenThereIsAChoice() {
        let plain = ModelChoice(agent: .claude, model: opus.id, effort: "high")
        let one = AccountMenu(projectDefault: "Personal")
        XCTAssertEqual(RoundConfigEditor.accountRow(one, choice: plain), .line("Personal"))
        let several = AccountMenu(projectDefault: "Personal", options: [], offersChoice: true)
        XCTAssertEqual(RoundConfigEditor.accountRow(several, choice: plain), .picker)
        var held = plain
        held.account = .pool("team")
        XCTAssertEqual(RoundConfigEditor.accountRow(one, choice: held), .picker, "a role holding its own can be put back")
        XCTAssertEqual(RoundConfigEditor.accountLabel, "Account")
        XCTAssertEqual(several.defaultTitle, "Project default — Personal")
    }

    func testNoVisibleEditorTextSaysBillsOrANakedAgentId() throws {
        let a = available()
        var strings: [String] = [RoundConfigEditor.accountLabel, RoundConfigEditor.otherModel,
                                 AccountMenu(projectDefault: "Personal").defaultTitle]
        if case .line(let text) = RoundConfigEditor.accountRow(AccountMenu(projectDefault: "Personal"), choice: ModelChoice(agent: .codex, model: "m", effort: "")) {
            strings.append(text)
        }
        for agent in AgentID.allCases {
            strings += a.menuOptions(for: agent).map(\.name)
            strings.append(a.modelLabel(agent: agent, model: a.menuOptions(for: agent).first?.id ?? "x"))
        }
        strings.append(RoundConfigEditor.summary(preset: .featurePlan, config: try config()))
        for text in strings {
            XCTAssertFalse(text.contains("Bill"), text)
            for agent in AgentID.allCases { XCTAssertFalse(text.contains(agent.rawValue), "\(text) shows the raw id \(agent.rawValue)") }
        }
    }

    // MARK: - The account menu (the live resolver)

    func testTheAccountMenuNamesTheProjectDefaultAndOffersAChoiceOnlyWhenThereIsOne() {
        let work = AgentAccount(agent: .claude, displayName: "Work", home: dir.appendingPathComponent("work"))
        let spare = AgentAccount(agent: .claude, displayName: "Spare", home: dir.appendingPathComponent("spare"))
        let solo = AgentAccount(agent: .codex, displayName: "CX", home: dir.appendingPathComponent("cx"))
        let store = PreferencesStore(persistence: nil)
        store.preferences.accountList = AccountList(entries: [
            .account(solo), .account(work),
            .pool(AccountPool(id: "team", label: "Team", agent: .claude, members: [spare])),
        ])
        let resolver = AccountResolver(preferences: store, ledger: CapacityLedger())
        let claude = resolver.accountMenu(.claude, project: "/p")
        XCTAssertTrue(claude.offersChoice)
        XCTAssertEqual(claude.projectDefault, "Work")
        XCTAssertEqual(claude.defaultTitle, "Project default — Work")
        XCTAssertTrue(claude.options.contains { $0.choice == .account(work.id) && !$0.isPool })
        XCTAssertTrue(claude.options.contains { $0.choice == .pool("team") && $0.isPool })
        let codex = resolver.accountMenu(.codex, project: "/p")
        XCTAssertFalse(codex.offersChoice, "one account and no pool of the user's own: shown as text")
        XCTAssertEqual(codex.projectDefault, "CX")
        let grok = resolver.accountMenu(.grok, project: "/p")
        XCTAssertFalse(grok.offersChoice)
        XCTAssertEqual(grok.projectDefault, "Grok built-in")
        XCTAssertEqual(claude.title(for: .account(work.id)), "Work")
    }

    func testBillingKnowsTheChoiceBehindItsName() {
        let work = AgentAccount(agent: .claude, displayName: "Work", home: dir.appendingPathComponent("work"))
        let store = PreferencesStore(persistence: nil)
        store.preferences.accountList = AccountList(entries: [.account(work)])
        let resolver = AccountResolver(preferences: store, ledger: CapacityLedger())
        XCTAssertEqual(resolver.billing(.claude, project: "/p").choice, .account(work.id))
        XCTAssertNil(resolver.billing(.grok, project: "/p").choice)
    }

    // MARK: - The refresher

    private func account(_ agent: AgentID, _ name: String, bound: Bool = true) -> ModelListTargets.Account {
        ModelListTargets.Account(agent: agent, choice: .account(UUID()), home: URL(fileURLWithPath: "/homes/\(name)"), bound: bound)
    }

    private func refresher(read: @escaping @Sendable (AgentID, URL) -> [ModelOption]?,
                           log: @escaping @Sendable (String) -> Void = { _ in }) -> ModelListRefresher {
        ModelListRefresher(store: ModelListStore(directory: dir.appendingPathComponent("lists")),
                           runClaude: { _, _ in nil }, readCache: read, log: log)
    }

    func testEachAccountIsReadFromItsOwnHomeAndAPoolListsTheUnion() {
        let work = account(.claude, "work"), spare = account(.claude, "spare")
        let targets = ModelListTargets(accounts: [work, spare],
                                       pools: [.init(choice: .pool("team"), agent: .claude, members: [work.choice!, spare.choice!])])
        let r = refresher { _, home in home.lastPathComponent == "work" ? [opusOption] : [haikuOption] }
        let lists = r.refresh(targets)
        XCTAssertEqual(lists[work.choice!.key], [opus])
        XCTAssertEqual(lists[spare.choice!.key], [haiku], "accounts see different models")
        XCTAssertEqual(lists["pool:team"], [opus, haiku], "the union, first member first")
        XCTAssertEqual(r.cached(targets)[work.choice!.key], [opus], "the editor's first paint reads the store")
    }

    func testAFailedRefreshKeepsTheLastGoodListAndLogsWhy() {
        let work = account(.codex, "work")
        let targets = ModelListTargets(accounts: [work])
        let logged = LockedLog()
        let good = refresher(read: { _, _ in [lunaOption] })
        XCTAssertEqual(good.refresh(targets)[work.choice!.key], [luna])
        let offline = ModelListRefresher(store: good.store, runClaude: { _, _ in nil }, readCache: { _, _ in nil }, log: { logged.add($0) })
        XCTAssertEqual(offline.refresh(targets)[work.choice!.key], [luna], "never emptied")
        XCTAssertTrue(logged.lines.first?.contains("keeping 1 cached") == true, "\(logged.lines)")
    }

    func testClaudeAsksTheLocalModelCommandInTheAccountsHome() {
        let work = account(.claude, "work")
        let asked = LockedLog()
        let r = ModelListRefresher(store: ModelListStore(directory: dir.appendingPathComponent("lists")),
                                   runClaude: { account, model in
                                       asked.add("\(account.home.lastPathComponent) \(model ?? "-")")
                                       let name = model == "opus" ? "Opus 5.5" : "Opus 5.5"
                                       return try? JSONSerialization.data(withJSONObject: [
                                           "local_command": "model", "total_cost_usd": 0, "is_error": false,
                                           "result": "Current model: `\(name)`\nUsage: /model <name>. Available: opus, best, or a full model ID."])
                                   },
                                   readCache: { _, _ in [opusOption] }, log: { _ in })
        let list = r.refresh(ModelListTargets(accounts: [work]))[work.choice!.key]
        XCTAssertEqual(list?.map(\.id), [opus.id, "opus"])
        XCTAssertEqual(list?.last?.name, "Opus 5.5 (latest)")
        XCTAssertEqual(list?.last?.efforts, opus.efforts)
        XCTAssertEqual(asked.lines, ["work -", "work opus"])
    }

    func testDetectionListsAreStoredAndAFailedDetectionFallsBackToThem() {
        let r = refresher(read: { _, _ in nil })
        var first = available()
        first.options[.gemini] = [ModelOption(id: GeminiProfile.defaultPlanningModel, name: "Gemini 3.8 Flash (High)")]
        r.record(&first)
        var offline = available()
        offline.options[.gemini] = nil
        r.record(&offline)
        XCTAssertEqual(offline.options[.gemini]?.first?.name, "Gemini 3.8 Flash (High)", "agy was unreachable: the last list stands")
        XCTAssertNil(offline.options[.grok], "nothing stored for grok, nothing invented")
    }

    func testRefreshedNamesReachTheRegistryThePrintedLabelsUse() {
        let work = account(.codex, "work")
        _ = refresher(read: { _, _ in [ModelOption(id: "gpt-9", name: "GPT 9 Nova")] }).refresh(ModelListTargets(accounts: [work]))
        XCTAssertEqual(ModelChoice(agent: .codex, model: "gpt-9", effort: "high").displayLabel, "Codex > GPT 9 Nova")
    }

    // MARK: - The service

    func testDetectionAlsoRefreshesTheModelListsAndTheEditorReadsTheProjectDefaultsList() async throws {
        let work = account(.claude, "work")
        let spare = account(.claude, "spare")
        let targets = ModelListTargets(accounts: [work, spare])
        let r = refresher { _, home in home.lastPathComponent == "work" ? [opusOption] : [haikuOption] }
        let service = IntakeService(store: IntakeStore(root: dir.appendingPathComponent("intakes")), availableModels: available(),
                                    inject: { _, _, _, _ in true }, hasSession: { _, _ in false },
                                    defaults: UserDefaults(suiteName: "RoundEditorModelsTests.\(UUID())")!,
                                    detectAgents: { AvailableModels.defaults })
        service.modelRefresher = r
        service.modelListTargets = { targets }
        XCTAssertTrue(service.modelLists.isEmpty)
        await service.recheckAgents().value
        XCTAssertEqual(service.modelLists[work.choice!.key], [opus])
        XCTAssertEqual(service.modelLists[spare.choice!.key], [haiku])
        let a = service.availableModels(project: "/p")
        XCTAssertEqual(a.optionsByAccount[spare.choice!.key], [haiku], "a role's own account lists its own models")
    }

    // MARK: - The wire

    func testTheWireCarriesTheModelNameAndARolesAccountAndOldMessagesStillDecode() throws {
        var cfg = try config()
        let work = AccountChoice.account(UUID())
        cfg.reviewer?.choice.account = work
        cfg.reviewers = [cfg.reviewer!, cfg.reviewer!]
        var a = available()
        a.options[.claude] = [opus, haiku]
        let naming = IntakeDetailProjection.Naming(available: a) { $0 == work ? "Work" : nil }
        let wire = IntakeDetailProjection.wireConfig(cfg, naming: naming)
        let reviewer = try XCTUnwrap(wire.reviewer?.choice)
        XCTAssertEqual(reviewer.account, "Work")
        XCTAssertEqual(reviewer.agentName, cfg.reviewer?.choice.agent.displayName)
        XCTAssertNotNil(reviewer.modelName)
        XCTAssertNil(wire.drafters[0].choice.account, "the project's assignment is not named")
        let claude = IntakeDetailProjection.wireChoice(ModelChoice(agent: .claude, model: opus.id, effort: "high"), naming: naming)
        XCTAssertEqual(claude.modelName, "Opus 5.5")
        XCTAssertEqual(claude.model, opus.id, "the id stays on the wire")
        let data = try JSONEncoder().encode(wire)
        XCTAssertEqual(try JSONDecoder().decode(WireRoundConfig.self, from: data), wire)
        let legacy = Data(#"{"agent":"claude","agentName":"Claude","model":"opus","effort":"high"}"#.utf8)
        let old = try JSONDecoder().decode(WireModelChoice.self, from: legacy)
        XCTAssertNil(old.modelName)
        XCTAssertNil(old.account)
    }

    func testWireOptionsForAFreshMacNameModelsWithoutALoadedList() {
        let wire = IntakeDetailProjection.wireChoice(ModelChoice(agent: .codex, model: "gpt-6-sol", effort: "high"))
        XCTAssertEqual(wire.modelName, "GPT 6 Sol", "derived when no list has been read")
    }
}

private let opusOption = ModelOption(id: "claude-opus-5-5", name: "Opus 5.5", efforts: ["low", "medium", "high", "xhigh", "max"])
private let haikuOption = ModelOption(id: "claude-haiku-4-5-20251001", name: "Haiku 4.5", efforts: [])
private let lunaOption = ModelOption(id: "gpt-6-luna", name: "GPT 6 Luna", efforts: ["low", "medium"])

private final class LockedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ line: String) { lock.withLock { storage.append(line) } }
    var lines: [String] { lock.withLock { storage } }
}

/// `ClaudeModelProcess` against a stand-in `claude` that records how it was run.
@MainActor
final class ClaudeModelProcessTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: "/tmp/cmp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        { echo "args: $*"; echo "config: ${CLAUDE_CONFIG_DIR:-unset}"; echo "child: ${CLAUDE_CODE_CHILD_SESSION:-unset}"; echo "cwd: $(pwd)"; } > "\(dir.path)/seen-$$"
        echo '{"local_command":"model","total_cost_usd":0,"is_error":false,"result":"Current model: `Opus 5.5`"}'
        """
        let url = dir.appendingPathComponent("bin/claude")
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func seen() throws -> String {
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: dir.path).first { $0.hasPrefix("seen-") })
        defer { try? FileManager.default.removeItem(at: dir.appendingPathComponent(file)) }
        return try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
    }

    func testItSendsOnlyTheLocalCommandWithNoSessionAndBindsAnAccountsHome() throws {
        let account = ModelListTargets.Account(agent: .claude, choice: .account(UUID()), home: dir.appendingPathComponent("acct"), bound: true)
        let data = ClaudeModelProcess.run(account, "opus", path: dir.appendingPathComponent("bin").path,
                                          base: ["PATH": "/usr/bin:/bin", "CLAUDE_CODE_CHILD_SESSION": "1"])
        XCTAssertEqual(ClaudeModelCommand.parse(try XCTUnwrap(data))?.name, "Opus 5.5")
        let record = try seen()
        XCTAssertTrue(record.contains("args: -p /model --output-format json --no-session-persistence --model opus"), record)
        XCTAssertTrue(record.contains("config: \(dir.path)/acct"), record)
        XCTAssertTrue(record.contains("child: unset"), "the child-session marker is scrubbed: \(record)")
        let cwd = record.split(separator: "\n").first { $0.hasPrefix("cwd: ") }.map { String($0.dropFirst(5)) } ?? ""
        XCTAssertTrue(cwd.contains("fd-model-"), record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cwd), "the temporary directory is removed")
    }

    func testTheBuiltInHomeIsNotBoundAndAMissingClaudeIsNil() throws {
        let builtIn = ModelListTargets.Account(agent: .claude, choice: nil, home: dir.appendingPathComponent("home"), bound: false)
        _ = ClaudeModelProcess.run(builtIn, nil, path: dir.appendingPathComponent("bin").path, base: ["PATH": "/usr/bin:/bin"])
        let record = try seen()
        XCTAssertTrue(record.contains("config: unset"), record)
        XCTAssertTrue(record.contains("args: -p /model --output-format json --no-session-persistence\n"), record)
        XCTAssertNil(ClaudeModelProcess.run(builtIn, nil, path: dir.appendingPathComponent("nowhere").path, base: [:]))
    }
}
