import XCTest
@testable import FlightDeck

/// `FlywheelEnablement.isEnabled` is the one predicate `ProjectView` switches its whole body
/// on — enabled shows the intake UI, disabled shows `disabledEmptyState` — and the one
/// `ProjectHeaderRow`'s context menu reads to gate "Enable/Setup Flywheel…". Exercising the
/// predicate directly is what actually covers that branch: both call sites are otherwise
/// plain SwiftUI with no seam to assert a rendered view through.
final class FlywheelEnablementTests: XCTestCase {
    func testNilSettingsIsDisabled() {
        XCTAssertFalse(FlywheelEnablement.isEnabled(nil))
    }

    func testDefaultSettingsIsDisabled() {
        XCTAssertFalse(FlywheelEnablement.isEnabled(ProjectSettings()))
    }

    func testExplicitlyDisabledSettingsIsDisabled() {
        XCTAssertFalse(FlywheelEnablement.isEnabled(ProjectSettings(flywheelEnabled: false)))
    }

    func testEnabledSettingsIsEnabled() {
        XCTAssertTrue(FlywheelEnablement.isEnabled(ProjectSettings(flywheelEnabled: true)))
    }
}
