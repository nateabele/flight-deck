import XCTest
import IntakeKit
@testable import FlightDeck

/// A hand-off agent reads the old agent's transcript from wherever the old agent's account wrote
/// it. These pin that the pointer is the very file Flight Deck already tails for that tab — the
/// worktree-following directory for claude, the reported rollout for codex — and that a file
/// that is not on disk yields no pointer, so the prompt says "not available" instead of sending
/// the new agent to read nothing.
final class TranscriptPointersTests: XCTestCase {
    func testClaudePointsAtTheTailedTranscriptUnderTheAccountHome() throws {
        let conversation = UUID(uuidString: "8552ADC8-BBAE-48C2-9B86-29A5BECFA369")!
        var s = Session(title: "t", workingDirectory: "/p/proj", pinnedConversationID: conversation)
        s.transcriptDirectory = "/p/proj/.claude/worktrees/feat"
        let root = URL(fileURLWithPath: "/Users/n/.claude-work/projects", isDirectory: true)
        let p = try XCTUnwrap(TranscriptPointers.claude(session: s, projectsRoot: root, exists: { _ in true }))
        XCTAssertEqual(p.locator, .path("/Users/n/.claude-work/projects/-p-proj--claude-worktrees-feat/8552adc8-bbae-48c2-9b86-29a5becfa369.jsonl"))
        XCTAssertEqual(p.format, TranscriptPointers.claudeFormat)
        XCTAssertTrue(p.howToRead.contains("last 200 lines"))
    }

    func testClaudeWithNoFileOnDiskHasNoPointer() {
        let s = Session(title: "t", workingDirectory: "/p/proj")
        XCTAssertNil(TranscriptPointers.claude(session: s, projectsRoot: URL(fileURLWithPath: "/nope"), exists: { _ in false }))
    }

    func testCodexPointsAtTheReportedRollout() throws {
        let s = Session(title: "t", workingDirectory: "/p", agent: .codex, transcriptPath: "/Users/n/.codex/sessions/2026/10/04/rollout-x.jsonl")
        let p = try XCTUnwrap(TranscriptPointers.codex(session: s, exists: { _ in true }))
        XCTAssertEqual(p.locator, .path("/Users/n/.codex/sessions/2026/10/04/rollout-x.jsonl"))
        XCTAssertEqual(p.format, TranscriptPointers.codexFormat)
    }

    func testCodexWithoutAReportedPathHasNoPointer() {
        XCTAssertNil(TranscriptPointers.codex(session: Session(title: "t", workingDirectory: "/p", agent: .codex), exists: { _ in true }))
        XCTAssertNil(TranscriptPointers.codex(session: Session(title: "t", workingDirectory: "/p", agent: .codex, transcriptPath: "/gone.jsonl"),
                                              exists: { _ in false }))
    }

    /// The tab's mirror (`OpenCodeMirror`), a plain JSONL file — not `opencode export` (which
    /// reads the built-in account's data unless `XDG_DATA_HOME` is set) nor the server's message
    /// endpoint (which needs the account's server password).
    func testOpenCodePointsAtTheTabsMirror() {
        let session = Session(title: "t", workingDirectory: "/p", agent: .opencode, transcriptPath: "/m/ses_1.jsonl")
        let p = TranscriptPointers.openCode(session: session, exists: { _ in true })
        XCTAssertEqual(p?.locator, .path("/m/ses_1.jsonl"))
        XCTAssertEqual(p?.format, TranscriptPointers.openCodeFormat)
        XCTAssertNil(TranscriptPointers.openCode(session: session, exists: { _ in false }))
        XCTAssertNil(TranscriptPointers.openCode(session: Session(title: "t", workingDirectory: "/p", agent: .opencode),
                                                 exists: { _ in true }))
    }
}
