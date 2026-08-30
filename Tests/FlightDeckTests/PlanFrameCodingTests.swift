import XCTest
@testable import FleetKit

/// The wire shapes this feature adds, both directions.
///
/// `WireSession` decoding is additive on purpose — a phone built before this feature must
/// still decode a snapshot from a Mac built after it. The commands throw on an unrecognised
/// value, exactly as `PromptAnswer` does and for the same reason: they travel phone → Mac and
/// are *executed*, and there is no default that is not a wrong action.
final class PlanFrameCodingTests: XCTestCase {

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    func testPlanGateRoundTrips() throws {
        let gate = WirePlanGate(
            callID: "toolu_01ABC", tier: "annotate", plan: "# Title\n\nBody.",
            startedAt: "2026-08-29T17:40:36.186Z", annotationCount: 2
        )
        XCTAssertEqual(try roundTrip(gate), gate)
    }

    /// A session with no gate is the ordinary case and must not grow a key.
    func testSessionWithoutAGateEncodesNoKey() throws {
        let session = WireSession(id: UUID(), title: "t", agent: "claude")
        let data = try JSONEncoder().encode(session)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(json["planGate"])
    }

    /// **A phone that predates this feature must still read the snapshot.** The absence of the
    /// key decodes as no gate, not as a failure that takes the whole fleet down — the ruling
    /// `WireSession.agent` already makes for an unknown agent string.
    func testASnapshotWithAnUnknownExtraKeyStillDecodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"t","agent":"claude","subagentCount":0,
         "isUnread":false,"hasBackgroundWork":false,"somethingNewer":42}
        """
        XCTAssertNoThrow(try JSONDecoder().decode(WireSession.self, from: Data(json.utf8)))
    }

    func testAnnotateCommandRoundTrips() throws {
        let id = UUID(), token = UUID()
        let command = FleetCommand.annotatePlan(
            id: id, token: token, call: "toolu_01ABC", text: "needs a rollback", block: 7
        )
        XCTAssertEqual(try roundTrip(command), command)
    }

    /// A global comment carries no block. `nil` and "block 0" are different requests.
    func testAnnotateWithoutABlockRoundTrips() throws {
        let command = FleetCommand.annotatePlan(
            id: UUID(), token: UUID(), call: "c", text: "high-level note", block: nil
        )
        XCTAssertEqual(try roundTrip(command), command)
    }

    func testResolveCommandRoundTrips() throws {
        for approve in [true, false] {
            let command = FleetCommand.resolvePlan(
                id: UUID(), token: UUID(), call: "c", approve: approve, feedback: "why"
            )
            XCTAssertEqual(try roundTrip(command), command)
        }
    }

    func testCommandOpsAreTheNamesOnTheWire() throws {
        let annotate = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(
                FleetCommand.annotatePlan(id: UUID(), token: UUID(), call: "c",
                                          text: "t", block: 1)
            )
        ) as? [String: Any]
        XCTAssertEqual(annotate?["op"] as? String, "plan.annotate")

        let resolve = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(
                FleetCommand.resolvePlan(id: UUID(), token: UUID(), call: "c",
                                         approve: true, feedback: nil)
            )
        ) as? [String: Any]
        XCTAssertEqual(resolve?["op"] as? String, "plan.resolve")
    }
}
