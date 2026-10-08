import XCTest
import IntakeKit
@testable import FlightDeck

/// Unify brief R3/R4 and the P0 stubs: `AgentAdapter` is the one per-agent type and carries the
/// headless profile; grok and gemini exist with stub adapters but stay off every surface that
/// opens a tab until their tracks flip `tabReady`.
@MainActor
final class AgentUnificationTests: XCTestCase {
    // MARK: R3 — the headless facet

    /// The app reaches each agent's profile through its adapter, the runner through
    /// `AgentProfiles`; they must be the same answers, or behaviour lives in two places.
    func testEveryAdapterCarriesItsAgentsProfile() {
        let adapters: [(AgentID, any AgentProfile)] = [
            (ClaudeAdapter.id, ClaudeAdapter.profile), (CodexAdapter.id, CodexAdapter.profile),
            (GrokAdapter.id, GrokAdapter.profile), (GeminiAdapter.id, GeminiAdapter.profile),
        ]
        XCTAssertEqual(adapters.map(\.0), AgentID.allCases)
        for (id, profile) in adapters {
            XCTAssertEqual(profile.id, id)
            XCTAssertEqual(profile.binaryName, AgentProfiles.profile(for: id).binaryName)
            XCTAssertEqual(id.profile.id, id)
        }
    }

    // MARK: R4 — tab readiness

    /// gemini joined when Track M's adapter passed its suite (`GeminiAdapterTests`).
    func testOnlyAgentsWithARealAdapterAreTabReady() {
        XCTAssertEqual(AgentID.tabReadyCases, [.claude, .codex, .gemini])
    }

    /// The agent list is the new-tab surface (menus, ⌘N): a stored list naming a stub agent must
    /// not offer it.
    func testTheNewTabAgentListHoldsTabReadyAgentsOnly() {
        var prefs = Preferences()
        prefs.storedAgents = [AgentSettings(id: .grok, options: .grok(GrokOptions())),
                              AgentSettings(id: .claude, options: .claude(FlagSet())),
                              AgentSettings(id: .gemini, options: .gemini(GeminiOptions()))]
        XCTAssertEqual(prefs.agents.map(\.id), [.claude, .gemini])
        XCTAssertEqual(NewSessionAffordance.slots(for: prefs.agents).count, 2)
    }

    /// The migration appends any tab-ready agent a stored list lacks — how grok appears the
    /// launch after Track G flips it — and never a stub one.
    func testMigrationAddsMissingTabReadyAgentsOnly() {
        var prefs = Preferences(storedAgents: [AgentSettings(id: .codex, options: .codex(CodexThreadOptions()))])
        prefs.migrateAgentsIfNeeded()
        XCTAssertEqual(prefs.storedAgents?.map(\.id), [.codex, .claude, .gemini], "appended, so no shortcut moves")
    }

    /// Routing sends a task to an agent by opening a tab on it.
    func testRoutingTargetsAreTabReadyAgentsOnly() {
        let registry = RoutingCapabilityRegistry.standard()
        XCTAssertEqual(registry.agents, [.claude, .codex, .gemini])
        XCTAssertNil(registry.capabilities(for: .grok))
    }

    // MARK: Stubs

    /// Every optional capability is the stated refusal, not a claude-shaped default.
    func testStubAdaptersRefuseEveryOptionalCapability() {
        for agent in [AgentID.grok] {
            XCTAssertNil(agent.textChannel, "\(agent)")
            XCTAssertNil(agent.renameTyping, "\(agent)")
            XCTAssertNil(agent.dialogDriver, "\(agent)")
            XCTAssertNil(agent.turnRecovery, "\(agent)")
            XCTAssertNil(agent.openPromptReader, "\(agent)")
            XCTAssertNil(agent.searchCorpus, "\(agent)")
            XCTAssertNil(agent.exitCommand, "\(agent)")
            XCTAssertFalse(agent.hasStatusRegistry, "\(agent)")
            XCTAssertTrue(agent.timelineItems(inLine: #"{"type":"user"}"#, at: 0).isEmpty)
        }
    }

    func testStubRoutingCapabilitiesAreUnsupported() async {
        for caps in [GrokRoutingCapabilities() as any AgentRoutingCapabilities] {
            let catalog = await caps.modelCatalog()
            XCTAssertNil(catalog.value, "\(caps.agent)")
        }
    }

    /// A hand-edited `sessions.json` can name a stub agent; the store must answer it with that
    /// agent's own stub rather than claude's adapter, which would launch `claude` in a tab
    /// labelled grok.
    func testTheStoreAnswersAStubAgentWithItsOwnAdapter() {
        let store = SessionStore(provider: nil, persistence: nil)
        XCTAssertTrue(store.adapter(for: .grok, account: nil) is GrokAdapter)
        XCTAssertTrue(store.adapter(for: .gemini, account: nil) is GeminiAdapter)
        let session = Session(title: "g", workingDirectory: "/tmp", agent: .grok)
        let adapter = store.adapter(for: .grok, account: nil)
        XCTAssertEqual(adapter.launchCommand(adapter.binding(for: session), session, .grok(GrokOptions())), "grok")
        XCTAssertNil(adapter.binding(for: session).transcriptURL)
    }

    /// Gemini has no home variable (keychain login), so binding an account sets nothing — a
    /// made-up variable would be set on every launch and bind nothing.
    func testGeminiBindsNoHomeVariableAndGrokBindsGrokHome() {
        XCTAssertNil(AgentID.gemini.homeEnvironmentKey)
        XCTAssertEqual(AgentID.grok.homeEnvironmentKey, "GROK_HOME")
        let gemini = AgentAccount(agent: .gemini, displayName: "G", home: AgentID.gemini.builtInHome)
        XCTAssertEqual(GeminiAdapter().environment(for: gemini), [:])
        let grok = AgentAccount(agent: .grok, displayName: "K", home: URL(fileURLWithPath: "/tmp/grok-k"))
        XCTAssertEqual(GrokAdapter().environment(for: grok)["GROK_HOME"], "/tmp/grok-k")
    }

    func testStubOptionsRoundTripAndAreEmpty() throws {
        for options in [AgentOptions.grok(GrokOptions()), .gemini(GeminiOptions())] {
            XCTAssertEqual(try JSONDecoder().decode(AgentOptions.self, from: JSONEncoder().encode(options)), options)
            XCTAssertTrue(options.isEmpty)
            XCTAssertEqual(AgentOptions.empty(for: options.agent), options)
        }
        // A row written with only the agent name (no payload key) still decodes.
        XCTAssertEqual(try JSONDecoder().decode(AgentOptions.self, from: Data(#"{"agent":"grok"}"#.utf8)), .grok(GrokOptions()))
    }
}
