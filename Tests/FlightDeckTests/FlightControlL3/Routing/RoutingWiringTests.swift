import XCTest
import IntakeKit
@testable import FlightDeck

/// The app owns one `RoutingService`: Settings draws it, and intake release asks it for blocks
/// through the store. A store a test builds has none, and releases exactly as before Level 3.
@MainActor
final class RoutingWiringTests: XCTestCase {
    private var root: URL!
    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RoutingWiringTests-\(UUID())", isDirectory: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root); super.tearDown() }

    func testTheStoresRoutingIsWhatIntakeReleaseAsks() {
        let store = SessionStore(provider: nil, persistence: nil, intakesRoot: root)
        XCTAssertNil(store.intakeService.encodeRouting())
        let routing = RoutingService.live(preferences: PreferencesStore(persistence: nil))
        store.flightControlRouting = routing
        XCTAssertTrue(store.intakeService.encodeRouting() === routing,
                      "resolved at release time, so routing attached after the service was built still counts")
    }

    func testFlightControlIsASettingsPane() {
        XCTAssertTrue(PreferencesTab.allCases.contains(.flightControl))
    }

    func testALiveServiceStartsEmptyAndIsNotTheFixture() {
        let svc = RoutingService.make(preferences: PreferencesStore(persistence: nil))
        XCTAssertEqual(svc.rules(.global), [])
        XCTAssertNil(svc.fixtureProjects)
    }
}
