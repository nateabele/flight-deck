import XCTest
@testable import FlightDeck

final class DAGCameraTests: XCTestCase {
    func testCenterMapsToViewportCenter() {
        let cam = DAGCamera.centered(on: CGPoint(x: 100, y: 200), scale: 2)
        let vp = CGSize(width: 640, height: 360)
        let mapped = CGPoint(x: 100, y: 200).applying(cam.transform(viewport: vp))
        XCTAssertEqual(mapped.x, 320, accuracy: 0.001)
        XCTAssertEqual(mapped.y, 180, accuracy: 0.001)
    }

    func testViewToGraphRoundTrip() {
        let cam = DAGCamera.centered(on: CGPoint(x: 100, y: 200), scale: 1.7)
        let vp = CGSize(width: 640, height: 360)
        let v = CGPoint(x: 512, y: 40)
        let g = cam.graphPoint(fromViewPoint: v, viewport: vp)
        let back = g.applying(cam.transform(viewport: vp))
        XCTAssertEqual(back.x, v.x, accuracy: 0.001)
        XCTAssertEqual(back.y, v.y, accuracy: 0.001)
    }
}
