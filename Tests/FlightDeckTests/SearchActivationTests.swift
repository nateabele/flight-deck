import XCTest
@testable import FlightDeck

/// What pressing Return on a result means, decided as a value before anything is launched.
///
/// Pure so the rules are testable without spawning an agent: launching is `SessionStore`'s
/// job, deciding is this type's.
final class SearchActivationTests: XCTestCase {
    private func result(
        kind: SearchResultKind, conversation: String? = nil, project: String = "/w/fd"
    ) -> SearchResult {
        SearchResult(
            id: "r", kind: kind, title: "t", projectName: "fd", projectPath: project,
            tier: .exact, recency: .distantPast, highlightedRanges: [], snippet: nil,
            conversationID: conversation
        )
    }

    func testASessionResultSelectsItsTab() {
        let id = UUID()
        let activation = SearchActivation.plan(
            for: result(kind: .session(id)), openSessions: [], projects: ["/w/fd"]
        )

        XCTAssertEqual(activation, .select(id))
    }

    /// Re-resuming a conversation that already has a tab would start a second `claude` on
    /// the same conversation — two processes writing one transcript, which is the collision
    /// the app's pid-keyed registry cannot survive.
    func testAConversationThatAlreadyHasATabSelectsItRatherThanResuming() {
        let tab = UUID()
        let activation = SearchActivation.plan(
            for: result(kind: .conversation("c1"), conversation: "c1"),
            openSessions: [SearchActivation.ActiveSession(id: tab, conversationID: "c1")],
            projects: ["/w/fd"]
        )

        XCTAssertEqual(activation, .select(tab))
    }

    func testAConversationWithNoTabResumesIntoItsProject() {
        let activation = SearchActivation.plan(
            for: result(kind: .conversation("c1"), conversation: "c1"),
            openSessions: [], projects: ["/w/fd"]
        )

        XCTAssertEqual(activation, .resume(
            conversationID: "c1", projectPath: "/w/fd", transcriptDirectory: "/w/fd"
        ))
    }

    /// The user asked for this explicitly: opening a result reopens its project if it is no
    /// longer in the sidebar.
    func testAConversationWhoseProjectHasLeftTheSidebarBringsTheProjectBack() {
        let activation = SearchActivation.plan(
            for: result(kind: .conversation("c1"), conversation: "c1", project: "/w/gone"),
            openSessions: [], projects: ["/w/fd"]
        )

        XCTAssertEqual(activation, .addProjectThenResume(
            projectPath: "/w/gone", conversationID: "c1", transcriptDirectory: "/w/gone"
        ))
    }

    /// A worktree conversation must resume where claude actually wrote it. Resuming it in
    /// the project root would point the tab's watcher at a transcript nothing writes to,
    /// silently losing title sync and subagent counts — the failure `Session.transcriptDirectory`
    /// exists to prevent.
    func testAWorktreeConversationResumesInItsWorktreeDirectory() {
        var worktree = result(kind: .conversation("c1"), conversation: "c1")
        worktree = SearchResult(
            id: worktree.id, kind: worktree.kind, title: worktree.title,
            projectName: worktree.projectName, projectPath: "/w/fd",
            tier: worktree.tier, recency: worktree.recency,
            highlightedRanges: [], snippet: nil, conversationID: "c1"
        )

        let activation = SearchActivation.plan(
            for: worktree, openSessions: [], projects: ["/w/fd"],
            transcriptDirectory: "/w/fd/.claude/worktrees/fleet-pairing"
        )

        XCTAssertEqual(activation, .resume(
            conversationID: "c1", projectPath: "/w/fd",
            transcriptDirectory: "/w/fd/.claude/worktrees/fleet-pairing"
        ))
    }
}
