import XCTest
@testable import FlightDeck

final class DisplayStateTests: XCTestCase {
    /// The seam exists so the store can be tested on both sides of a condition that is
    /// otherwise a property of the machine running the suite.
    func testAStubReportsWhateverItIsToldTo() {
        struct Stub: DisplayInspecting { var isDrawable: Bool }
        XCTAssertTrue(Stub(isDrawable: true).isDrawable)
        XCTAssertFalse(Stub(isDrawable: false).isDrawable)
    }

    /// The real one must answer without throwing or hanging. Its VALUE is not asserted: the
    /// suite runs both with a live display and headless, and pinning either would make this
    /// fail in the other environment.
    func testTheRealInspectorAnswers() {
        _ = DisplayState().isDrawable
    }
}
