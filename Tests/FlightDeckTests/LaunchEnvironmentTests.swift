import XCTest
@testable import FlightDeck

/// Pins the fix for black-and-white Claude tabs: an app relaunched with `open` from inside an
/// agent's tool call inherits that call's environment — codex's `NO_COLOR=1` among it — and
/// passes it on to every tab it launches after.
final class LaunchEnvironmentTests: XCTestCase {
    /// What `open` handed the app when a codex exec inside a Flight Deck claude tab relaunched it
    /// (trimmed from the live process, 2026-10-24).
    private let agentLaunched: [String: String] = [
        "HOME": "/Users/x", "PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8",
        "EDITOR": "cursor", "CLICOLOR": "1",
        "NO_COLOR": "1", "CODEX_CI": "1", "CODEX_THREAD_ID": "01a1", "CODEX_HOME": "/Users/x/.codex",
        "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "46a4", "CLAUDE_CODE_ENTRYPOINT": "cli",
        "CLAUDE_CONFIG_DIR": "/Users/x/.claude-work", "CLAUDE_PID": "68704", "AI_AGENT": "claude-code",
        "FLIGHT_DECK_SESSION_ID": "46A4", "FLIGHTDECK_CLI": "/Applications/x", "FD_OUTLOG_BUDGET": "4",
        "GIT_EDITOR": "true", "GIT_PAGER": "cat", "GH_PAGER": "cat",
    ]

    func testAnAgentLaunchedAppDropsTheAgentsVariables() {
        let strays = Set(LaunchEnvironment.strays(in: agentLaunched))
        XCTAssertEqual(strays, [
            "NO_COLOR", "CODEX_CI", "CODEX_THREAD_ID", "CODEX_HOME", "CLAUDECODE",
            "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CONFIG_DIR", "CLAUDE_PID",
            "AI_AGENT", "FLIGHT_DECK_SESSION_ID", "FLIGHTDECK_CLI", "FD_OUTLOG_BUDGET",
            "GIT_EDITOR", "GIT_PAGER", "GH_PAGER",
        ])
    }

    /// A Dock or Finder launch carries only what the user put in launchd: a `NO_COLOR` there is
    /// theirs, and stays.
    func testAnOrdinaryLaunchKeepsEverything() {
        let env = ["HOME": "/Users/x", "NO_COLOR": "1", "GIT_PAGER": "cat", "CODEX_HOME": "/Users/x/.codex"]
        XCTAssertEqual(LaunchEnvironment.strays(in: env), [])
    }

    func testAnyOneMarkerIsEnough() {
        for marker in ["CLAUDECODE", "CODEX_CI", "CODEX_THREAD_ID", "FLIGHT_DECK_SESSION_ID", "AI_AGENT"] {
            XCTAssertEqual(
                Set(LaunchEnvironment.strays(in: [marker: "1", "NO_COLOR": "1", "HOME": "/x"])),
                [marker, "NO_COLOR"], marker)
        }
    }
}
