import XCTest
@testable import FlightDeck

final class ObserveLaneModelTests: XCTestCase {
    func testMissingReservationLaneMarksFilesUnavailableOnly() {
        let agent = FlywheelProjection.Agent(name: "BlueFalcon",
            bead: .init(id: "bd-142", title: "refactor auth", status: "in_progress", assignee: "BlueFalcon"),
            status: .active, holds: [], waitsOn: [], lastEventAt: nil, stalledSince: nil)
        let rows = ObserveLaneModel.lanes(for: agent, unavailable: ["reservations"])
        let files = rows.first { $0.lane == .files }
        let working = rows.first { $0.lane == .workingOn }
        XCTAssertEqual(files?.isUnavailable, true)
        XCTAssertEqual(working?.isUnavailable, false)
        XCTAssertEqual(working?.detail.contains("bd-142"), true)
    }

    func testNilAgentYieldsNoLanes() {
        XCTAssertTrue(ObserveLaneModel.lanes(for: nil, unavailable: []).isEmpty)
    }
}
