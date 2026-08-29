import XCTest
@testable import FlightDeck

final class ScreenLockTests: XCTestCase {
    /// The seam exists so the store can be tested on both sides of a condition that is
    /// otherwise a property of the machine running the suite.
    func testAStubReportsWhateverItIsToldTo() {
        struct Stub: ScreenLockInspecting { var isLocked: Bool }
        XCTAssertTrue(Stub(isLocked: true).isLocked)
        XCTAssertFalse(Stub(isLocked: false).isLocked)
    }

    /// The real one must answer without throwing or hanging. Its VALUE is not asserted:
    /// the suite runs both locked (CI, no session) and unlocked (a desk), and pinning
    /// either would make this test fail on the other.
    func testTheRealInspectorAnswers() {
        _ = ScreenLock().isLocked
    }
}
