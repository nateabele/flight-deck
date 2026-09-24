import XCTest
@testable import FlightDeck

final class FlywheelProjectionTests: XCTestCase {
    private func snap(agents: [String], beads: [(String,String,String,String?)] = []) -> FlywheelSnapshot {
        FlywheelSnapshot(
            agents: agents.map { .init(name: $0) },
            beads: beads.map { .init(id: $0.0, title: $0.1, status: $0.2, assignee: $0.3) },
            reservations: [], depEdges: [], events: [])
    }

    func testJoinsIdentityToAgentRow() {
        let p = FlywheelProjection.project(
            snap(agents: ["BlueFalcon"], beads: [("bd-142","refactor auth","in_progress","BlueFalcon")]),
            now: Date(), stallThreshold: 600, previous: nil)
        let a = p.agent(for: FlywheelIdentity(agentName: "BlueFalcon", project: "/tmp/p"))
        XCTAssertEqual(a?.bead?.id, "bd-142")
    }

    func testUnjoinedIdentityIsExternal() {
        let p = FlywheelProjection.project(snap(agents: ["GoldViper"]), now: Date(), stallThreshold: 600, previous: nil)
        XCTAssertNil(p.agent(for: FlywheelIdentity(agentName: "NotHere", project: "/tmp/p")))
    }

    func testStalledIsHoldsContendedPlusIdlePastThresholdAndNotBlocked() {
        let now = Date()
        var snap = self.snap(agents: ["GoldViper"])
        // GoldViper holds a file another agent waits on, last event 20m ago, not blocked.
        snap.reservations = [.init(file: "src/Auth.swift", holder: "GoldViper", since: now.addingTimeInterval(-1800), waiters: ["BlueFalcon"])]
        snap.events = [.init(agent: "GoldViper", kind: "edit", at: now.addingTimeInterval(-1200))]
        let p = FlywheelProjection.project(snap, now: now, stallThreshold: 600, previous: nil)
        let a = p.agents.first { $0.name == "GoldViper" }
        XCTAssertEqual(a?.status, .stalled)
        XCTAssertNotNil(a?.stalledSince)
    }

    func testRefreshedLeaseKeepsStallClockNotReset() {
        let now = Date()
        var first = self.snap(agents: ["GoldViper"])
        first.reservations = [.init(file: "a.swift", holder: "GoldViper", since: now.addingTimeInterval(-1800), waiters: ["X"])]
        first.events = [.init(agent: "GoldViper", kind: "edit", at: now.addingTimeInterval(-1200))]
        let p1 = FlywheelProjection.project(first, now: now, stallThreshold: 600, previous: nil)
        let stalledSince1 = p1.agents.first { $0.name == "GoldViper" }?.stalledSince
        // Lease refreshes (new `since`) but no new activity: still the same stall.
        var second = first
        second.reservations = [.init(file: "a.swift", holder: "GoldViper", since: now.addingTimeInterval(-60), waiters: ["X"])]
        let p2 = FlywheelProjection.project(second, now: now.addingTimeInterval(30), stallThreshold: 600, previous: p1)
        let stalledSince2 = p2.agents.first { $0.name == "GoldViper" }?.stalledSince
        XCTAssertEqual(stalledSince1, stalledSince2, "a lease refresh is continuity, not a new stall")
    }

    func testNilReservationLaneMarksLaneUnavailableNotCrash() {
        var s = snap(agents: ["BlueFalcon"]); s.reservations = nil
        let p = FlywheelProjection.project(s, now: Date(), stallThreshold: 600, previous: nil)
        XCTAssertTrue(p.lanesUnavailable.contains("reservations"))
        XCTAssertEqual(p.agents.first?.holds, [])
    }
}
