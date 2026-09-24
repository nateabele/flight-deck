import XCTest
@testable import FlightDeck

final class DependencyGraphLayoutTests: XCTestCase {
    // 142 -> 118, 142 -> 133, 118 -> 120, 133 -> 120  (diamond; 120 is the shared root)
    private let edges: [FlywheelProjection.DepEdge] = [
        .init(from: "bd-142", to: "bd-118", kind: .dependency),
        .init(from: "bd-142", to: "bd-133", kind: .dependency),
        .init(from: "bd-118", to: "bd-120", kind: .dependency),
        .init(from: "bd-133", to: "bd-120", kind: .dependency),
    ]

    func testSharedNodeAppearsOnceAtDeepestRank() {
        let l = DependencyGraphLayout.layout(
            beadIDs: ["bd-142","bd-118","bd-133","bd-120"], edges: edges,
            statusByBead: [:], nodeSize: .init(width: 132, height: 48), spacing: .init(width: 40, height: 80))
        XCTAssertEqual(l.nodes.count, 4)                       // one node per bead, not five
        XCTAssertEqual(l.nodes["bd-142"]?.rank, 0)
        XCTAssertEqual(l.nodes["bd-120"]?.rank, 2)            // pushed to the deepest rank
    }

    func testEqualTopologyYieldsIdenticalPositions() {
        let a = DependencyGraphLayout.layout(beadIDs: ["bd-142","bd-118","bd-133","bd-120"], edges: edges,
            statusByBead: ["bd-118": .stalled], nodeSize: .init(width: 132, height: 48), spacing: .init(width: 40, height: 80))
        // Same topology, only a status changed (stalled -> active): positions must not move.
        let b = DependencyGraphLayout.layout(beadIDs: ["bd-142","bd-118","bd-133","bd-120"], edges: edges,
            statusByBead: ["bd-118": .active], nodeSize: .init(width: 132, height: 48), spacing: .init(width: 40, height: 80))
        XCTAssertEqual(a.contentHash, b.contentHash)
        XCTAssertEqual(a.nodes["bd-118"]?.position, b.nodes["bd-118"]?.position)
    }

    func testRootCauseIsDeepestStalledNotBlockedOnCriticalPath() {
        let l = DependencyGraphLayout.layout(beadIDs: ["bd-142","bd-118","bd-133","bd-120"], edges: edges,
            statusByBead: ["bd-142": .blocked, "bd-118": .stalled, "bd-120": .active],
            nodeSize: .init(width: 132, height: 48), spacing: .init(width: 40, height: 80))
        XCTAssertEqual(l.rootCauseID, "bd-118")   // stalled, not blocked, deepest actionable node
    }
}
