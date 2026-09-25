import XCTest
@testable import FlightDeck

final class ProjectSettingsObserveTests: XCTestCase {
    func testDecodesRecordWrittenBeforeDrawerField() throws {
        // JSON with no drawerCollapsed key — must decode with nil, not throw.
        let json = #"{"accounts":{},"options":{}}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(ProjectSettings.self, from: json)
        XCTAssertNil(s.drawerCollapsed)
    }

    func testDrawerCollapsedAloneDoesNotKeepRecordAlive() {
        var s = ProjectSettings()
        s.drawerCollapsed = false
        XCTAssertTrue(s.isEmpty, "a false/absent drawer flag must not keep an otherwise-empty record")
        s.drawerCollapsed = true
        XCTAssertFalse(s.isEmpty)
    }
}
