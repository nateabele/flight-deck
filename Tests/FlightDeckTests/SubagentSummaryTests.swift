import XCTest
@testable import FleetKit

/// Shared presentation keeps the list glyph and timeline header consistent when a runtime
/// supplies a count. Zero stays silent, including when an older runtime supplies no count.
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

    func testOpenCodeReportsItsCount() {
        XCTAssertEqual(session(agent: "opencode", subagents: 1).subagentSummary, "1 subagent")
        XCTAssertEqual(session(agent: "opencode", subagents: 2).subagentSummary, "2 subagents")
        XCTAssertNil(session(agent: "opencode", subagents: 0).subagentSummary)
    }

    func testCodexAtZeroSaysNothing() {
        XCTAssertNil(session(agent: "codex", subagents: 0).subagentSummary)
    }

    func testCodexReportsItsCount() {
        XCTAssertEqual(session(agent: "codex", subagents: 4).subagentSummary, "4 subagents")
    }

    func testCodexSingularizesAtOne() {
        XCTAssertEqual(session(agent: "codex", subagents: 1).subagentSummary, "1 subagent")
    }

    /// Unknown agents stay silent until this build understands their count semantics.
    func testAnUnknownAgentSaysNothing() {
        XCTAssertNil(session(agent: "goose", subagents: 0).subagentSummary)
        XCTAssertNil(session(agent: "goose", subagents: 2).subagentSummary)
    }
}
