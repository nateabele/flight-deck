import XCTest
import IntakeKit

/// The swarm reads four br outputs and joins them. These pin the join's order — the scheduler's
/// rank first, then priority — and the two rules the Review Focus calls out: a ranked task that is
/// not ready is dropped, and `br ready`'s rows carry no `agent_context`, so blocks come from
/// `br list` (probed, br 0.6.0).
final class SwarmTaskDecodingTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures/FlightControlL3/Swarm")))
    }

    func testReadyRowsDecodeBareArray() throws {
        let rows = try XCTUnwrap(SwarmTaskDecoding.readyRows(fixture("br-ready")))
        XCTAssertEqual(rows.map(\.id), ["fx-a", "fx-b", "fx-c"])
        XCTAssertEqual(rows.map(\.priority), [1, 2, 0])
    }

    func testSchedulerRanksByIssueID() throws {
        let ranks = try XCTUnwrap(SwarmTaskDecoding.schedulerRanks(fixture("br-scheduler")))
        XCTAssertEqual(ranks, ["fx-b": 1, "fx-z": 2, "fx-a": 3])
    }

    func testSchedulerRefusesAnotherSchemaMajor() {
        XCTAssertNil(SwarmTaskDecoding.schedulerRanks(Data(#"{"schema":"br.scheduler.v2","recommendations":[]}"#.utf8)))
    }

    func testListContextsAcceptEnvelopeAndBareArray() throws {
        let contexts = try XCTUnwrap(SwarmTaskDecoding.listContexts(fixture("br-list-open")))
        XCTAssertNotNil(contexts["fx-a"])
        XCTAssertNil(contexts["fx-b"], "a row with no agent_context has no entry")
        XCTAssertEqual(contexts["fx-c"], #"{"instructions":"keep"}"#)
        let bare = try XCTUnwrap(SwarmTaskDecoding.listContexts(Data(#"[{"id":"x","agent_context":"{}"}]"#.utf8)))
        XCTAssertEqual(bare, ["x": "{}"])
    }

    func testJoinOrdersByRankThenPriorityAndDropsRankedButNotReady() throws {
        let tasks = SwarmTaskDecoding.join(
            ready: try XCTUnwrap(SwarmTaskDecoding.readyRows(fixture("br-ready"))),
            ranks: try XCTUnwrap(SwarmTaskDecoding.schedulerRanks(fixture("br-scheduler"))),
            contexts: try XCTUnwrap(SwarmTaskDecoding.listContexts(fixture("br-list-open"))))
        XCTAssertEqual(tasks.map(\.id), ["fx-b", "fx-a", "fx-c"], "fx-z is ranked but not ready")
        XCTAssertEqual(tasks.map(\.rank), [1, 3, nil])
        XCTAssertEqual(try tasks[1].block.get()?.model, "gpt-6-sol")
        XCTAssertNil(try tasks[0].block.get(), "no agent_context is no block")
    }

    func testJoinWithoutRanksFallsBackToPriority() throws {
        let tasks = SwarmTaskDecoding.join(ready: try XCTUnwrap(SwarmTaskDecoding.readyRows(fixture("br-ready"))),
                                           ranks: [:], contexts: [:])
        XCTAssertEqual(tasks.map(\.id), ["fx-c", "fx-a", "fx-b"])
    }

    func testDetailReadsArrayOrObject() throws {
        let d = try XCTUnwrap(SwarmTaskDecoding.detail(fixture("br-show")))
        XCTAssertEqual(d, TaskDetail(id: "fx-a", title: "Add snapshot tests",
                                     description: "Cover the parser with snapshot tests.",
                                     acceptance: "- every fixture has a snapshot\n- CI passes",
                                     status: "in_progress", assignee: "BlueLake"))
        XCTAssertEqual(SwarmTaskDecoding.detail(Data(#"{"id":"x","title":"t","status":"open"}"#.utf8))?.description, "")
    }

    func testClaimOutcome() throws {
        let conflict = String(decoding: try fixture("br-claim-conflict"), as: UTF8.self)
        XCTAssertEqual(SwarmTaskDecoding.claimOutcome(exitCode: 0, stdout: "{}"), .claimed)
        XCTAssertEqual(SwarmTaskDecoding.claimOutcome(exitCode: 1, stdout: conflict), .conflict)
        XCTAssertEqual(SwarmTaskDecoding.claimOutcome(exitCode: 3, stdout: "boom\nmore"), .failed("exit 3: boom"))
    }
}
