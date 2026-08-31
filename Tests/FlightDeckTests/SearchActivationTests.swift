import XCTest
import FleetKit
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
        let conversation = UUID()
        let activation = SearchActivation.plan(
            for: result(kind: .conversation(conversation.uuidString.lowercased()),
                        conversation: conversation.uuidString.lowercased()),
            openSessions: [SearchActivation.ActiveSession(id: tab, conversationID: conversation)],
            projects: ["/w/fd"]
        )

        XCTAssertEqual(activation, .select(tab))
    }

    /// The bug this guards: `UUID.uuidString` is uppercase, and a `SearchResult`'s
    /// conversation id is a lowercase transcript filename stem. A caller filling
    /// `ActiveSession` straight from `pinnedConversationID.uuidString` (no `.lowercased()`)
    /// must still match — comparing as `UUID` rather than as a raw string is what makes that
    /// true no matter which case either side started from.
    func testAConversationThatAlreadyHasATabMatchesRegardlessOfUUIDStringCase() {
        let tab = UUID()
        let conversation = UUID()
        // Built from the uppercase string, exactly as a caller filling `ActiveSession`
        // straight from `session.pinnedConversationID.uuidString` would, with no
        // `.lowercased()` anywhere.
        let openSession = SearchActivation.ActiveSession(
            id: tab, conversationID: UUID(uuidString: conversation.uuidString.uppercased())!
        )

        let activation = SearchActivation.plan(
            // The lowercase transcript filename stem `SearchResult.conversationID` actually
            // carries.
            for: result(kind: .conversation(conversation.uuidString.lowercased()),
                        conversation: conversation.uuidString.lowercased()),
            openSessions: [openSession], projects: ["/w/fd"]
        )

        XCTAssertEqual(activation, .select(tab))
    }

    func testAConversationWithNoTabResumesIntoItsProject() {
        let activation = SearchActivation.plan(
            for: result(kind: .conversation("c1"), conversation: "c1"),
            openSessions: [], projects: ["/w/fd"]
        )

        XCTAssertEqual(activation, .resume(
            conversationID: "c1", projectPath: "/w/fd", title: "t", transcriptDirectory: "/w/fd"
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
            projectPath: "/w/gone", conversationID: "c1", title: "t", transcriptDirectory: "/w/gone"
        ))
    }

    /// `plan` passes `transcriptDirectory` straight through when given one; it is not, on
    /// its own, proof that a worktree conversation resumes correctly in production, since
    /// production wiring has no way to compute this value and always leaves it `nil` — see
    /// `SessionStore`'s `resolvedTranscriptDirectory`, which is where the real answer comes
    /// from. This only pins the pass-through shape `plan` promises to a caller that does
    /// have one, e.g. a test.
    func testAKnownTranscriptDirectoryPassesThroughUnchanged() {
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
            conversationID: "c1", projectPath: "/w/fd", title: "t",
            transcriptDirectory: "/w/fd/.claude/worktrees/fleet-pairing"
        ))
    }

    /// Opening a conversation that already has a tab selects it rather than starting a
    /// second `--resume` against a live transcript — two processes appending one file. This
    /// is the branch `FleetService.openConversation` relies on for a phone's `search.open`.
    func testOpenConversationSelectsAnExistingTab() {
        let tab = UUID()
        let conversation = UUID()
        let result = SearchResult(
            id: "conversation:\(conversation.uuidString.lowercased())",
            kind: .conversation(conversation.uuidString.lowercased()),
            title: "auth refactor",
            projectName: "proj",
            projectPath: "/proj",
            tier: .transcript,
            recency: Date(timeIntervalSince1970: 1),
            highlightedRanges: [],
            snippet: "the rename path",
            conversationID: conversation.uuidString.lowercased()
        )

        let plan = SearchActivation.plan(
            for: result,
            openSessions: [.init(id: tab, conversationID: conversation)],
            projects: ["/proj"]
        )

        XCTAssertEqual(plan, .select(tab))
    }
}
