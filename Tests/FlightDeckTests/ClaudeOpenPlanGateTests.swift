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

    // MARK: Widening

    /// A transcript as `TranscriptPager.page(anchor: .latest)` serves it: the last `limit`
    /// lines, and whether anything precedes them.
    private func tail(of lines: [SourceLine]) -> (Int) -> (lines: [SourceLine], hasMore: Bool) {
        { limit in (Array(lines.suffix(limit)), lines.count > limit) }
    }

    /// The live transcript tail of 2026-10-09's "The Plan" (expression-editor), reduced to its
    /// record types: the open `ExitPlanMode` call, the six bookkeeping lines claude writes after
    /// every turn, then two messages queued while the gate was open — a background task's
    /// notification and another session's merge request. Nine lines, so a fixed
    /// `PromptService.tailRecords` (8) window held only the bookkeeping: no call id, no gate,
    /// no banner on the phone, while `PromptService` (which widens) reported the same call open.
    func testAnOpenGateCrowdedOutOfTheFirstWindowIsFoundByWidening() {
        let bookkeeping = [
            #"{"type":"last-prompt","lastPrompt":"ship it","sessionId":"s"}"#,
            #"{"type":"custom-title","customTitle":"The Plan","sessionId":"s"}"#,
            #"{"type":"agent-name","agentName":"The Plan","sessionId":"s"}"#,
            #"{"type":"mode","mode":"normal","sessionId":"s"}"#,
            #"{"type":"permission-mode","permissionMode":"plan","sessionId":"s"}"#,
            #"{"type":"atis-latch","atis":"","sessionId":"s"}"#,
            #"{"type":"queue-operation","operation":"enqueue","content":"<task-notification>done</task-notification>","sessionId":"s"}"#,
            #"{"type":"queue-operation","operation":"enqueue","content":"MERGE REQUEST","sessionId":"s"}"#,
        ]
        let lines = ([exitPlanMode("toolu_PLAN")] + bookkeeping).enumerated()
            .map { line($0.offset * 100, $0.element) }
        XCTAssertEqual(lines.count, PromptService.tailRecords + 1,
                       "the call must sit just outside the first window")
        XCTAssertNil(ClaudeOpenPlanGate.find(in: Array(lines.suffix(PromptService.tailRecords))),
                     "precondition: the fixed first window cannot see the call")

        XCTAssertEqual(ClaudeOpenPlanGate.find(tail: tail(of: lines)), "toolu_PLAN")
    }

    /// The first window answers the common case with one read, and an answered gate stays
    /// closed however far back the reader looks.
    func testWideningReadsOnceWhenTheFirstWindowFindsTheCall() {
        var reads: [Int] = []
        let lines = [line(0, exitPlanMode("toolu_PLAN"))]
        let found = ClaudeOpenPlanGate.find { limit in
            reads.append(limit)
            return (lines, false)
        }
        XCTAssertEqual(found, "toolu_PLAN")
        XCTAssertEqual(reads, [PromptService.tailRecords])
    }

    /// Nothing to find terminates — on `hasMore` false, and on a wider read that returned no
    /// more lines than the last — rather than climbing to the ceiling on every registry tick.
    func testWideningStopsWhenTheFileRunsOut() {
        let lines = (0..<20).map { line($0 * 100, #"{"type":"mode","mode":"normal"}"#) }
        var reads = 0
        XCTAssertNil(ClaudeOpenPlanGate.find { limit in
            reads += 1
            return tail(of: lines)(limit)
        })
        XCTAssertEqual(reads, 2, "8 lines with more above, then all 20 with none")

        var stalled = 0
        XCTAssertNil(ClaudeOpenPlanGate.find { _ in
            stalled += 1
            return (Array(lines.prefix(5)), true)
        })
        XCTAssertEqual(stalled, 2, "a wider read that grew nothing cannot find more")
    }
}
