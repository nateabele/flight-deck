import XCTest
@testable import FlightDeck

/// The tab's sections are what `RoutingUITests` clicks by identifier; renaming one silently
/// breaks every UI test, so the names are pinned here, where a rename fails fast and headless.
final class FlightControlTabTests: XCTestCase {
    func testTheTabHasFourSectionsInOrder() {
        XCTAssertEqual(FlightControlSettingsTab.Section.allCases.map(\.rawValue), ["Routing", "Task kinds", "Capability index", "Capacity"])
        XCTAssertEqual(FlightControlSettingsTab.Section.allCases.map(\.identifier), ["fc-section-routing", "fc-section-kinds", "fc-section-index", "fc-section-capacity"])
    }
}
