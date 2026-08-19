import XCTest
@testable import FlightDeck

final class CodexEventMapperTests: XCTestCase {
    private func fixture(_ key: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: Self.self)
            .url(forResource: "notifications", withExtension: "json", subdirectory: "Fixtures/Codex")
            ?? Bundle(for: Self.self).url(forResource: "notifications", withExtension: "json"))
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        return try XCTUnwrap(root[key] as? [String: Any])
    }

    func testNameUpdatedBecomesATitleEvent() throws {
        var state = CodexThreadState()
        let events = CodexEventMapper.events(
            method: "thread/name/updated", params: try fixture("nameUpdated"), state: &state
        )
        XCTAssertEqual(events, [.title("flight-deck spike")])
    }

    func testTurnStartedAndCompletedDriveActivityAndTurnEnd() throws {
        var state = CodexThreadState()
        XCTAssertEqual(
            CodexEventMapper.events(method: "turn/started", params: try fixture("turnStarted"), state: &state),
            [.activity(.busy)]
        )
        // `.turnEnded` is what `SessionReadPolicy` marks unread from, so it must accompany idle.
        XCTAssertEqual(
            CodexEventMapper.events(method: "turn/completed", params: try fixture("turnCompleted"), state: &state),
            [.activity(.idle), .turnEnded]
        )
    }

    func testSubagentCountIsRecomputedFromAgentsStates() throws {
        var state = CodexThreadState()

        XCTAssertEqual(
            CodexEventMapper.events(method: "item/started", params: try fixture("spawnTwo"), state: &state),
            [.subagentCount(2)]
        )
        // Recomputed from the payload's own map, not decremented. `agentsStates` carries the
        // full current state every time, so the count cannot drift and needs no turn-boundary
        // clearing — which is exactly the fragile part of claude's `outstandingAgents`.
        XCTAssertEqual(
            CodexEventMapper.events(method: "item/completed", params: try fixture("oneFinished"), state: &state),
            [.subagentCount(1)]
        )
    }

    func testUnrelatedNotificationsProduceNothing() {
        var state = CodexThreadState()
        XCTAssertTrue(CodexEventMapper.events(
            method: "mcpServer/startupStatus/updated", params: [:], state: &state
        ).isEmpty)
    }
}
