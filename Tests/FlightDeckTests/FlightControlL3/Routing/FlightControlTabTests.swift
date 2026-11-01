import XCTest
@testable import FlightDeck

/// The tab's sections are what `RoutingUITests` clicks by identifier; renaming one silently
/// breaks every UI test, so the names are pinned here, where a rename fails fast and headless.
final class FlightControlTabTests: XCTestCase {
    func testTheTabHasFiveSectionsInOrder() {
        XCTAssertEqual(FlightControlSettingsTab.Section.allCases.map(\.rawValue), ["Routing", "Task Kinds", "Capability Index", "Capacity", "Providers"])
        XCTAssertEqual(FlightControlSettingsTab.Section.allCases.map(\.identifier), ["fc-section-routing", "fc-section-kinds", "fc-section-index", "fc-section-capacity", "fc-section-providers"])
    }
}
