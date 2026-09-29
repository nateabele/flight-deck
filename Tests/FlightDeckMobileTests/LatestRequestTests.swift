import XCTest
@testable import FlightDeckMobile

final class LatestRequestTests: XCTestCase {
    func testOnlyTheLatestRequestIsAccepted() {
        var seq = LatestRequest()
        let first = seq.begin()
        XCTAssertTrue(seq.accepts(first))
        let second = seq.begin()
        XCTAssertFalse(seq.accepts(first), "a slower earlier reply must not overwrite the newer request")
        XCTAssertTrue(seq.accepts(second))
    }
}
