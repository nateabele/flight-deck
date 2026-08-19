import XCTest
@testable import FlightDeck

final class CodexEventMapperTests: XCTestCase {
    private func fixture(_ key: String) throws -> [String: Any] {
        // No fallback to a subdirectory-less lookup: that would silently resolve a
        // differently-scoped `notifications.json` if one ever existed elsewhere in the
        // bundle (later tasks are expected to add `Fixtures/<Adapter>/` siblings). Fail
        // loudly instead of matching ambiguously.
        let url = try XCTUnwrap(
            Bundle(for: Self.self)
                .url(forResource: "notifications", withExtension: "json", subdirectory: "Fixtures/Codex"),
            "Fixtures/Codex/notifications.json not found in the test bundle"
        )
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

    func testSubagentCountTreatsUnfamiliarStateAsNotLive() throws {
        var state = CodexThreadState()

        // "quiescing" is not in `liveStates` — an unfamiliar value must read as finished so
        // it can never pin the spinner on. Only "sub-a" (running) should count.
        XCTAssertEqual(
            CodexEventMapper.events(
                method: "item/started", params: try fixture("spawnWithUnfamiliarState"), state: &state
            ),
            [.subagentCount(1)]
        )
    }

    func testThreadStatusChangedMapsKnownStatusToActivity() throws {
        var state = CodexThreadState()
        XCTAssertEqual(
            CodexEventMapper.events(
                method: "thread/status/changed", params: try fixture("statusRunning"), state: &state
            ),
            [.activity(.busy)]
        )
    }

    func testThreadStatusChangedIgnoresUnrecognizedStatus() throws {
        var state = CodexThreadState()
        // An unrecognized status must not overwrite a known activity with a guess — it
        // produces nothing, explicitly not `.idle` or `.busy`.
        XCTAssertEqual(
            CodexEventMapper.events(
                method: "thread/status/changed", params: try fixture("statusUnrecognized"), state: &state
            ),
            []
        )
    }

    func testUnrelatedNotificationsProduceNothing() {
        var state = CodexThreadState()
        XCTAssertTrue(CodexEventMapper.events(
            method: "mcpServer/startupStatus/updated", params: [:], state: &state
        ).isEmpty)
    }
}
