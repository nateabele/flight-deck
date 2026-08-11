import XCTest
@testable import FlightDeck

final class SurfaceProviderTests: XCTestCase {
    func testGhosttyAppConformsToSurfaceProvider() throws {
        // Use the process-wide instance rather than constructing a second `GhosttyApp()`:
        // this test process only ever holds one libghostty app (see
        // testAppDelegateSharesTheProcessWideGhosttyApp), and a second instance would get
        // `ghostty_app_free`d out from under the shared one at its own teardown.
        guard let app = GhosttyApp.shared else {
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
