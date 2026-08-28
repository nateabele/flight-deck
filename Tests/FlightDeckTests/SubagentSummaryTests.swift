import XCTest
@testable import FleetKit

/// The one place the sub-agent asymmetry is decided, so the list glyph and the timeline
/// header cannot disagree about it.
///
/// Spec §6 says "a count for claude, per-sub-agent for codex". The code says the reverse:
/// `TranscriptWatcher` counts claude's outstanding top-level `Agent` tool calls, while
/// `CodexEventMapper` states that no `collab` record exists in any surveyed rollout and that
/// `subagentCount` is deliberately never emitted for codex. Re-checked across 494 rollouts
/// on the build machine: still nothing.
///
/// **So a codex tab's `0` means unknown, not none**, and saying "0 subagents" would assert a
/// fact nobody has. That is the whole point of this file.
final class SubagentSummaryTests: XCTestCase {
    private func session(agent: String, subagents: Int) -> WireSession {
        WireSession(id: UUID(), title: "t", agent: agent, activity: "busy",
                    subagentCount: subagents)
    }

    func testClaudeReportsItsCount() {
        XCTAssertEqual(session(agent: "claude", subagents: 3).subagentSummary, "3 subagents")
    }

    func testClaudeSingularizesAtOne() {
        XCTAssertEqual(session(agent: "claude", subagents: 1).subagentSummary, "1 subagent")
    }

    func testClaudeAtZeroSaysNothingBecauseThereReallyAreNone() {
        XCTAssertNil(session(agent: "claude", subagents: 0).subagentSummary)
    }

    /// The load-bearing case. Codex has no sub-agent ground truth at all, so the honest
    /// answer is silence — never "0 subagents", which would claim none are running when the
    /// truth is that nobody knows.
    func testCodexSaysNothingEvenAtZero() {
        XCTAssertNil(session(agent: "codex", subagents: 0).subagentSummary)
    }

    /// And nothing at a non-zero count either. Nothing produces one today; if something
    /// starts to, this fails and whoever changed it has to decide what codex's count MEANS
    /// before it reaches a screen.
    func testCodexSaysNothingAtANonZeroCountEither() {
        XCTAssertNil(session(agent: "codex", subagents: 4).subagentSummary)
    }

    /// An agent this build has never heard of gets the same silence for the same reason:
    /// `WireSession.agent` is a String precisely so a newer Mac's agent renders without a
    /// glyph rather than taking the snapshot down, and inventing a count for it would be the
    /// same mistake as inventing one for codex.
    func testAnUnknownAgentSaysNothing() {
        XCTAssertNil(session(agent: "goose", subagents: 2).subagentSummary)
    }
}
