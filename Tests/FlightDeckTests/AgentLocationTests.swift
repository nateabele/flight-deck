import XCTest
@testable import FlightDeck

/// The seam that keeps claude's path derivation out of the tools subsystem. These tests pin
/// that a location is the ADAPTER's answer — not a field read — which is what makes a third
/// agent able to disagree.
@MainActor
final class AgentLocationTests: XCTestCase {
    private func session(cwd: String, live: String) -> Session {
        Session(title: "w", workingDirectory: cwd, transcriptDirectory: live)
    }

    func testDefaultReportsTheAgentsLiveDirectoryNotTheFiledProject() {
        // A worktree is the case that separates the two: the tab stays filed under the
        // project, but the agent is working somewhere else and that is where a tool goes.
        let s = session(cwd: "/w/a", live: "/w/a/.claude/worktrees/tools")
        XCTAssertEqual(
            ClaudeAdapter().location(for: s).workingDirectory,
            "/w/a/.claude/worktrees/tools"
        )
    }

    func testDefaultCarriesTheAdaptersOwnBinding() {
        let adapter = ClaudeAdapter()
        let s = session(cwd: "/w/a", live: "/w/a")
        XCTAssertEqual(adapter.location(for: s).binding, adapter.binding(for: s),
                       "a location must not invent a second identity rule")
    }

    func testAnAdapterMayOverrideTheDefault() {
        // The whole point of the seam: an agent whose cwd is not `transcriptDirectory` has
        // somewhere to say so. Without an override point this would be a field read.
        let s = session(cwd: "/w/a", live: "/w/a")
        XCTAssertEqual(RelocatingAdapter().location(for: s).workingDirectory, "/elsewhere")
    }

    /// Mirrors `ClaudeAdapter` with only `location` replaced.
    private struct RelocatingAdapter: AgentAdapter {
        static let id: AgentID = .claude
        func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
            binding(for: session)
        }
        func binding(for session: Session) -> AgentBinding {
            AgentBinding(conversationID: session.pinnedConversationID, transcriptURL: nil)
        }
        func location(for session: Session) -> AgentLocation {
            AgentLocation(workingDirectory: "/elsewhere", binding: binding(for: session))
        }
        func launchCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "" }
        func resumeCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "" }
        func rename(_: AgentBinding, to: String) async throws {}
    }
}
