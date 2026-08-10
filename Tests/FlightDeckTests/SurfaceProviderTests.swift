import XCTest
@testable import FlightDeck

final class SurfaceProviderTests: XCTestCase {
    func testGhosttyAppConformsToSurfaceProvider() throws {
        guard let app = GhosttyApp() else {
            throw XCTSkip("GhosttyApp could not initialize in this environment")
        }
        // Conformance is the assertion: this must compile and hold at runtime.
        let provider: SurfaceProvider = app
        XCTAssertTrue(provider is GhosttyApp)
        XCTAssertTrue(app.hasValidApp)
    }
}
