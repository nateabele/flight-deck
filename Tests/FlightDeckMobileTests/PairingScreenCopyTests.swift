import XCTest
import FleetKit
@testable import FlightDeckMobile

final class PairingScreenCopyTests: XCTestCase {
    /// Until v3 only "too new" was reachable, so one message covered it. A newer phone can
    /// now meet an older Mac, and telling that user to update their phone sends them the
    /// wrong way entirely.
    func testATooOldCodeBlamesTheMacAndATooNewOneBlamesThePhone() {
        let older = PairingScreen.message(for: .unsupportedVersion(2))
        let newer = PairingScreen.message(for: .unsupportedVersion(99))
        XCTAssertTrue(older.localizedCaseInsensitiveContains("Mac"), older)
        XCTAssertFalse(older.localizedCaseInsensitiveContains("phone"), older)
        XCTAssertTrue(newer.localizedCaseInsensitiveContains("phone"), newer)
        XCTAssertNotEqual(older, newer)
    }
}
