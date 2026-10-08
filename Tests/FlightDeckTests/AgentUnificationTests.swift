import XCTest
import IntakeKit
@testable import FlightDeck

/// Unify brief R3/R4: `AgentAdapter` is the one per-agent type and carries the headless profile,
/// and `tabReady` gates every surface that opens a tab. grok and gemini have real adapters now
/// (their own tests are `Grok*Tests` and `GeminiAdapterTests`).
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

    /// grok joined with Track G's adapter (`Grok*Tests`), gemini with Track M's
    /// (`GeminiAdapterTests`).
    func testEveryAgentWithARealAdapterIsTabReady() {
        XCTAssertEqual(AgentID.tabReadyCases, [.claude, .codex, .grok, .gemini])
    }

    /// The seam the gate tests below use — it must reach `tabReadyCases` too, and must not
    /// outlive its scope, or a test's override would leak into the next test.
    func testTheTabReadyOverrideIsScoped() {
        AgentID.$tabReadyOverride.withValue([.claude, .codex]) {
            XCTAssertFalse(AgentID.grok.tabReady)
            XCTAssertEqual(AgentID.tabReadyCases, [.claude, .codex])
        }
        XCTAssertTrue(AgentID.grok.tabReady)
    }

    /// The agent list is the new-tab surface (menus, ⌘N): a stored list naming an agent that
    /// cannot run a tab must not offer it. Every agent can today, so gemini is made the stand-in
    /// through the test seam.
    func testTheNewTabAgentListHoldsTabReadyAgentsOnly() {
        var prefs = Preferences()
        prefs.storedAgents = [AgentSettings(id: .grok, options: .grok(GrokOptions())),
                              AgentSettings(id: .claude, options: .claude(FlagSet())),
                              AgentSettings(id: .gemini, options: .gemini(GeminiOptions()))]
        XCTAssertEqual(prefs.agents.map(\.id), [.grok, .claude, .gemini])
        AgentID.$tabReadyOverride.withValue([.claude, .codex, .grok]) {
            XCTAssertEqual(prefs.agents.map(\.id), [.grok, .claude])
            XCTAssertEqual(NewSessionAffordance.slots(for: prefs.agents).count, 2)
        }
    }

    /// The migration appends any tab-ready agent a stored list lacks — how grok and gemini
    /// appear the launch after their tracks flipped them — and never one that is not ready.
    func testMigrationAddsMissingTabReadyAgentsOnly() {
        var prefs = Preferences(storedAgents: [AgentSettings(id: .codex, options: .codex(CodexThreadOptions()))])
        prefs.migrateAgentsIfNeeded()
        XCTAssertEqual(prefs.storedAgents?.map(\.id), [.codex, .claude, .grok, .gemini], "appended, so no shortcut moves")

        var gated = Preferences(storedAgents: [AgentSettings(id: .codex, options: .codex(CodexThreadOptions()))])
        AgentID.$tabReadyOverride.withValue([.claude, .codex, .grok]) { gated.migrateAgentsIfNeeded() }
        XCTAssertEqual(gated.storedAgents?.map(\.id), [.codex, .claude, .grok])
    }

    /// Routing sends a task to an agent by opening a tab on it.
    func testRoutingTargetsAreTabReadyAgentsOnly() {
        let registry = RoutingCapabilityRegistry.standard()
        XCTAssertEqual(registry.agents, [.claude, .codex, .grok, .gemini])
        AgentID.$tabReadyOverride.withValue([.claude, .codex, .grok]) {
            let gated = RoutingCapabilityRegistry.standard()
            XCTAssertEqual(gated.agents, [.claude, .codex, .grok])
            XCTAssertNil(gated.capabilities(for: .gemini))
        }
    }

    /// The store must answer each agent with that agent's own adapter rather than claude's,
    /// which would launch `claude` in a tab labelled grok.
    func testTheStoreAnswersEachAgentWithItsOwnAdapter() {
        let store = SessionStore(provider: nil, persistence: nil)
        XCTAssertTrue(store.adapter(for: .grok, account: nil) is GrokAdapter)
        XCTAssertTrue(store.adapter(for: .gemini, account: nil) is GeminiAdapter)
        let session = Session(title: "g", workingDirectory: "/tmp", agent: .gemini)
        let adapter = store.adapter(for: .gemini, account: nil)
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

    func testEmptyGrokAndGeminiOptionsRoundTrip() throws {
        for options in [AgentOptions.grok(GrokOptions()), .gemini(GeminiOptions())] {
            XCTAssertEqual(try JSONDecoder().decode(AgentOptions.self, from: JSONEncoder().encode(options)), options)
            XCTAssertTrue(options.isEmpty)
            XCTAssertEqual(AgentOptions.empty(for: options.agent), options)
        }
        // A row written with only the agent name (no payload key) still decodes.
        XCTAssertEqual(try JSONDecoder().decode(AgentOptions.self, from: Data(#"{"agent":"grok"}"#.utf8)), .grok(GrokOptions()))
    }
}
