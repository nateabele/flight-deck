import XCTest
import IntakeKit

final class ChangeSetCodingTests: XCTestCase {
    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "changeset-all-ops", withExtension: "json", subdirectory: "Fixtures/Intake"))
        return try Data(contentsOf: url)
    }

    func testDecodesEveryOpKind() throws {
        let cs = try ChangeSet.decode(try fixture())
        XCTAssertEqual(cs.ops.count, 5)
        XCTAssertEqual(cs.ops[1], .addEdge(from: .new("n1"), to: .existing("br-42"), kind: .blocks))
        guard case .editBead(let id, let set, let pre, let delivery) = cs.ops[2] else { return XCTFail() }
        XCTAssertEqual(id, "br-17")
        XCTAssertEqual(set.acceptance, "new ac")
        XCTAssertEqual(pre, Precondition(status: "in_progress", assignee: "BlueFalcon"))
        XCTAssertEqual(delivery?.rating, .scopeChange)
    }

    func testRoundTrips() throws {
        let cs = try ChangeSet.decode(try fixture())
        XCTAssertEqual(try ChangeSet.decode(try cs.encoded()), cs)
    }

    func testUnknownOpIsAnError() {
        let data = Data(#"{"graphObservedAt":"2026-09-26T20:00:00Z","ops":[{"op":"deleteEverything"}]}"#.utf8)
        XCTAssertThrowsError(try ChangeSet.decode(data))
    }

    func testBeadRefStringForm() throws {
        XCTAssertEqual(BeadRef(parsing: "new:n3"), .new("n3"))
        XCTAssertEqual(BeadRef(parsing: "br-3"), .existing("br-3"))
        XCTAssertEqual(BeadRef.new("n3").wireValue, "new:n3")
    }

    func testIntakeJSONRoundTripWithFractionalSeconds() throws {
        // Date with fractional seconds must round-trip exactly after rounding to milliseconds.
        // Intake.init rounds to millisecond precision to match ISO8601 formatter precision.
        let dateWithSubMs = Date(timeIntervalSince1970: 1000.1234567)
        var intake = Intake(projectPath: "/p", intent: "test", createdAt: dateWithSubMs)
        intake.state = .review
        let encoded = try IntakeJSON.encoder.encode(intake)
        let decoded = try IntakeJSON.decoder.decode(Intake.self, from: encoded)
        // After rounding to milliseconds in init, dates should match exactly
        XCTAssertEqual(decoded.createdAt, intake.createdAt)
        XCTAssertEqual(decoded, intake)
    }

    func testIntakeJSONDecodesNoFractionTimestamps() throws {
        // Task 5 fixtures and agents emit dates without fractional seconds (e.g., 2026-09-26T20:00:00Z).
        // These must still decode successfully.
        let json = """
        {
          "id": "12345678-1234-5678-1234-567812345678",
          "projectPath": "/p",
          "intent": "test",
          "createdAt": "2026-09-26T20:00:00Z",
          "state": "triaging",
          "exchanges": [],
          "ratingOverrides": {},
          "droppedOps": [],
          "confirmedDrift": []
        }
        """.data(using: .utf8)!
        let decoded = try IntakeJSON.decoder.decode(Intake.self, from: json)
        XCTAssertEqual(decoded.intent, "test")
        XCTAssertEqual(decoded.state, .triaging)
    }
}
