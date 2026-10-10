import Foundation
import IntakeKit

/// `-FlightDeckRoutingFixture YES`: Settings → Flight Control against fixed data, for
/// `RoutingUITests`. Honored only together with `-FlightDeckResetState YES`, whose nil
/// preferences persistence keeps the run hermetic, so a stray default cannot pose a project.
///
/// Real stores and the real validator; scripted I/O. The kinds and the project's rules are
/// written to a scratch project under the app's own temporary directory (the UI-test runner's
/// sandbox cannot write anywhere the app can read, so the app writes it). The compiler answers
/// from a script, the catalogs are fixed, and neither `br` nor a model ever runs.
@MainActor
enum RoutingUIFixture {
    static var isActive: Bool {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: "FlightDeckResetState") && defaults.bool(forKey: "FlightDeckRoutingFixture")
    }

    static func service(preferences: PreferencesStore,
                        root: URL = FileManager.default.temporaryDirectory
                            .appendingPathComponent("FlightDeck-routing-fixture", isDirectory: true)) -> RoutingService {
        try? FileManager.default.removeItem(at: root)
        let project = root.appendingPathComponent("fixture-project", isDirectory: true)
        try? FileManager.default.createDirectory(at: project.appendingPathComponent(".flightdeck", isDirectory: true),
                                                 withIntermediateDirectories: true)
        try? Data(kindsJSON.utf8).write(to: KindRegistryStore.fileURL(project: project))
        try? Data(routingJSON.utf8).write(to: ProjectRoutingStore.fileURL(project: project))
        var next = 0
        return RoutingService(preferences: preferences, kindStore: KindRegistryStore(),
                              makeCompiler: { FixtureRuleCompiler() },
                              loadCatalogs: { catalogs },
                              pools: DefaultPoolDirectory(agents: [.claude, .codex]),
                              hints: FixtureHints(), tasks: FixtureOpenTasks(), writer: FixtureBlockWriter(),
                              fixtureProjects: [project.path],
                              makeRuleID: { next += 1; return "r\(next)" })
    }

    static var catalogs: AdapterCatalogs {
        AdapterCatalogs([
            AdapterCatalog(agent: .claude, models: ClaudeRoutingCatalog.models, knobSchema: ClaudeRoutingCatalog.knobSchema,
                           defaultModel: "opus", enabled: true),
            AdapterCatalog(agent: .codex,
                           models: [ModelEntry(id: "gpt-6.1-sol", displayName: "GPT-6.1-Sol", knobs: ["effort"]),
                                    ModelEntry(id: "gpt-6-sol", displayName: "GPT-6-Sol", knobs: ["effort"]),
                                    ModelEntry(id: "gpt-6-luna", displayName: "GPT-6-Luna", knobs: ["effort"])],
                           knobSchema: ["effort": ["low", "medium", "high", "xhigh", "max", "ultra"]],
                           defaultModel: "gpt-6.1-sol", enabled: true),
        ])
    }

    /// The same four kinds as L3-0's shared `kinds.json` fixture.
    static let kindsJSON = """
    {"v":1,"kinds":[
     {"id":"tests","name":"Tests","description":"Unit and integration tests","dimensions":{"test-authoring":0.9,"agentic-coding":0.4},"origin":"seed","status":"active","createdAt":"2026-10-04T18:00:00Z"},
     {"id":"snapshot-tests","name":"Snapshot tests","description":"Write or update snapshot/golden-file tests","dimensions":{"test-authoring":0.8,"agentic-coding":0.3},"origin":"planning","status":"active","createdAt":"2026-10-04T18:00:00Z"},
     {"id":"golden-tests","name":"Golden tests","description":"Duplicate of snapshot tests","dimensions":{"test-authoring":0.8},"origin":"planning","status":"merged:snapshot-tests","createdAt":"2026-10-04T18:00:00Z"},
     {"id":"algorithm","name":"Algorithm","description":"Non-trivial algorithms","dimensions":{"algorithmic-reasoning":0.9,"agentic-coding":0.3},"origin":"seed","status":"active","createdAt":"2026-10-04T18:00:00Z"}
    ]}
    """

    static let routingJSON = """
    {"v":1,"rules":[{"id":"p1","sentence":"Use Claude for docs","compiled":{"match":{"any":[{"dimension":"docs-prose","atLeast":0.5}]},"assign":{"harness":"claude","model":"opus","knobs":{},"pool":"claude-default"}},"state":"confirmed","compiledAt":"2026-10-04T18:00:00Z","compiler":{"harness":"claude","model":"haiku"}}]}
    """
}

/// Answers the way a compiler would; the real validator then decides. "teleport" names a
/// dimension that does not exist, which is how the UI test sees a failed rule.
struct FixtureRuleCompiler: RuleCompiling {
    var ref: CompilerRef { CompilerRef(agent: .claude, model: "haiku") }

    func propose(_ input: RuleCompilerInput) async -> RuleProposal {
        func term(_ d: String, _ t: Double) -> RuleCompilerWire.Term { .init(dimension: d, atLeast: t, kind: nil) }
        if input.sentence.localizedCaseInsensitiveContains("teleport") {
            return .wire(RuleCompilerWire(ok: true, reason: nil, mode: "any", terms: [term("teleportation", 0.5)],
                                          harness: "codex", model: "gpt-6-sol", modelDefaulted: false, knobs: [],
                                          pool: nil, fallbackPool: nil))
        }
        // "Sonnet" is the capitalised alias a person types; the catalog lists `sonnet`. The
        // validator's case-only suggestion is what the UI test reads as the actionable failure.
        if input.sentence.localizedCaseInsensitiveContains("sonnet") {
            return .wire(RuleCompilerWire(ok: true, reason: nil, mode: "any", terms: [term("frontend-ui", 0.5)],
                                          harness: "claude", model: "Sonnet", modelDefaulted: false, knobs: [],
                                          pool: nil, fallbackPool: nil))
        }
        if input.sentence.localizedCaseInsensitiveContains("codex") {
            return .wire(RuleCompilerWire(ok: true, reason: nil, mode: "any",
                                          terms: [term("test-authoring", 0.5), term("algorithmic-reasoning", 0.6),
                                                  .init(dimension: nil, atLeast: nil, kind: "tests")],
                                          harness: "codex", model: "gpt-6-sol", modelDefaulted: false,
                                          knobs: [.init(name: "effort", value: "high")], pool: nil, fallbackPool: nil))
        }
        return .unavailable("the fixture compiler has no answer for this sentence")
    }
}

struct FixtureHints: RuleHintSource {
    private static let snapshot = Date(timeIntervalSince1970: 1_790_000_000)
    func hint(for rule: RoutingRule, kinds: [TaskKind], catalogs: AdapterCatalogs) -> RuleHint? {
        // Gone once the rule routes to the suggestion, as the real index's hint would be.
        guard rule.id == "p1", rule.compiled?.assign.model != "gpt-6-luna" else { return nil }
        return RuleHint(ruleID: "p1", text: "gpt-6-luna scores 0.14 higher on docs-prose (confidence 0.8)",
                        snapshotDate: Self.snapshot, suggested: ModelRef(agent: .codex, model: "gpt-6-luna"))
    }
}

struct FixtureOpenTasks: OpenTaskReading {
    func openTasks(project: String) async -> Result<[TaskContextRow], OpenTaskReadError> {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        func row(_ id: String, _ kind: KindID, _ agent: AgentID, _ model: String, _ pool: PoolID) -> TaskContextRow {
            let block = ExecutionBlock(kind: kind, agent: agent, model: model, pool: pool,
                                       source: AssignmentSource(by: .default, reason: "fixture", at: at))
            return TaskContextRow(id: id, agentContext: try? ExecutionBlockCodec.encode(block, into: nil))
        }
        return .success([row("fx-1", "snapshot-tests", .claude, "opus", "claude-default"),
                         row("fx-2", "tests", .codex, "gpt-6-sol", "codex-default")])
    }
}

struct FixtureBlockWriter: BlockWriting {
    func writeBlock(_ block: ExecutionBlock, id: String, project: String) async -> BlockWriteOutcome { .written }
}
