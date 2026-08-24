import XCTest
@testable import FlightDeck

/// The seam that keeps an agent's path derivation out of the tools subsystem. `location(for:)`
/// is a REQUIRED protocol member with no default implementation — each adapter states its own
/// answer, so a third agent whose cwd is not `transcriptDirectory` has somewhere to say so, and
/// the compiler, not a default, is what stops a new adapter from silently inheriting the wrong
/// directory.
@MainActor
final class AgentLocationTests: XCTestCase {
    private func session(cwd: String, live: String) -> Session {
        Session(title: "w", workingDirectory: cwd, transcriptDirectory: live)
    }

    func testClaudeReportsTheAgentsLiveDirectoryNotTheFiledProject() {
        // A worktree is the case that separates the two: the tab stays filed under the
        // project, but the agent is working somewhere else and that is where a tool goes.
        let s = session(cwd: "/w/a", live: "/w/a/.claude/worktrees/tools")
        XCTAssertEqual(
            ClaudeAdapter().location(for: s).workingDirectory,
            "/w/a/.claude/worktrees/tools"
        )
    }

    func testClaudeCarriesItsOwnBinding() {
        let adapter = ClaudeAdapter()
        let s = session(cwd: "/w/a", live: "/w/a")
        XCTAssertEqual(adapter.location(for: s).binding, adapter.binding(for: s),
                       "a location must not invent a second identity rule")
    }

    func testEachAdapterStatesItsOwnAnswerRatherThanSharingOne() {
        // The property the seam exists for: two adapters given the SAME session must be free
        // to disagree about where the agent is working. A shared default (extension method or
        // a base-class field read) could not let `RelocatingAdapter` diverge from
        // `ClaudeAdapter` the way this asserts it does.
        let s = session(cwd: "/w/a", live: "/w/a/.claude/worktrees/tools")
        XCTAssertEqual(
            ClaudeAdapter().location(for: s).workingDirectory,
            "/w/a/.claude/worktrees/tools"
        )
        XCTAssertEqual(RelocatingAdapter().location(for: s).workingDirectory, "/elsewhere")
    }

    /// Mirrors `ClaudeAdapter` with only `location` replaced.
    private struct RelocatingAdapter: AgentAdapter {
        static let id: AgentID = .claude
        /// Claude's answers, because this stands in for claude — the store reads both
        /// capabilities off `AgentID`, so a stub that disagreed would describe an agent that
        /// does not exist.
        static let textChannel: AgentTextChannel? = ClaudeTextChannel()
        static let dialogDriver: AgentDialogDriver? = ClaudeDialogDriver()
        static let negotiatesIdentity = false
        static let needsRuntimeStart = false
        static let hasStatusRegistry = true
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
        func loginInvocation(for account: AgentAccount) -> LoginInvocation { LoginInvocation(command: "", inject: nil) }
    }

    func testCodexReportsTheAgentsLiveDirectoryAndItsOwnBinding() {
        // Codex also uses transcriptDirectory as its working directory: prepare passes it as
        // the thread's own cwd, and launchCommand requires the pty to spawn there.
        let transport = MinimalCodexTransport()
        let adapter = CodexAdapter(rpc: CodexRPC(transport: transport))
        let s = session(cwd: "/w/a", live: "/w/a/.claude/worktrees/tools")
        let location = adapter.location(for: s)

        XCTAssertEqual(location.workingDirectory, "/w/a/.claude/worktrees/tools")
        XCTAssertEqual(location.binding, adapter.binding(for: s),
                       "location must carry the adapter's own binding")
    }

    /// Minimal transport that doesn't respond to anything — location(for:) doesn't make RPC calls.
    private class MinimalCodexTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        func send(_: String) {}
    }
}
