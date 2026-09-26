import XCTest
import IntakeKit

final class GraphSnapshotTests: XCTestCase {
    private func load(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures/Intake")))
    }
    func testDecodesBeadsAndEdges() throws {
        let g = try GraphSnapshot.decode(list: try load("br-list-all"), graph: try load("br-graph-all"))
        XCTAssertEqual(g.beads.count, 3)
        XCTAssertEqual(g.beads["t-lqw"]?.assignee, "BlueFalcon")
        XCTAssertEqual(g.beads["t-c1"]?.status, "closed")
        XCTAssertEqual(g.beads["t-5mi"]?.labels, ["x", "y"])
        XCTAssertEqual(g.edges, [DepEdge(dependent: "t-5mi", dependency: "t-lqw")])
    }
    func testEmptyGraphHasNoComponents() throws {
        let g = try GraphSnapshot.decode(list: Data(#"{"issues":[]}"#.utf8),
                                         graph: Data(#"{"components":[]}"#.utf8))
        XCTAssertTrue(g.beads.isEmpty); XCTAssertTrue(g.edges.isEmpty)
    }
}
