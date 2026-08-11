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

    func testTmuxWithWorktreeIsClean() {
        let flags = FlagSet(values: ["--tmux": .on, "--worktree": .on])
        XCTAssertTrue(FlagDiagnostics.validate(flags).isEmpty)
    }

    func testSkipPermissionsWarns() {
        let diagnostics = FlagDiagnostics.validate(
            FlagSet(values: ["--dangerously-skip-permissions": .on])
        )
        XCTAssertEqual(diagnostics.first?.severity, .warning)
        XCTAssertTrue(diagnostics.contains { $0.message.contains("permission") })
    }

    func testWorktreeWarnsThatTheWorkingDirectoryMoves() {
        let diagnostics = FlagDiagnostics.validate(FlagSet(values: ["--worktree": .on]))
        XCTAssertTrue(diagnostics.contains { $0.message.contains("working directory") })
    }

    func testDiagnosticsAreOrderStable() {
        let flags = FlagSet(values: ["--tmux": .on, "--dangerously-skip-permissions": .on])
        XCTAssertEqual(FlagDiagnostics.validate(flags), FlagDiagnostics.validate(flags))
    }
}
