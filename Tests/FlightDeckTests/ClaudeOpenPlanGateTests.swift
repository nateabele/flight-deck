import FleetKit
import XCTest
@testable import FlightDeck

/// `ClaudeOpenPlanGate.find` had zero coverage before this file — the CRITICAL fix that gave
/// plan gates a `FleetEvent` left this derivation exactly as untested as it found it. These
/// tests are modeled on `ClaudeOpenCallTests`, which is the sibling derivation for dialogs, and
/// deliberately probe the one place the two disagree: this walks *past* a newer unanswered
/// call that is not `ExitPlanMode`, where `OpenPrompt.find` would stop there and report it.
final class ClaudeOpenPlanGateTests: XCTestCase {
    private func line(_ offset: Int, _ json: String) -> SourceLine {
        SourceLine(offset: offset, text: json)
    }

    private func exitPlanMode(_ id: String, plan: String = "# Plan") -> String {
        """
        {"type":"assistant","timestamp":"2026-08-21T04:30:59.425Z","message":{"role":\
        "assistant","content":[{"type":"tool_use","id":"\(id)","name":"ExitPlanMode",\
        "input":{"plan":"\(plan)"}}]}}
        """
    }

    private func bash(_ id: String, command: String = "ls") -> String {
        """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use",\
        "id":"\(id)","name":"Bash","input":{"command":"\(command)"}}]}}
        """
    }

    /// Hand-written for the same reason `ClaudeOpenCallTests.answer` is: claude writes the
    /// call record before the tool runs, so a `tool_result` for an `ExitPlanMode` call means
    /// the plan was decided (approved or denied) and the gate this call opened is closed.
    private func answer(_ id: String) -> String {
        """
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result",\
        "tool_use_id":"\(id)","content":"done"}]}}
        """
    }

    func testAnUnansweredExitPlanModeIsFound() {
        XCTAssertEqual(
            ClaudeOpenPlanGate.find(in: [line(0, exitPlanMode("toolu_PLAN"))]),
            "toolu_PLAN"
        )
    }

    func testAnAnsweredExitPlanModeIsNotOpen() {
        let lines = [
            line(0, exitPlanMode("toolu_PLAN")),
            line(100, answer("toolu_PLAN")),
        ]
        XCTAssertNil(ClaudeOpenPlanGate.find(in: lines))
    }

    /// The behavior that sets this apart from `OpenPrompt.find`, pinned rather than left
    /// implicit. A newer unanswered call that is not `ExitPlanMode` does not hide an older
    /// open gate — `find` keeps scanning past it — because `ExitPlanMode` blocks the tool loop
    /// until it resolves, so this can only be a sibling from the same blocked turn, never a
    /// call claude went on to make afterward. `OpenPrompt.find` would stop at `toolu_NEWER` and
    /// report it instead; this must not.
    func testANewerUnansweredNonExitPlanModeCallDoesNotHideAnOlderOpenGate() {
        let lines = [
            line(0, exitPlanMode("toolu_PLAN")),
            line(100, bash("toolu_NEWER")),
        ]
        XCTAssertEqual(ClaudeOpenPlanGate.find(in: lines), "toolu_PLAN")
    }

    func testAnEmptyWindowFindsNothing() {
        XCTAssertNil(ClaudeOpenPlanGate.find(in: []))
    }
}
