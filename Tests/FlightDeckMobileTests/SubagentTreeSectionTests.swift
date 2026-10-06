import FleetKit
import XCTest
@testable import FlightDeckMobile

final class SubagentTreeSectionTests: XCTestCase {
    private let nodes = [
        WireSubagent(id: "a0", parent: nil, type: "controller", description: "Run", state: "running"),
        WireSubagent(id: "a1", parent: "a0", type: "implementer", description: "Task 14", state: "blocked"),
        WireSubagent(id: "a2", parent: "a0", type: "reviewer", description: "Review", state: "running"),
    ]

    func testAncestorsOfABlockedAgentStartExpanded() {
        XCTAssertEqual(SubagentRows.autoExpanded(nodes), ["a0"])
    }

    func testCollapsedShowsOnlyRoots() {
        let rows = SubagentRows.visible(nodes, expanded: [])
        XCTAssertEqual(rows.map(\.node.id), ["a0"])
        XCTAssertEqual(rows.map(\.depth), [0])
    }

    func testExpandedShowsChildrenOneDeeper() {
        let rows = SubagentRows.visible(nodes, expanded: ["a0"])
        XCTAssertEqual(rows.map(\.node.id), ["a0", "a1", "a2"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1])
    }
}
