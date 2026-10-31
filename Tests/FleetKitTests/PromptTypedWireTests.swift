import XCTest
@testable import FleetKit

final class PromptTypedWireTests: XCTestCase {
    func testPromptTypedRoundTripsOnTheWire() throws {
        let id = UUID(); let token = UUID()
        let event = FleetEvent.promptTyped(id: id, token: token)
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(FleetEvent.self, from: data), event)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"prompt.typed\""), json)
    }
    func testPromptTypedCarriesSessionIdAndNoProject() {
        let id = UUID()
        let event = FleetEvent.promptTyped(id: id, token: UUID())
        XCTAssertEqual(event.sessionID, id)
        XCTAssertNil(event.projectID)
    }
    func testPromptTypedIsANoOpOnTheSnapshot() {
        var snapshot = FleetSnapshot(projects: [])
        let before = snapshot
        snapshot.apply(.promptTyped(id: UUID(), token: UUID()))
        XCTAssertEqual(snapshot, before)
    }
}
