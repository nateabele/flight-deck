import XCTest
@testable import FlightDeck

/// The Meter Gallery UI test finds each bar by its `meter-bar` identifier and reads `.value`.
/// An AXGroup carries no value and a Text carries no label, so the bar exposes one Text whose
/// string holds both; this pins that string. (An in-process NSAccessibility tree walk was tried
/// and deleted: this runner is not AX-trusted, so SwiftUI builds no tree and it always skipped,
/// proving nothing. The UI test is the authority on the live tree.)
final class MeterAccessibilityTests: XCTestCase {
    private let model = AccountMeterModel(id: "a", label: "Work", fraction: 0.82, state: .overSoft, soft: 0.8, hard: 0.95,
                                          resetText: "resets 11:00 PM", sourceText: "claude mod · 3 min ago", detail: nil)

    func testSpokenTextIsNameThenReading() {
        XCTAssertEqual(model.spokenText, "Work: \(model.accessibilityValue)")
        XCTAssertTrue(model.spokenText.hasPrefix("Work: 82 percent used, past its soft limit"))
    }

    func testUnknownAccountSpeaksNoReading() {
        let spare = AccountMeterModel(id: "b", label: "Spare", fraction: nil, state: .unknown, soft: 0.8, hard: 0.95,
                                      resetText: nil, sourceText: nil, detail: "no reading")
        XCTAssertEqual(spare.spokenText, "Spare: no reading")
    }
}
