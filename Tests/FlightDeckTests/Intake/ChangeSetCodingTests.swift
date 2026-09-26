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
}
