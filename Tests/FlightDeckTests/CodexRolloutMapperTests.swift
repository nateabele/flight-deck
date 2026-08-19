import XCTest
@testable import FlightDeck

/// Asserted against captured codex output, not against payloads written here. Three of this
/// branch's worst defects were assumptions validated against fixtures their author wrote.
final class CodexRolloutMapperTests: XCTestCase {
    func testACapturedRolloutProducesTheTurnEventsInOrder() throws {
        let events = try CodexRolloutFixtureTests.lines("rollout.captured")
            .flatMap { CodexEventMapper.events(inRolloutLine: $0) }

        // Two complete turns, then one that started and never finished — the approval prompt.
        XCTAssertEqual(events, [
            .activity(.busy), .activity(.idle), .turnEnded,
            .activity(.busy), .activity(.idle), .turnEnded,
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

    func testAnAbortedTurnEndsTheTurnJustLikeACompletedOne() throws {
        let line = try XCTUnwrap(CodexRolloutFixtureTests.lines("turn-aborted").first)
        XCTAssertEqual(CodexEventMapper.events(inRolloutLine: line),
                       [.activity(.idle), .turnEnded])
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
