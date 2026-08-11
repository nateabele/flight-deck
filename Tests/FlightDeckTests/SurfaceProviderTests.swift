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

    /// One libghostty app per process. A second `GhosttyApp()` would call
    /// `ghostty_app_new` again, and `AppDelegate` constructing its own was how the
    /// startup-ordering bug hid.
    @MainActor
    func testAppDelegateSharesTheProcessWideGhosttyApp() {
        XCTAssertNotNil(GhosttyApp.shared)
        XCTAssertTrue(AppDelegate().ghostty === GhosttyApp.shared)
    }
}
