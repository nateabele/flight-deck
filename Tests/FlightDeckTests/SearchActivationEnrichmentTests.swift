// Tests/FlightDeckTests/SearchActivationEnrichmentTests.swift
import XCTest
import FleetKit
@testable import FlightDeck

/// `AppDelegate.startSearch`'s onSelect closure is not unit-testable directly — it closes
/// over a live `SessionStore` and the `SQLiteSearchIndex` it just opened. This exercises the
/// pure piece it is built from: filling a name match's location from the index before
/// `SearchActivation.plan` ever sees it.
final class SearchActivationEnrichmentTests: XCTestCase {
    private func result(
        kind: SearchResultKind = .conversation("c1"), conversation: String? = "c1",
        agent: String = "codex", workingDirectory: String = "", transcriptPath: String = ""
    ) -> SearchResult {
        SearchResult(
            id: "r", kind: kind, title: "t", projectName: "fd", projectPath: "/w/fd",
            tier: .exact, recency: .distantPast, highlightedRanges: [], snippet: nil,
            conversationID: conversation, agent: agent, workingDirectory: workingDirectory,
            transcriptPath: transcriptPath
        )
    }

    /// The bug itself: a codex conversation matched by NAME, not by transcript content,
    /// carries empty `workingDirectory`/`transcriptPath` straight out of `SearchCandidates.build`.
    /// Without this lookup, `CodexAdapter.binding(for:)` sees no rollout and types a bare
    /// `codex`, starting an unrelated thread while the tab stays pinned to the conversation
    /// that was searched for.
    func testACodexNameMatchIsEnrichedWithTheIndexsRecordedLocation() {
        let enriched = AppDelegate.enrichedForActivation(result(agent: "codex")) { conversationID in
            XCTAssertEqual(conversationID, "c1")
            return (workingDirectory: "/w/fd/.codex/worktrees/x", transcriptPath: "/rollouts/c1.jsonl", agent: "codex")
        }

        XCTAssertEqual(enriched.workingDirectory, "/w/fd/.codex/worktrees/x")
        XCTAssertEqual(enriched.transcriptPath, "/rollouts/c1.jsonl")
    }

    /// A conversation the index genuinely has no row for — never indexed, or indexed before
    /// these fields existed — must stay empty rather than surface a lookup failure as a
    /// fabricated path; `SessionStore.openConversation`'s project-root fallback is what
    /// handles this case, not this function.
    func testANameMatchTheIndexCannotLocateStaysEmpty() {
        let enriched = AppDelegate.enrichedForActivation(result()) { _ in nil }

        XCTAssertEqual(enriched.workingDirectory, "")
        XCTAssertEqual(enriched.transcriptPath, "")
    }

    /// A transcript hit already carries both fields from the corpus walk itself — the lookup
    /// must not run at all, or a stale index read could silently override what the walk just
    /// read live.
    func testATranscriptHitWithBothFieldsAlreadySetIsNotReLookedUp() {
        var consulted = false
        let hit = result(workingDirectory: "/w/fd/worktree", transcriptPath: "/rollouts/c1.jsonl")

        let enriched = AppDelegate.enrichedForActivation(hit) { _ in
            consulted = true
            return (workingDirectory: "/somewhere/else", transcriptPath: "/somewhere/else.jsonl", agent: "codex")
        }

        XCTAssertFalse(consulted, "a result with both fields already known must not trigger a lookup")
        XCTAssertEqual(enriched.workingDirectory, "/w/fd/worktree")
        XCTAssertEqual(enriched.transcriptPath, "/rollouts/c1.jsonl")
    }

    /// A project row carries no conversation id at all — there is nothing to look up, and
    /// the guard on `conversationID` is what keeps this from crashing on a nil key.
    func testAProjectResultWithNoConversationIsLeftAlone() {
        var consulted = false
        let project = result(kind: .project, conversation: nil)

        let enriched = AppDelegate.enrichedForActivation(project) { _ in
            consulted = true
            return nil
        }

        XCTAssertFalse(consulted)
        XCTAssertEqual(enriched.workingDirectory, "")
        XCTAssertEqual(enriched.transcriptPath, "")
    }
}
