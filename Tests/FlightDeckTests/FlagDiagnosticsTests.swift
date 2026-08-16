import XCTest
@testable import FlightDeck

final class FlagDiagnosticsTests: XCTestCase {
    func testCleanSetHasNoDiagnostics() {
        XCTAssertTrue(FlagDiagnostics.validate(FlagSet(values: ["--model": .value("opus")])).isEmpty)
    }

    func testTmuxWithoutWorktreeWarns() {
        let diagnostics = FlagDiagnostics.validate(FlagSet(values: ["--tmux": .on]))
        XCTAssertTrue(diagnostics.contains { $0.message.contains("--worktree") })
    }

    func testTmuxWithWorktreeStillWarnsAboutTheWorkingDirectory() {
        let flags = FlagSet(values: ["--tmux": .on, "--worktree": .on])
        let diagnostics = FlagDiagnostics.validate(flags)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertTrue(diagnostics[0].message.contains("working directory"))
        XCTAssertFalse(diagnostics.contains { $0.message.contains("requires --worktree") })
    }

    func testSkipPermissionsWarns() {
        let diagnostics = FlagDiagnostics.validate(
            FlagSet(values: ["--dangerously-skip-permissions": .on])
        )
        XCTAssertEqual(diagnostics.first?.severity, .warning)
        XCTAssertTrue(diagnostics.contains { $0.message.contains("permission") })
    }

    /// Both halves of the warning are asserted, because only one of them is true and the
    /// wrong one is easy to reintroduce: the transcript really does follow the worktree
    /// (`claude` names its project directory after its live cwd), while the sidebar
    /// deliberately does not (`SessionStore.applyRegistry` moves a tab only into a project
    /// that is already open). A warning that claimed both would send the user looking for a
    /// row that never moves.
    func testWorktreeWarnsTheTranscriptFollowsButTheTabDoesNot() {
        let diagnostics = FlagDiagnostics.validate(FlagSet(values: ["--worktree": .on]))
        let message = diagnostics.first?.message ?? ""
        XCTAssertTrue(message.contains("working directory"))
        XCTAssertTrue(message.contains("transcript follows the worktree"))
        XCTAssertTrue(message.contains("stays filed under its project"))
    }

    func testDiagnosticsAreOrderStable() {
        let flags = FlagSet(values: ["--tmux": .on, "--dangerously-skip-permissions": .on])
        XCTAssertEqual(FlagDiagnostics.validate(flags), FlagDiagnostics.validate(flags))
    }
}
