import XCTest
import IntakeKit
@testable import FlightDeck

/// Observe's projection gets three facts it could not read for itself: who waits on a reservation
/// (from guard blocks), when each agent was last active (from its tab), and who declared BLOCKED:.
final class ObserveEnrichmentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let reservation = FlywheelReadCommands.RawReservation(file: "Sources/*.swift", holder: "GreenFox",
                                                                  since: Date(timeIntervalSince1970: 1_790_000_000 - 360), waiters: [])

    func testAContestBecomesAWaiterOnTheMatchingReservation() {
        let contest = Contest(file: "Sources/Foo.swift", holder: "GreenFox", heldSince: nil, message: "m", at: now)
        let snapshot = ObserveEnrichment.enrich(
            FlywheelSnapshot(agents: [], beads: [], reservations: [reservation], depEdges: [], events: nil),
            contests: ["BlueLake": contest], activity: [:], blocked: [])
        XCTAssertEqual(snapshot.reservations?.first?.waiters, ["BlueLake"])
    }

    func testActivityStandsInForAMissingEventsLane() {
        let snapshot = ObserveEnrichment.enrich(
            FlywheelSnapshot(agents: [], beads: [], reservations: [], depEdges: [], events: nil),
            contests: [:], activity: ["GreenFox": now - 1_200], blocked: ["BlueLake"])
        XCTAssertEqual(snapshot.events, [FlywheelReadCommands.RawEvent(agent: "GreenFox", kind: "activity", at: now - 1_200)])
        XCTAssertEqual(snapshot.declaredBlocked, ["BlueLake"])
    }

    func testARealEventsLaneIsLeftAlone() {
        let real = [FlywheelReadCommands.RawEvent(agent: "A", kind: "x", at: now)]
        let snapshot = ObserveEnrichment.enrich(
            FlywheelSnapshot(agents: [], beads: [], reservations: [], depEdges: [], events: real),
            contests: [:], activity: ["A": now - 9_999], blocked: [])
        XCTAssertEqual(snapshot.events, real)
    }
}
