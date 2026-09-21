import XCTest
@testable import FlightDeck

@MainActor
final class AgentAccountEnvironmentTests: XCTestCase {
    private func account(_ agent: AgentID) -> AgentAccount {
        AgentAccount(agent: agent, displayName: "Work", home: URL(fileURLWithPath: "/tmp/home"))
    }

    func testEachAgentNamesItsOwnVariable() {
        // Claude also carries FLIGHT_DECK_EVENT_DIR, folded in from
        // `ClaudeAdapter.launchEnvironment` — which codex has no equivalent of, since only
        // claude's plugin writes hook events. That this reaches a *launched* session is a
        // separate fact with its own test: `AccountLaunchTests`. This file only pins the
        // adapter's answer.
        // Built from a hand-written literal, not `ClaudePluginLocation.eventDirectory`
        // itself: mirroring the production call would only catch a wrong key on the
        // adapter's side, never a wrong path inside `eventDirectory`.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let expectedEventDir = base
            .appendingPathComponent("Flight Deck", isDirectory: true)
            .appendingPathComponent("hook-events-debug", isDirectory: true)
            .path
        XCTAssertEqual(
            ClaudeAdapter().environment(for: account(.claude)),
            [
                "CLAUDE_CONFIG_DIR": "/tmp/home",
                "FLIGHT_DECK_EVENT_DIR": expectedEventDir,
            ]
        )
        XCTAssertEqual(CodexAdapter(rpc: CodexRPC(transport: NullTransport())).environment(for: account(.codex)),
                       ["CODEX_HOME": "/tmp/home"])
    }

    /// The account-free half, which is the half the launch path actually uses: a tab whose
    /// login was deleted is launched with no account at all and must still report its
    /// lifecycle. Codex takes the empty default — its readiness comes from rollout evidence
    /// on disk, which needs nothing in the child's environment.
    func testTheAccountFreeLaunchEnvironmentCarriesOnlyClaudesHookDirectory() {
        XCTAssertEqual(ClaudeAdapter().launchEnvironment,
                       ["FLIGHT_DECK_EVENT_DIR": ClaudePluginLocation.eventDirectory.path])
        XCTAssertEqual(CodexAdapter(rpc: CodexRPC(transport: NullTransport())).launchEnvironment, [:])
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
