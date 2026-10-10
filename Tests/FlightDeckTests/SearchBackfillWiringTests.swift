import XCTest
import IntakeKit
@testable import FlightDeck

/// `AppDelegate.startSearch`'s deferred backfill task is not unit-testable directly — it
/// closes over a live `SessionStore` and an `AppDelegate` that owns `GhosttyApp.shared`. These
/// exercise the pure pieces it is built from instead: which refs one pass hands the builder,
/// and whether it hands them at all.
final class SearchBackfillWiringTests: XCTestCase {
    private func ref(
        agent: AgentID, conversationID: String, modified: Date, project: String = "/w/fd"
    ) -> TranscriptRef {
        TranscriptRef(
            url: URL(fileURLWithPath: "/tmp/\(conversationID).jsonl"),
            projectPath: project,
            accountHome: agent.builtInHome,
            workingDirectory: project,
            conversationID: conversationID,
            agent: agent,
            provenance: nil,
            indexedName: nil,
            modified: modified
        )
    }

    /// A corpus that always answers the same fixed list, regardless of what it is asked for —
    /// enough to prove which agents were consulted without a real filesystem walk.
    private struct StubCorpus: AgentSearchCorpus {
        let refs: [TranscriptRef]

        func transcripts(
            forProjects projects: [String], accounts: [AgentAccount]
        ) -> [TranscriptRef] { refs }

        func indexedMessages(
            inLine line: String, conversationID: String, at offset: Int
        ) -> [IndexedMessage] { [] }

        func conversationName(inLines lines: [String], for ref: TranscriptRef) -> ConversationNaming {
            .unknown
        }
    }

    // MARK: - corpusRefs

    /// Every agent contributes to ONE list. Asserted rather than assumed because the
    /// alternative — a build per agent — silently halves the index (see
    /// `SearchIndexBuilderTests.testOneBuildOverBothAgentsPrunesNeither`).
    func testAssemblyAsksEveryAgentAndConcatenates() {
        let claudeRef = ref(agent: .claude, conversationID: "c1", modified: Date(timeIntervalSince1970: 100))
        let codexRef = ref(agent: .codex, conversationID: "x1", modified: Date(timeIntervalSince1970: 50))

        let refs = AppDelegate.corpusRefs(projects: ["/w/fd"], accounts: []) { agent in
            switch agent {
            case .claude: StubCorpus(refs: [claudeRef])
            case .codex: StubCorpus(refs: [codexRef])
            case .grok, .gemini, .opencode: nil
            }
        }

        XCTAssertEqual(Set(refs.map(\.conversationID)), ["c1", "x1"])
    }

    /// Newest first: search becomes useful long before a walk of hundreds of megabytes ends.
    func testAssemblySortsNewestFirstAcrossAgents() {
        let older = ref(agent: .claude, conversationID: "old", modified: Date(timeIntervalSince1970: 10))
        let newer = ref(agent: .codex, conversationID: "new", modified: Date(timeIntervalSince1970: 200))

        let refs = AppDelegate.corpusRefs(projects: ["/w/fd"], accounts: []) { agent in
            switch agent {
            case .claude: StubCorpus(refs: [older])
            case .codex: StubCorpus(refs: [newer])
            case .grok, .gemini, .opencode: nil
            }
        }

        XCTAssertEqual(refs.map(\.conversationID), ["new", "old"])
    }

    /// An agent answering nil contributes nothing and must not abort the others.
    func testAnUnsearchableAgentIsSkipped() {
        let codexRef = ref(agent: .codex, conversationID: "x1", modified: Date(timeIntervalSince1970: 1))

        let refs = AppDelegate.corpusRefs(projects: ["/w/fd"], accounts: []) { agent in
            switch agent {
            case .claude: nil
            case .codex: StubCorpus(refs: [codexRef])
            case .grok, .gemini, .opencode: nil
            }
        }

        XCTAssertEqual(refs.map(\.conversationID), ["x1"])
    }

    // MARK: - backfillPlan

    /// The wipe this whole plan exists to prevent: `SearchIndexBuilder.build([])` prunes with
    /// an empty keep-set, deleting every already-indexed row. Proven by the returned plan
    /// VALUE, not by a mock builder — `startSearch` only ever calls `build` for a `.build`
    /// plan, so a `.skip` here is the same guarantee as "build was not called".
    func testBackfillPlanSkipsRatherThanWipeWhenProjectsExistButDiscoveryIsEmpty() {
        XCTAssertEqual(AppDelegate.backfillPlan(projects: ["/w/fd"], refs: []), .skip)
    }

    /// An empty sidebar has genuinely nothing to keep, so building empty here is correct
    /// rather than the failure `.skip` guards against.
    func testBackfillPlanBuildsEmptyWhenTheSidebarHasNoProjects() {
        XCTAssertEqual(AppDelegate.backfillPlan(projects: [], refs: []), .build([]))
    }

    /// The ordinary case: refs present, build proceeds with exactly them.
    func testBackfillPlanBuildsWithDiscoveredRefs() {
        let discovered = ref(agent: .claude, conversationID: "c1", modified: Date())
        XCTAssertEqual(
            AppDelegate.backfillPlan(projects: ["/w/fd"], refs: [discovered]),
            .build([discovered])
        )
    }

    // MARK: - resolvedAccounts

    /// The common single-login case the old hardcoded account existed for: no accounts
    /// preferences knows about yet, so both agents fall back to their built-in home rather
    /// than the backfill asking nothing.
    func testResolvedAccountsFallsBackToBuiltInHomeForEveryAgentWhenNoneAreLive() {
        let resolved = AppDelegate.resolvedAccounts([])

        XCTAssertEqual(Set(resolved.map(\.agent)), Set(AgentID.allCases))
        for agent in AgentID.allCases {
            XCTAssertEqual(resolved.filter { $0.agent == agent }.map(\.home), [agent.builtInHome])
        }
    }

    /// A real account for one agent is used as-is; the other agent, which `live` says nothing
    /// about, still gets its built-in fallback rather than being left out entirely.
    func testResolvedAccountsPrefersALiveAccountAndStillFillsTheOtherAgent() {
        let customHome = URL(fileURLWithPath: "/Users/me/.claude-work", isDirectory: true)
        let live = AgentAccount(agent: .claude, displayName: "Work", home: customHome)

        let resolved = AppDelegate.resolvedAccounts([live])

        XCTAssertEqual(resolved.filter { $0.agent == .claude }.map(\.home), [customHome])
        XCTAssertEqual(resolved.filter { $0.agent == .codex }.map(\.home), [AgentID.codex.builtInHome])
    }

    /// Two live logins for the same agent both survive — the fallback must not fire just
    /// because one of them exists, and must not collapse the pair to one.
    func testResolvedAccountsKeepsEveryLiveAccountForAnAgentWithMultiple() {
        let first = AgentAccount(agent: .claude, displayName: "Personal", home: AgentID.claude.builtInHome)
        let second = AgentAccount(
            agent: .claude, displayName: "Work",
            home: URL(fileURLWithPath: "/Users/me/.claude-work", isDirectory: true)
        )

        let resolved = AppDelegate.resolvedAccounts([first, second])

        XCTAssertEqual(Set(resolved.filter { $0.agent == .claude }.map(\.id)), [first.id, second.id])
    }
}
