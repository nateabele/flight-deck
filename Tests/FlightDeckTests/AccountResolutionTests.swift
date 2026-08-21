import XCTest
@testable import FlightDeck

@MainActor
final class AccountResolutionTests: XCTestCase {
    private func store(_ accounts: [AgentAccount], projects: [String: ProjectSettings] = [:]) -> PreferencesStore {
        let store = PreferencesStore(persistence: nil)
        store.preferences.storedAccounts = accounts
        store.preferences.storedProjectSettings = projects
        return store
    }

    private func account(_ agent: AgentID, _ name: String) -> AgentAccount {
        AgentAccount(agent: agent, displayName: name, home: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    func testAProjectWithNoChoiceGetsTheTopAccount() {
        let top = account(.claude, "top"), other = account(.claude, "other")
        XCTAssertEqual(store([top, other]).account(for: .claude, project: "/p")?.id, top.id)
    }

    func testAnExplicitAssignmentWins() {
        let top = account(.claude, "top"), chosen = account(.claude, "chosen")
        let store = store([top, chosen], projects: ["/p": ProjectSettings(accounts: [.claude: chosen.id])])
        XCTAssertEqual(store.account(for: .claude, project: "/p")?.id, chosen.id)
    }

    /// The rule that must never soften. A dangling id resolves to nothing, not to the top
    /// account — resuming under the wrong login would find no conversation and start a fresh one.
    func testADanglingAssignmentIsBrokenNotAFallback() {
        let top = account(.claude, "top")
        let store = store([top], projects: ["/p": ProjectSettings(accounts: [.claude: UUID()])])
        XCTAssertNil(store.account(for: .claude, project: "/p"))
    }

    func testANilSessionAccountNormalisesToTheBuiltInAccount() {
        let builtIn = AgentAccount(agent: .claude, displayName: "Default", home: AgentID.claude.builtInHome)
        let store = store([account(.claude, "first"), builtIn])
        XCTAssertEqual(store.resolvedAccountID(for: .claude, in: nil), builtIn.id,
                       "nil means the built-in home, never merely the topmost account")
    }

    func testProjectOptionsOverrideGlobalPerAgentAndSurviveTheDefaultAgentBeingUnset() {
        let store = store([account(.codex, "c")], projects: [
            "/p": ProjectSettings(defaultAgent: nil, options: [.codex: .codex(CodexThreadOptions(sandbox: "read-only"))])
        ])
        store.preferences.agents = [
            AgentSettings(id: .codex, options: .codex(CodexThreadOptions(model: "gpt-5")))
        ]
        guard case .codex(let merged) = store.resolvedOptions(for: .codex, project: "/p") else {
            return XCTFail("expected codex options")
        }
        XCTAssertEqual(merged.model, "gpt-5")
        XCTAssertEqual(merged.sandbox, "read-only")
    }

    func testAgentOrderPromotesTheProjectDefaultAndKeepsTheRestGlobal() {
        let store = store([])
        store.preferences.agents = [
            AgentSettings(id: .claude, options: .claude(FlagSet())),
            AgentSettings(id: .codex, options: .codex(CodexThreadOptions())),
        ]
        store.preferences.projectSettings["/p"] = ProjectSettings(defaultAgent: .codex)
        XCTAssertEqual(store.agentOrder(forProject: "/p").map(\.id), [.codex, .claude])
        XCTAssertEqual(store.agentOrder(forProject: "/other").map(\.id), [.claude, .codex])
    }

    func testTwoAccountsMayNotShareAHome() {
        let existing = account(.claude, "a")
        let store = store([existing])
        XCTAssertTrue(store.homeIsTaken(existing.home, excluding: nil))
        XCTAssertFalse(store.homeIsTaken(existing.home, excluding: existing.id))
    }

    func testRemovingAnAccountClearsProjectsThatReferencedIt() {
        let doomed = account(.claude, "doomed"), keep = account(.claude, "keep")
        let store = store([keep, doomed], projects: ["/p": ProjectSettings(accounts: [.claude: doomed.id])])
        store.markAccountRemoved(id: doomed.id)
        XCTAssertNil(store.preferences.projectSettings["/p"], "the record became empty and was dropped")
        XCTAssertEqual(store.preferences.accounts(for: .claude).map(\.id), [keep.id],
                       "a tombstone still stores; it is the LIST that must drop it")
    }

    /// Feeds `NewSessionAffordance.menu`'s checkmark: one entry per agent that has a
    /// resolvable account, and an agent this project cannot resolve at all — the dangling
    /// case above — is simply absent, not mapped to some placeholder id.
    func testResolvedAccountsMapsEachAgentToWhatItWouldLaunchHereToday() {
        let claudeTop = account(.claude, "claude-top"), codexTop = account(.codex, "codex-top")
        let claudeChosen = account(.claude, "claude-chosen")
        let store = store(
            [claudeTop, codexTop, claudeChosen],
            projects: ["/p": ProjectSettings(accounts: [.claude: claudeChosen.id, .codex: UUID()])]
        )
        let agents = [
            AgentSettings(id: .claude, options: .claude(FlagSet())),
            AgentSettings(id: .codex, options: .codex(CodexThreadOptions())),
        ]

        let resolved = store.resolvedAccounts(for: agents, project: "/p")

        XCTAssertEqual(resolved[.claude], claudeChosen.id, "the project's own assignment wins")
        XCTAssertNil(resolved[.codex], "a dangling assignment resolves to nothing, not a guess")
    }
}
