import XCTest
@testable import FlightDeck

@MainActor
final class AgentAccountEnvironmentTests: XCTestCase {
    private func account(_ agent: AgentID) -> AgentAccount {
        AgentAccount(agent: agent, displayName: "Work", home: URL(fileURLWithPath: "/tmp/home"))
    }

    func testEachAgentNamesItsOwnVariable() {
        XCTAssertEqual(ClaudeAdapter().environment(for: account(.claude)), ["CLAUDE_CONFIG_DIR": "/tmp/home"])
        XCTAssertEqual(CodexAdapter(rpc: CodexRPC(transport: NullTransport())).environment(for: account(.codex)),
                       ["CODEX_HOME": "/tmp/home"])
    }

    /// Claude has no shell-level login subcommand — it authenticates inside a running session —
    /// so its invocation is a launch plus an injection, while codex's is a plain command.
    func testLoginInvocationsDifferInShape() {
        XCTAssertEqual(ClaudeAdapter().loginInvocation(for: account(.claude)),
                       LoginInvocation(command: "claude", inject: "/login"))
        XCTAssertEqual(CodexAdapter(rpc: CodexRPC(transport: NullTransport())).loginInvocation(for: account(.codex)),
                       LoginInvocation(command: "codex login", inject: nil))
    }
}

/// `CodexTransport` requires exactly two things — `send(_:)` and `onLine` — so a fake that
/// answers nothing is three lines. `CodexResumeTests` already has richer fakes
/// (`ScriptedTransport`, `SilentTransport`); reuse one of those instead if it is already
/// visible from this file rather than adding a fourth.
final class NullTransport: CodexTransport {
    var onLine: ((String) -> Void)?
    func send(_ line: String) {}
}
