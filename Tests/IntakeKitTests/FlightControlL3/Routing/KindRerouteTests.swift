import XCTest
import IntakeKit

/// When a kind is merged or re-weighted, its open, unpinned tasks are re-routed (spec L3-R §5).
/// The plan is pure; the router is L3-0's `FakeRouter`, so these pin only what gets re-routed.
final class KindRerouteTests: XCTestCase {
    private typealias D = RoutingTestData
    private let project = URL(fileURLWithPath: "/w/project", isDirectory: true)

    private func row(_ id: String, kind: KindID, agent: AgentID = .claude, model: String = "opus",
                     knobs: [String: String] = [:], pool: PoolID = "claude-default", pinned: Bool = false) throws -> TaskContextRow {
        let b = ExecutionBlock(kind: kind, agent: agent, model: model, knobs: knobs, pool: pool,
                               source: AssignmentSource(by: .default, reason: "r", at: D.at), pinned: pinned)
        return TaskContextRow(id: id, agentContext: try ExecutionBlockCodec.encode(b, into: #"{"instructions":"keep"}"#))
    }

    private func codexAssignment() -> Assignment {
        Assignment(block: ExecutionBlock(
            kind: "x", agent: .codex, model: "gpt-6-sol", knobs: ["effort": "high"], pool: "codex-default",
            source: AssignmentSource(by: .rule, ruleId: "r3", reason: "test-authoring 0.8 → codex", at: D.at)))
    }

    /// Scripts every kind these tests route: the unscripted-call guard in `FakeRouter` fails loudly.
    private func codexRouter() -> FakeRouter {
        let r = FakeRouter()
        r.defaultAssignment = codexAssignment()
        return r
    }

    private func plan(_ rows: [TaskContextRow], affected: KindID, router: FakeRouter) -> KindReroute.Plan {
        KindReroute.plan(rows: rows, affected: affected, project: project, kinds: D.kinds, router: router, catalogs: D.catalogs, now: D.at)
    }

    func testOnlyUnpinnedTasksOfTheAffectedKindAreReRouted() throws {
        let r = codexRouter()
        let p = plan([try row("t1", kind: "snapshot-tests"), try row("t2", kind: "snapshot-tests", pinned: true),
                      try row("t3", kind: "algorithm")], affected: "snapshot-tests", router: r)
        XCTAssertEqual(p.changes.map(\.id), ["t1"])
        XCTAssertEqual(p.changes.first?.block.kind, "snapshot-tests", "the task keeps its own kind")
        XCTAssertEqual(p.changes.first?.block.agent, .codex)
        XCTAssertEqual(p.skippedPinned, ["t2"])
        XCTAssertEqual(r.assignCalls, ["snapshot-tests"], "a pinned task is never even routed")
    }

    func testKindsMergedIntoTheAffectedKindComeAlong() throws {
        let p = plan([try row("t1", kind: "golden-tests")], affected: "snapshot-tests", router: codexRouter())
        XCTAssertEqual(p.changes.map(\.id), ["t1"])
        XCTAssertEqual(p.changes.first?.block.kind, "golden-tests")
    }

    func testAnUnchangedAssignmentIsNotRewritten() throws {
        let same = try row("t1", kind: "snapshot-tests", agent: .codex, model: "gpt-6-sol", knobs: ["effort": "high"], pool: "codex-default")
        XCTAssertEqual(plan([same], affected: "snapshot-tests", router: codexRouter()).changes, [])
    }

    func testInvalidBlocksAreReportedNotRepaired() {
        let p = plan([TaskContextRow(id: "t9", agentContext: #"{"flight_deck":{"execution":{"v":1,"kind":"snapshot-tests"}}}"#),
                      TaskContextRow(id: "t0", agentContext: nil)], affected: "snapshot-tests", router: FakeRouter())
        XCTAssertEqual(p.invalid, ["t9": "missing harness"])
        XCTAssertEqual(p.changes, [])
    }

    func testAnUnroutableTaskIsReported() throws {
        let r = FakeRouter()
        r.assignments["snapshot-tests"] = Assignment.unroutable(kind: "snapshot-tests",
                                                                reason: "no enabled agent has a model and a pool", at: D.at)
        let p = plan([try row("t1", kind: "snapshot-tests")], affected: "snapshot-tests", router: r)
        XCTAssertEqual(p.unroutable, ["t1": "unroutable: no enabled agent has a model and a pool"])
        XCTAssertEqual(p.changes, [])
    }

    func testBrListParsesTheEnvelopeAndABareArray() throws {
        let rows = try TaskContextRow.parse(brList: RoutingFixtures.data("br-list-open.json"))
        XCTAssertEqual(rows.map(\.id), ["fx-a", "fx-b"])
        XCTAssertNotNil(rows[0].agentContext); XCTAssertNil(rows[1].agentContext)
        // Envelopes: br-list-open.json above and L3-0's br-list-with-blocks (real execution-block rows).
        XCTAssertEqual(try TaskContextRow.parse(brList: L3Fixtures.data("br-list-with-blocks")).count, 5)
        // A bare array inline, so both shapes are pinned.
        let bare = try TaskContextRow.parse(brList: Data(#"[{"id":"b1","agent_context":"{}"},{"id":"b2"}]"#.utf8))
        XCTAssertEqual(bare, [TaskContextRow(id: "b1", agentContext: "{}"), TaskContextRow(id: "b2", agentContext: nil)])
        XCTAssertThrowsError(try TaskContextRow.parse(brList: Data(#""nope""#.utf8)))
    }
}
