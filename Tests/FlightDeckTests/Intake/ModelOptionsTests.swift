import Foundation
import IntakeKit
import XCTest

/// The model lists and their names: every source path (claude's catalog file and local `/model`
/// command, codex's cache file, agy's and opencode's list output), the derivation for an id no
/// source names, the cache, and the per-model effort rules. Fixtures are recorded output; nothing
/// here spawns a CLI or reads the operator's home.
final class ModelOptionsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ModelOptionsTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ModelNaming.resetRegistry()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        ModelNaming.resetRegistry()
    }

    // MARK: - Fixtures

    /// Trimmed from `<config dir>/cache/model-catalog/<id>-cc.json` (claude 2.1.299).
    static let claudeCatalog = """
    {"version":2,"fetchedAt":1791942101522,"staleAt":1791945789755,"catalog":{"surface":"cc","config":{"id":"cc","models":[
     {"id":"claude-opus-5-5","name":"Opus 5.5","short_name":"Opus","thinking":{"type":"effort_and_mode","effort_options":[{"id":"low","name":"Low"},{"id":"medium","name":"Medium"},{"id":"high","name":"High"},{"id":"xhigh","name":"Extra"},{"id":"max","name":"Max"}]}},
     {"id":"claude-fable-5-1","name":"Fable 5.1","thinking":{"type":"effort_and_mode","effort_options":[{"id":"low"},{"id":"medium"},{"id":"high"},{"id":"xhigh"},{"id":"max"}]}},
     {"id":"claude-opus-4-6","name":"Opus 4.6","thinking":{"type":"effort_and_mode","effort_options":[{"id":"low"},{"id":"medium"},{"id":"high"},{"id":"max"}]}},
     {"id":"claude-haiku-4-5-20251001","name":"Haiku 4.5","thinking":{"type":"mode"}}]}}}
    """

    /// Trimmed from `~/.codex/models_cache.json` (codex-cli 0.162.1).
    static let codexCache = """
    {"fetched_at":"2026-10-14T18:24:40Z","client_version":"0.162.1","models":[
     {"slug":"gpt-6.1-sol","display_name":"GPT-6.1-Sol","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}]},
     {"slug":"gpt-6-luna","display_name":"GPT-6-Luna","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"}]},
     {"slug":"gpt-reserve","display_name":"GPT-Reserve","visibility":"hide","supported_reasoning_levels":[{"effort":"low"}]},
     {"slug":"codex-auto-review","display_name":"Codex Auto Review","visibility":"hide","supported_reasoning_levels":[]}]}
    """

    static let agyOutput = """
    gemini-3.8-flash-high\tGemini 3.8 Flash (High)
    gemini-3.8-flash-low\tGemini 3.8 Flash (Low)
    claude-opus-5-5-high\tClaude Opus 5.5 (High)
    gpt-oss-120b-medium\tGPT-OSS 120B (Medium)
    """

    static let opencodeVerbose = """
    opencode/big-pickle
    {
      "id": "big-pickle",
      "name": "Big Pickle",
      "api": { "url": "https://opencode.ai/inference/v1" },
      "variants": {}
    }
    ollama/qwen3-coder:30b
    {
      "id": "qwen3-coder:30b",
      "name": "qwen3-coder:30b",
      "variants": {}
    }
    """

    private func localCommand(result: String, cost: Double = 0, local: Bool = true) -> Data {
        let body: [String: Any] = ["result": result, "total_cost_usd": cost, "is_error": false,
                                   "local_command": local ? "model" : NSNull()].filter { !($0.value is NSNull) }
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private static let available = "Usage: /model <name>. Available: sonnet, opus, haiku, fable, best, sonnet[1m], opus[1m], fable[1m], opusplan, default, or a full model ID."

    // MARK: - Derived names

    func testDerivedNamesForTrickyIds() {
        XCTAssertEqual(ModelNaming.derive("claude-opus-5-5", agent: .claude), "Opus 5.5")
        XCTAssertEqual(ModelNaming.derive("claude-haiku-4-5-20251001", agent: .claude), "Haiku 4.5", "the date goes")
        XCTAssertEqual(ModelNaming.derive("gpt-6-sol"), "GPT 6 Sol")
        XCTAssertEqual(ModelNaming.derive("gpt-oss-120b-medium"), "GPT OSS 120B (Medium)")
        XCTAssertEqual(ModelNaming.derive("grok-4.7-build-fast"), "Grok 4.7 Build Fast")
        XCTAssertEqual(ModelNaming.derive("gemini-3.8-flash-high"), "Gemini 3.8 Flash (High)")
        XCTAssertEqual(ModelNaming.derive("ollama/qwen3-coder:30b"), "Qwen3 Coder:30b", "the provider prefix goes")
        XCTAssertEqual(ModelNaming.derive("claude-fable-5-1[1m]", agent: .claude), "Fable 5.1 (1M context)")
    }

    func testAnUnknownFutureIdStillGetsAName() {
        XCTAssertEqual(ModelNaming.derive("zeta-9-turbo"), "Zeta 9 Turbo")
        XCTAssertEqual(ModelNaming.derive("x"), "X")
        XCTAssertEqual(ModelNaming.derive("claude-"), "Claude", "never blank")
        XCTAssertEqual(ModelNaming.derive("---"), "---")
        XCTAssertEqual(ModelNaming.derive(""), "")
    }

    func testAliasNamesAndTheRegistry() {
        XCTAssertEqual(ModelNaming.aliasName("opus"), "Opus (latest)")
        let choice = ModelChoice(agent: .codex, model: "gpt-6.1-sol", effort: "high")
        XCTAssertEqual(choice.displayLabel, "Codex > GPT 6.1 Sol", "derived until a list is read")
        ModelNaming.register([ModelOption(id: "gpt-6.1-sol", name: "GPT 6.1 Sol")], agent: .codex)
        XCTAssertEqual(choice.displayLabel, "Codex > GPT 6.1 Sol")
        ModelNaming.register([ModelOption(id: "gpt-6.1-sol", name: "The CLI's own")], agent: .codex)
        XCTAssertEqual(choice.displayLabel, "Codex > The CLI's own", "a name a list holds beats the derivation")
        XCTAssertEqual(ModelChoice(agent: .opencode, model: "", effort: "").displayLabel, "OpenCode")
    }

    // MARK: - claude

    func testTheClaudeCatalogNamesModelsAndKnowsEachOnesEfforts() throws {
        let (fetched, options) = try XCTUnwrap(ModelListSources.claudeCatalog(Data(Self.claudeCatalog.utf8)))
        XCTAssertEqual(fetched.timeIntervalSince1970, 1791942101.522, accuracy: 0.001)
        XCTAssertEqual(options.map(\.name), ["Opus 5.5", "Fable 5.1", "Opus 4.6", "Haiku 4.5"], "the CLI's own display names")
        XCTAssertEqual(options[0].efforts, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(options[2].efforts, ["low", "medium", "high", "max"])
        XCTAssertEqual(options[3].efforts, [], "Haiku 4.5 takes no effort")
        XCTAssertEqual(options[3].id, "claude-haiku-4-5-20251001")
    }

    func testAClaudeCatalogFromAnotherSurfaceIsNotUsed() {
        let other = Self.claudeCatalog.replacingOccurrences(of: "\"surface\":\"cc\"", with: "\"surface\":\"ccd\"")
        XCTAssertNil(ModelListSources.claudeCatalog(Data(other.utf8)))
        XCTAssertNil(ModelListSources.claudeCatalog(Data("not json".utf8)))
    }

    func testTheNewestClaudeCatalogFileInAConfigDirectoryWins() throws {
        let cache = dir.appendingPathComponent("cache/model-catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let older = Self.claudeCatalog.replacingOccurrences(of: "1791942101522", with: "1790000000000")
            .replacingOccurrences(of: "Opus 5.5", with: "Old Opus")
        try Data(older.utf8).write(to: cache.appendingPathComponent("a-111-cc.json"))
        try Data(Self.claudeCatalog.utf8).write(to: cache.appendingPathComponent("b-222-cc.json"))
        try Data(Self.claudeCatalog.utf8).write(to: cache.appendingPathComponent("tok-333-ccd.json"))
        XCTAssertEqual(ModelListSources.claudeCache(configDirectory: dir)?.first?.name, "Opus 5.5")
        XCTAssertNil(ModelListSources.claudeCache(configDirectory: dir.appendingPathComponent("nowhere")))
    }

    func testTheLocalModelCommandIsParsedOnlyWhenItIsFree() throws {
        let ok = try XCTUnwrap(ClaudeModelCommand.parse(localCommand(result: "Current model: `Opus 5.5 (default)`\n" + Self.available)))
        XCTAssertEqual(ok.name, "Opus 5.5")
        XCTAssertEqual(ok.aliases, ["sonnet", "opus", "haiku", "fable"], "families only: no best, default, opusplan or [1m]")
        // `/models` (with an s) went to the model and billed $0.21; its output is refused.
        XCTAssertNil(ClaudeModelCommand.parse(localCommand(result: "text", cost: 0.21, local: false)))
        XCTAssertNil(ClaudeModelCommand.parse(localCommand(result: "Current model: `X`", cost: 0.21)), "local but billed")
        XCTAssertNil(ClaudeModelCommand.parse(localCommand(result: "Current model: `X`", local: false)))
        XCTAssertNil(ClaudeModelCommand.parse(Data("{}".utf8)))
        XCTAssertEqual(ClaudeModelCommand.prompt, "/model")
    }

    func testTheClaudeMenuIsTheCatalogPlusAliasesNamedForWhatTheyResolveTo() throws {
        let catalog = try XCTUnwrap(ModelListSources.claudeCatalog(Data(Self.claudeCatalog.utf8))).1
        var asked: [String?] = []
        let names = ["opus": "Opus 5.5", "fable": "Fable 5.1", "sonnet": "Sonnet 5.5", "haiku": "Haiku 4.5"]
        let options = ClaudeModelCommand.build(catalog: catalog) { model in
            asked.append(model)
            let resolved = model.map { names[$0] ?? $0 } ?? "Opus 5.5"
            return self.localCommand(result: "Current model: `\(resolved)`\n" + Self.available)
        }
        XCTAssertEqual(options.map(\.id), ["claude-opus-5-5", "claude-fable-5-1", "claude-opus-4-6", "claude-haiku-4-5-20251001",
                                            "sonnet", "opus", "haiku", "fable"])
        let opus = try XCTUnwrap(options.first { $0.id == "opus" })
        XCTAssertEqual(opus.name, "Opus 5.5 (latest)")
        XCTAssertEqual(opus.efforts, ["low", "medium", "high", "xhigh", "max"], "the alias takes its model's efforts")
        XCTAssertEqual(options.first { $0.id == "haiku" }?.efforts, [], "Haiku 4.5 takes none")
        XCTAssertEqual(options.first { $0.id == "sonnet" }?.efforts, nil, "no catalog entry: the profile's levels stand")
        XCTAssertEqual(asked.compactMap { $0 }, ["sonnet", "opus", "haiku", "fable"], "no candidate probes when a catalog exists")
    }

    func testWithoutACatalogTheCLIIsAskedAboutCandidateVersions() {
        let known: [String: String] = ["claude-opus-5-5": "Opus 5.5", "claude-sonnet-4-6": "Sonnet 4.6", "opus": "Opus 5.5"]
        let options = ClaudeModelCommand.build(catalog: nil) { model in
            // An unknown id echoes back unchanged.
            self.localCommand(result: "Current model: `\(model.map { known[$0] ?? $0 } ?? "Opus 5.5")`\n" + Self.available)
        }
        XCTAssertEqual(options.map(\.id), ["claude-opus-5-5", "claude-sonnet-4-6", "opus"], "only ids the CLI recognizes, then aliases that resolve")
        XCTAssertEqual(options.map(\.name), ["Opus 5.5", "Sonnet 4.6", "Opus 5.5 (latest)"])
    }

    func testARefusedModelCommandLeavesTheCatalogAlone() throws {
        let catalog = try XCTUnwrap(ModelListSources.claudeCatalog(Data(Self.claudeCatalog.utf8))).1
        XCTAssertEqual(ClaudeModelCommand.build(catalog: catalog) { _ in self.localCommand(result: "x", cost: 0.21, local: false) }, catalog)
        XCTAssertEqual(ClaudeModelCommand.build(catalog: nil) { _ in nil }, [])
    }

    // MARK: - codex, agy, opencode

    func testTheCodexCacheListsOnlyVisibleModelsWithTheirOwnEfforts() throws {
        let options = try XCTUnwrap(ModelListSources.codexCache(Data(Self.codexCache.utf8)))
        XCTAssertEqual(options.map(\.id), ["gpt-6.1-sol", "gpt-6-luna"], "hidden models are not offered")
        XCTAssertEqual(options.map(\.name), ["GPT 6.1 Sol", "GPT 6 Luna"], "codex's display names, hyphens read as spaces")
        XCTAssertEqual(options[0].efforts, ["low", "medium", "high", "xhigh", "max"], "ultra is never offered")
        XCTAssertEqual(options[1].efforts, ["low", "medium"])
    }

    func testTheCodexCacheIsReadFromAnAccountsHome() throws {
        try Data(Self.codexCache.utf8).write(to: dir.appendingPathComponent("models_cache.json"))
        XCTAssertEqual(ModelListSources.cliCache(agent: .codex, home: dir)?.count, 2)
        XCTAssertNil(ModelListSources.cliCache(agent: .codex, home: dir.appendingPathComponent("elsewhere")))
        XCTAssertNil(ModelListSources.cliCache(agent: .grok, home: dir), "grok's list is a command")
    }

    func testAgyNamesComeFromItsListingAndOnlyGeminiIdsStay() {
        let options = ModelListSources.agyList(Self.agyOutput)
        XCTAssertEqual(options.map(\.id), ["gemini-3.8-flash-high", "gemini-3.8-flash-low"])
        XCTAssertEqual(options.map(\.name), ["Gemini 3.8 Flash (High)", "Gemini 3.8 Flash (Low)"])
        XCTAssertNil(options[0].efforts, "the id carries the effort; the profile has no knob")
    }

    func testOpenCodeNamesComeFromItsVerboseListing() {
        let options = ModelListSources.opencodeList(Self.opencodeVerbose)
        XCTAssertEqual(options.map(\.id), ["opencode/big-pickle", "ollama/qwen3-coder:30b"])
        XCTAssertEqual(options.map(\.name), ["Big Pickle", "qwen3-coder:30b"])
        XCTAssertEqual(OpenCodeProfile().parseModelList(Self.opencodeVerbose), ["opencode/big-pickle", "ollama/qwen3-coder:30b"],
                       "the JSON between the ids is not read as models")
        let plain = ModelListSources.opencodeList("opencode/big-pickle\nollama/llama3.2:latest\n")
        XCTAssertEqual(plain.map(\.name), ["Big Pickle", "Llama3.2:latest"], "a plain listing is named by derivation")
    }

    func testGrokIdsAreNamedByDerivation() {
        let grok = "Default model: grok-4.7-build-fast\n\nAvailable models:\n  - grok-4.7\n  * grok-4.7-build-fast (default)\n"
        let options = ModelListSources.options(agent: .grok, listStdout: grok, profile: GrokProfile())
        XCTAssertEqual(options.map(\.id), ["grok-4.7-build-fast", "grok-4.7"])
        XCTAssertEqual(options.map(\.name), ["Grok 4.7 Build Fast", "Grok 4.7"])
    }

    // MARK: - the cache

    func testTheStoreKeepsOneListPerAgentAndAccountAndNeverEmptiesOne() throws {
        let store = ModelListStore(directory: dir.appendingPathComponent("lists"))
        let work = AccountChoice.account(UUID()), spare = AccountChoice.account(UUID())
        let a = [ModelOption(id: "claude-opus-5-5", name: "Opus 5.5", efforts: ["high"])]
        let b = [ModelOption(id: "claude-fable-5-1", name: "Fable 5.1")]
        let now = Date(timeIntervalSince1970: 1_000)
        store.save(a, agent: .claude, key: work.key, now: now)
        store.save(b, agent: .claude, key: spare.key, now: now)
        XCTAssertEqual(store.load(agent: .claude, key: work.key), ModelList(fetchedAt: now, options: a))
        XCTAssertEqual(store.load(agent: .claude, key: spare.key)?.options, b, "accounts see different models")
        XCTAssertNil(store.load(agent: .codex, key: work.key))
        // A refresh that found nothing keeps the last good list.
        XCTAssertEqual(store.save([], agent: .claude, key: work.key, now: now + 60)?.options, a)
        XCTAssertEqual(store.load(agent: .claude, key: work.key)?.fetchedAt, now)
        XCTAssertNil(store.load(agent: .claude, key: ModelListStore.defaultKey))
    }

    // MARK: - AvailableModels

    private func available(_ options: [AgentID: [ModelOption]] = [:]) -> AvailableModels {
        var a = AvailableModels(choices: [.claude: ClaudeProfile().defaultPlanningChoice, .codex: CodexProfile().defaultPlanningChoice,
                                          .gemini: GeminiProfile().defaultPlanningChoice, .opencode: ModelChoice(agent: .opencode, model: "", effort: "")])
        a.options = options
        return a
    }

    func testWithNoListYetTheMenuIsTheProfilesAliasesNamedByDerivation() {
        let a = available()
        let claude = a.menuOptions(for: .claude)
        XCTAssertEqual(claude.map(\.id), ["fable", "opus", "sonnet", "haiku"])
        XCTAssertEqual(claude.map(\.name), ["Fable (latest)", "Opus (latest)", "Sonnet (latest)", "Haiku (latest)"])
        XCTAssertEqual(a.menuOptions(for: .codex).map(\.name), ["GPT 6 Sol"], "the profile's default, named by derivation")
        XCTAssertEqual(a.modelLabel(agent: .claude, model: "opus"), "Claude > Opus (latest)", "a saved alias still reads sensibly")
    }

    func testLabelsReadAgentThenModelAndMarkACustomModel() throws {
        let listed = try XCTUnwrap(ModelListSources.claudeCatalog(Data(Self.claudeCatalog.utf8))).1
        let a = available([.claude: listed])
        XCTAssertEqual(a.modelLabel(agent: .claude, model: "claude-opus-5-5"), "Claude > Opus 5.5")
        XCTAssertEqual(a.modelLabel(agent: .claude, model: "claude-opus-9-9"), "Claude > Opus 9.9 (custom)")
        XCTAssertEqual(a.modelLabel(agent: .opencode, model: ""), "OpenCode > Default")
        XCTAssertEqual(a.displayName(agent: .claude, model: "claude-fable-5-1"), "Fable 5.1")
    }

    func testEffortShowsOnlyWhereTheModelHasLevels() throws {
        let listed = try XCTUnwrap(ModelListSources.claudeCatalog(Data(Self.claudeCatalog.utf8))).1
        let a = available([.claude: listed, .codex: try XCTUnwrap(ModelListSources.codexCache(Data(Self.codexCache.utf8)))])
        XCTAssertEqual(a.effortValues(agent: .claude, model: "claude-opus-5-5"), ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(a.effortValues(agent: .claude, model: "claude-opus-4-6"), ["low", "medium", "high", "max"])
        XCTAssertEqual(a.effortValues(agent: .claude, model: "claude-haiku-4-5-20251001"), [], "Haiku 4.5: hidden")
        XCTAssertEqual(a.effortValues(agent: .codex, model: "gpt-6-luna"), ["low", "medium"])
        XCTAssertEqual(a.effortValues(agent: .gemini, model: GeminiProfile.defaultPlanningModel), [], "the id carries it")
        XCTAssertEqual(a.effortValues(agent: .opencode, model: "opencode/big-pickle"), [], "no knob today")
        XCTAssertEqual(a.effortValues(agent: .claude, model: "claude-not-listed"), ClaudeProfile.catalog.effortValues,
                       "a custom model keeps the profile's levels")
    }

    func testSwitchingModelsMovesTheEffortWithIt() throws {
        let listed = try XCTUnwrap(ModelListSources.claudeCatalog(Data(Self.claudeCatalog.utf8))).1
        let a = available([.claude: listed])
        let opus = ModelChoice(agent: .claude, model: "claude-opus-5-5", effort: "xhigh")
        let haiku = a.selecting(agent: .claude, model: "claude-haiku-4-5-20251001", from: opus)
        XCTAssertEqual(haiku.effort, "", "no levels: stored empty, as gemini does")
        let back = a.selecting(agent: .claude, model: "claude-opus-5-5", from: haiku)
        XCTAssertEqual(back.effort, "high", "levels again: the profile's planning effort")
        let narrower = a.selecting(agent: .claude, model: "claude-opus-4-6", from: opus)
        XCTAssertEqual(narrower.effort, "high", "xhigh is not an Opus 4.6 level")
        XCTAssertEqual(a.selecting(agent: .claude, model: "claude-fable-5-1", from: ModelChoice(agent: .claude, model: "x", effort: "max")).effort, "max",
                       "a level the new model has is kept")
        let gemini = a.selecting(agent: .gemini, model: GeminiProfile.defaultPlanningModel, from: opus)
        XCTAssertEqual(gemini, ModelChoice(agent: .gemini, model: GeminiProfile.defaultPlanningModel, effort: ""))
    }

    func testARolesAccountSurvivesAModelChangeButNotAnAgentChange() {
        let work = AccountChoice.account(UUID())
        let held = ModelChoice(agent: .claude, model: "opus", effort: "high", account: work)
        let a = available()
        XCTAssertEqual(a.selecting(agent: .claude, model: "sonnet", from: held).account, work)
        XCTAssertNil(a.selecting(agent: .codex, model: "gpt-6-sol", from: held).account, "an account belongs to one agent")
    }

    func testEachAccountSeesItsOwnListAndAPoolTheUnion() {
        var a = available([.claude: [ModelOption(id: "project", name: "Project default model")]])
        let work = AccountChoice.account(UUID()), team = AccountChoice.pool("team")
        a.optionsByAccount[work.key] = [ModelOption(id: "w", name: "Only Work")]
        a.optionsByAccount[team.key] = [ModelOption(id: "w", name: "Only Work"), ModelOption(id: "s", name: "Only Spare")]
        XCTAssertEqual(a.menuOptions(for: .claude).map(\.id), ["project"], "nothing chosen: the project default's account")
        XCTAssertEqual(a.menuOptions(for: .claude, account: work).map(\.id), ["w"])
        XCTAssertEqual(a.menuOptions(for: .claude, account: team).map(\.id), ["w", "s"])
        XCTAssertEqual(a.menuOptions(for: .claude, account: .account(UUID())).map(\.id), ["project"], "an account never listed falls back")
    }

    // MARK: - Codable

    func testAnOverrideRoundTripsAndOldConfigsDecodeWithoutOne() throws {
        let work = UUID()
        let choice = ModelChoice(agent: .claude, model: "opus", effort: "high", account: .account(work))
        let json = String(decoding: try IntakeJSON.encoder.encode(choice), as: UTF8.self)
        XCTAssertTrue(json.contains("\"accountOverride\""), json)
        XCTAssertTrue(json.contains("account:\(work.uuidString)"), json)
        XCTAssertEqual(try IntakeJSON.decoder.decode(ModelChoice.self, from: Data(json.utf8)), choice)
        let pool = ModelChoice(agent: .codex, model: "m", effort: "low", account: .pool("team"))
        XCTAssertEqual(try IntakeJSON.decoder.decode(ModelChoice.self, from: IntakeJSON.encoder.encode(pool)), pool)

        let old = try IntakeJSON.decoder.decode(ModelChoice.self, from: Data(#"{"harness":"claude","model":"opus","effort":"high"}"#.utf8))
        XCTAssertNil(old.account)
        XCTAssertFalse(String(decoding: try IntakeJSON.encoder.encode(old), as: UTF8.self).contains("accountOverride"), "nil writes no key")
    }

    /// The `account` key a pre-R9 Rounds editor wrote per seat is still NOT honoured: it names the
    /// login a seat was given long ago, and billing it would undo the project's current assignment.
    func testTheOldPerSeatAccountKeyIsStillIgnored() throws {
        let old = Data(#"{"harness":"codex","model":"m","effort":"high","account":{"id":"w","home":"file:///accounts/w"}}"#.utf8)
        let decoded = try IntakeJSON.decoder.decode(ModelChoice.self, from: old)
        XCTAssertNil(decoded.account)
        XCTAssertFalse(String(decoding: try IntakeJSON.encoder.encode(decoded), as: UTF8.self).contains("account"))
        let uuid = Data(#"{"harness":"codex","model":"m","effort":"high","account":"\#(UUID().uuidString)"}"#.utf8)
        XCTAssertNil(try IntakeJSON.decoder.decode(ModelChoice.self, from: uuid).account)
    }

    func testAnOverrideThisBuildCannotReadIsNoOverrideNotABrokenConfig() throws {
        let future = Data(#"{"harness":"claude","model":"opus","effort":"high","accountOverride":"team-seat:7"}"#.utf8)
        let decoded = try IntakeJSON.decoder.decode(ModelChoice.self, from: future)
        XCTAssertEqual(decoded.model, "opus")
        XCTAssertNil(decoded.account)
        XCTAssertNil(AccountChoice(key: "pool:"))
        XCTAssertNil(AccountChoice(key: "account:not-a-uuid"))
    }

    // MARK: - The runner's accounts

    private func config(_ choices: [ModelChoice], fallback: ModelChoice? = nil) -> RoundConfig {
        let a = choices[0]
        return RoundConfig(drafters: [Slot(a, fallback: fallback)], synthesizer: nil, reviewer: nil, integrator: choices.last!,
                           encoder: a, polisher: nil, refinementCap: 1, polishCap: 0, freshEyesAndDedup: false,
                           defaultPlay: .step, customized: false)
    }

    func testAnOverrideIsResolvedPerRoleAndTheProjectDefaultOnlyWhereSomeSeatUsesIt() {
        let work = AccountChoice.account(UUID())
        let plain = ModelChoice(agent: .codex, model: "gpt-6-sol", effort: "high")
        let pinned = ModelChoice(agent: .claude, model: "opus", effort: "high", account: work)
        let cfg = config([plain, pinned], fallback: ModelChoice(agent: .claude, model: "sonnet", effort: "high", account: .pool("team")))
        XCTAssertEqual(cfg.projectAssignedAgents, [.codex], "claude's seats all hold their own account")
        XCTAssertEqual(cfg.agents, [.codex, .claude], "agents still lists every agent a seat can run")
        XCTAssertEqual(cfg.accountOverrides.map(\.choice.key).sorted(), [work.key, "pool:team"].sorted())
        XCTAssertEqual(Set(cfg.accountOverrides.map(\.agent)), [.claude])
        let dup = config([pinned, pinned])
        XCTAssertEqual(dup.accountOverrides.count, 1, "one resolution per distinct account")
    }

    func testASeatBillsItsOverridesEntryElseItsAgentsAndAMissingEntryIsNil() {
        let work = AccountChoice.account(UUID())
        let project = RunnerAccounts.Entry(accountID: UUID(), home: nil, label: "Personal")
        let own = RunnerAccounts.Entry(accountID: UUID(), home: URL(fileURLWithPath: "/h/work"), label: "Work")
        let accounts = RunnerAccounts(agents: [.claude: project], overrides: [work.key: own])
        XCTAssertEqual(accounts.entry(for: ModelChoice(agent: .claude, model: "m", effort: "")), project)
        XCTAssertEqual(accounts.entry(for: ModelChoice(agent: .claude, model: "m", effort: "", account: work)), own)
        XCTAssertNil(accounts.entry(for: ModelChoice(agent: .claude, model: "m", effort: "", account: .pool("gone"))))
        XCTAssertNil(accounts.entry(for: ModelChoice(agent: .codex, model: "m", effort: "")))
    }

    func testOverrideLeasesAreHeldReleasedAndReadBackWithTheFile() throws {
        let lease = AccountLease(pool: "team", account: AccountRef(agent: .claude, id: UUID(), label: "Work"))
        let pooled = AccountChoice.pool("team")
        let accounts = RunnerAccounts(agents: [:], overrides: [pooled.key: RunnerAccounts.Entry(accountID: nil, home: nil, label: "Team pool",
                                                                                              lease: StoredLease(lease))])
        XCTAssertEqual(accounts.leases, [lease], "a pool override's lease is released with the runner's")
        try accounts.write(to: dir)
        XCTAssertEqual(RunnerAccounts.load(from: dir), accounts)
        // A file from before per-role accounts has no `overrides` key.
        let old = Data(#"{"agents":{}}"#.utf8)
        XCTAssertNil(try IntakeJSON.decoder.decode(RunnerAccounts.self, from: old).overrides)
    }
}
