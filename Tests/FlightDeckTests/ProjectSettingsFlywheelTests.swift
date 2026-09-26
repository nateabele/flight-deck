import XCTest
@testable import FlightDeck

final class ProjectSettingsFlywheelTests: XCTestCase {
    func testDefaultsToNilAndReadsAsDisabled() {
        XCTAssertNil(ProjectSettings().flywheelEnabled)
        XCTAssertFalse(ProjectSettings().flywheelEnabled == true)
    }

    func testEmptyIgnoresFlywheelFalseButNotTrue() {
        XCTAssertTrue(ProjectSettings(flywheelEnabled: nil).isEmpty)
        XCTAssertTrue(ProjectSettings(flywheelEnabled: false).isEmpty)
        XCTAssertFalse(ProjectSettings(flywheelEnabled: true).isEmpty)
    }

    func testDecodesLegacyJSONWithoutTheField() throws {
        let legacy = Data(#"{"accounts":{},"options":{}}"#.utf8)
        let decoded = try JSONDecoder().decode(ProjectSettings.self, from: legacy)
        XCTAssertNil(decoded.flywheelEnabled)
        XCTAssertTrue(decoded.isEmpty)
    }

    func testRoundTripsTrue() throws {
        let data = try JSONEncoder().encode(ProjectSettings(flywheelEnabled: true))
        XCTAssertEqual(try JSONDecoder().decode(ProjectSettings.self, from: data).flywheelEnabled, true)
    }
}
