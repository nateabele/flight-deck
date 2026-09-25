import XCTest
@testable import FlightDeck

final class DAGOverlayHitTestTests: XCTestCase {
    func testClickInsideNodeBoxResolvesToNode() {
        let edges: [FlywheelProjection.DepEdge] = [.init(from: "bd-142", to: "bd-118", kind: .dependency)]
        let nodeSize = CGSize(width: 132, height: 48)
        let layout = DependencyGraphLayout.layout(beadIDs: ["bd-142","bd-118"], edges: edges,
            statusByBead: [:], nodeSize: nodeSize, spacing: .init(width: 40, height: 80))
        let vp = CGSize(width: 640, height: 360)
        let cam = DAGCamera.centered(on: layout.nodes["bd-118"]!.position, scale: 1)
        // The selected node sits at viewport center; a click there hits it.
        let hit = DAGHitTester.node(at: CGPoint(x: 320, y: 180), layout: layout, camera: cam, viewport: vp, nodeSize: nodeSize)
        XCTAssertEqual(hit, "bd-118")
    }

    func testClickInEmptySpaceResolvesToNil() {
        let layout = DependencyGraphLayout.layout(beadIDs: ["bd-1"], edges: [],
            statusByBead: [:], nodeSize: .init(width: 132, height: 48), spacing: .init(width: 40, height: 80))
        let cam = DAGCamera.centered(on: layout.nodes["bd-1"]!.position, scale: 1)
        let hit = DAGHitTester.node(at: CGPoint(x: 5, y: 5), layout: layout, camera: cam, viewport: .init(width: 640, height: 360), nodeSize: .init(width: 132, height: 48))
        XCTAssertNil(hit)
    }
}
