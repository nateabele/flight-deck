import XCTest
@testable import FlightDeck

/// Asserted against captured codex output, not against payloads written here. Three of this
/// branch's worst defects were assumptions validated against fixtures their author wrote.
final class CodexRolloutMapperTests: XCTestCase {
    func testACapturedRolloutProducesTheTurnEventsInOrder() throws {
        let events = try CodexRolloutFixtureTests.lines("rollout.captured")
            .flatMap { CodexEventMapper.events(inRolloutLine: $0) }

        // Two complete turns, then one that started and never finished — the approval prompt.
        // Both completions are clean, so each now also clears any standing error.
        XCTAssertEqual(events, [
            .activity(.busy), .activity(.idle), .turnEnded, .apiError(nil),
            .activity(.busy), .activity(.idle), .turnEnded, .apiError(nil),
            .activity(.busy),
        ])
    }

    /// The tail of that sequence is a user-visible limitation, not an oversight: codex writes
    /// nothing when it starts waiting on approval, so the tab stays busy. See the spec's §5.
    func testAnApprovalPromptLeavesTheThreadLookingBusy() throws {
        let events = try CodexRolloutFixtureTests.lines("rollout.captured")
            .flatMap { CodexEventMapper.events(inRolloutLine: $0) }
        XCTAssertEqual(events.last, .activity(.busy))
        XCTAssertFalse(events.contains(.activity(.waiting)),
                       "nothing in a rollout can justify .waiting; inferring it from a "
                       + "tool call with no output is a guess this app does not make")
    }

    /// No `collab` record exists in any of 492 surveyed rollouts, so `.subagentCount` has no
    /// ground truth for codex and the mapper must never emit it. Nothing would fail today if
    /// a count were reintroduced without evidence — this pins the absence.
    func testNoSubagentCountIsEverEmittedForCodex() throws {
        let events = try CodexRolloutFixtureTests.lines("rollout.captured")
            .flatMap { CodexEventMapper.events(inRolloutLine: $0) }
        XCTAssertFalse(events.contains { if case .subagentCount = $0 { return true } else { return false } },
                       "codex has no rollout evidence for sub-agent counts; the mapper must "
                       + "not invent one")
    }

    func testAnAbortedTurnEndsTheTurnJustLikeACompletedOne() throws {
        let line = try XCTUnwrap(CodexRolloutFixtureTests.lines("turn-aborted.captured").first)
        XCTAssertEqual(CodexEventMapper.events(inRolloutLine: line),
                       [.activity(.idle), .turnEnded, .turnAborted])
    }

    /// Captured driving a real codex TUI at an upstream returning 429 (codex-cli 0.155.1).
    /// The error rides as a FIELD on `task_complete`, not as a record type of its own.
    func testTaskCompleteWithAnErrorEmitsAnAPIError() {
        let line = #"""
        {"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":null,"error":{"message":"exceeded retry limit, last status: 429 Too Many Requests","codex_error_info":{"response_too_many_failed_attempts":{"http_status_code":429}}}}}
        """#
        let events = CodexEventMapper.events(inRolloutLine: line)
        guard case .apiError(let error)? = events.first(where: {
            if case .apiError = $0 { return true } else { return false }
        }) else { return XCTFail("no apiError emitted: \(events)") }
        XCTAssertEqual(error?.status, 429)
        XCTAssertEqual(error?.kind, "response_too_many_failed_attempts")
        XCTAssertTrue(error?.isTransient == true)
        // The turn still ended; the existing contract must not regress.
        XCTAssertTrue(events.contains(.turnEnded))
        XCTAssertTrue(events.contains(.activity(.idle)))
    }

    func testACleanTaskCompleteClearsAnyStandingError() {
        let line = #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"done"}}"#
        XCTAssertTrue(CodexEventMapper.events(inRolloutLine: line).contains(.apiError(nil)))
    }

    /// A user interrupt is not an API failure, and must not clear or set one — the last turn
    /// really did fail and the badge is still true. It is reported as an interrupt instead,
    /// which is what stops the retry loop without touching the badge.
    func testTurnAbortedTouchesTheErrorNotAtAllAndReportsTheInterrupt() {
        let line = #"{"type":"event_msg","payload":{"type":"turn_aborted"}}"#
        let events = CodexEventMapper.events(inRolloutLine: line)
        XCTAssertFalse(events.contains { if case .apiError = $0 { return true } else { return false } })
        XCTAssertTrue(events.contains(.turnEnded))
        XCTAssertTrue(events.contains(.turnAborted),
                      "without this the user pressing Esc on a nudge stops nothing: the "
                      + "schedule stays armed and the next rung types again")
    }

    /// A permanent failure is still reported — the badge is right — it simply will not retry.
    func testAPermanentErrorIsReportedAsNonTransient() {
        let line = #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","error":{"message":"nope","codex_error_info":{"unauthorized":{}}}}}"#
        guard case .apiError(let error)? = CodexEventMapper.events(inRolloutLine: line).first(where: {
            if case .apiError = $0 { return true } else { return false }
        }) else { return XCTFail("no apiError emitted") }
        XCTAssertEqual(error?.kind, "unauthorized")
        XCTAssertFalse(error?.isTransient == true)
    }

    func testNonEventRecordsAndGarbageProduceNothing() throws {
        let responseItem = #"{"type":"response_item","payload":{"type":"message"}}"#
        XCTAssertEqual(CodexEventMapper.events(inRolloutLine: responseItem), [])
        XCTAssertEqual(CodexEventMapper.events(inRolloutLine: "not json at all"), [])
        XCTAssertEqual(CodexEventMapper.events(inRolloutLine: ""), [])
        // A record shape codex adds later must be ignored, not crashed on.
        XCTAssertEqual(
            CodexEventMapper.events(inRolloutLine: #"{"type":"event_msg","payload":{"type":"invented"}}"#),
            []
        )
    }
}
