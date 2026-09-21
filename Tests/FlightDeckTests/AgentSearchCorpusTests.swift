import XCTest
@testable import FlightDeck

/// The capability is reached through `AgentID`, never off an adapter instance — the backfill
/// runs from `AppDelegate.startSearch`, which has no adapters and no live account stacks.
@MainActor
final class AgentSearchCorpusTests: XCTestCase {
    /// Every agent must answer. A `nil` here is a legitimate answer ("not searchable"), but
    /// it must be a *decision* — this asserts the switch is exhaustive by exercising every
    /// case, which is what fails to compile when a third `AgentID` is added without one.
    func testEveryAgentAnswersTheCapability() {
        for agent in AgentID.allCases {
            _ = agent.searchCorpus
        }
    }

    /// Placeholder ids are a value type, so this pins the shape the rest of the plan builds on.
    func testTranscriptRefCarriesAttributionAndProvenance() {
        let ref = TranscriptRef(
            url: URL(fileURLWithPath: "/tmp/rollout.jsonl"),
            projectPath: "/w/fd",
            accountHome: URL(fileURLWithPath: "/home/.codex"),
            workingDirectory: "/w/fd/.claude/worktrees/x",
            conversationID: "abc",
            agent: .codex,
            provenance: "exec",
            indexedName: "session 206",
            modified: Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(ref.provenance, "exec")
        XCTAssertEqual(ref.workingDirectory, "/w/fd/.claude/worktrees/x")
        XCTAssertNotEqual(ref.workingDirectory, ref.projectPath)
    }
}
