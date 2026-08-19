import XCTest
@testable import FlightDeck

final class CodexEventMapperTests: XCTestCase {
    private func fixture(_ key: String) throws -> [String: Any] {
        // No fallback to a subdirectory-less lookup: that would silently resolve a
        // differently-scoped fixture if one ever existed elsewhere in the bundle (later
        // tasks are expected to add `Fixtures/<Adapter>/` siblings). Fail loudly instead of
        // matching ambiguously.
        //
        // `notifications.schema-derived` and not `notifications`: the file is built from
        // codex's generated schema, and the name says so because the version it replaced
        // claimed to be captured from a live codex and was not. See its `_provenance`.
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "notifications.schema-derived", withExtension: "json",
                subdirectory: "Fixtures/Codex"
            ),
            "Fixtures/Codex/notifications.schema-derived.json not found in the test bundle"
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

        // Two live agents: one `running`, one `pendingInit`. `pendingInit` is an agent that
        // has been spawned but has not started — it was missing from `liveStates` entirely,
        // so a freshly spawned agent read as already finished.
        XCTAssertEqual(
            CodexEventMapper.events(method: "item/started", params: try fixture("spawnTwo"), state: &state),
            [.subagentCount(2)]
        )
        // `agentsStates` is recorded flattened to id -> status, dropping `CollabAgentState`'s
        // optional `message`.
        XCTAssertEqual(state.subagents, ["sub-a": "running", "sub-b": "pendingInit"])
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

    /// Every terminal `CollabAgentStatus` counts as finished.
    ///
    /// The list is exhaustive over the non-live half of `CollabAgentStatus` — `interrupted`,
    /// `completed`, `errored`, `shutdown`, `notFound` — so adding a live state without
    /// thinking about this one breaks here.
    func testEveryTerminalCollabAgentStatusReadsAsFinished() throws {
        var state = CodexThreadState()
        XCTAssertEqual(
            CodexEventMapper.events(
                method: "item/completed", params: try fixture("everyTerminalState"), state: &state
            ),
            [.subagentCount(0)]
        )
    }

    func testANonCollabItemIsNotMistakenForASubagentUpdate() {
        var state = CodexThreadState()
        let params: [String: Any] = [
            "threadId": "01a01269-baa6-7493-8d15-8fa21bcb602b", "turnId": "t1",
            "startedAtMs": 1, "item": ["type": "agentMessage", "id": "m1", "text": "hi"],
        ]
        XCTAssertTrue(CodexEventMapper.events(method: "item/started", params: params, state: &state).isEmpty)
    }

    /// The whole `ThreadStatus` union, through the notification path.
    ///
    /// The pre-fix table mapped `running`/`busy` — neither of which is in the protocol —
    /// and had no case for `active` at all, so the one status that means "this thread is
    /// working" produced no event. See `CodexThreadStatus`.
    func testThreadStatusChangedMapsEveryRealStatus() throws {
        var state = CodexThreadState()
        let cases: [(String, [AgentEvent])] = [
            ("statusIdle", [.activity(.idle)]),
            ("statusActive", [.activity(.busy)]),
            ("statusActiveWaitingOnApproval", [.activity(.waiting)]),
            ("statusSystemError", [.activity(.idle)]),
            // `notLoaded` is an absence of information — every restored tab sees it — so it
            // must not overwrite what is already known.
            ("statusNotLoaded", []),
        ]
        for (key, expected) in cases {
            XCTAssertEqual(
                CodexEventMapper.events(
                    method: "thread/status/changed", params: try fixture(key), state: &state
                ),
                expected, "fixture \(key)"
            )
        }
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
