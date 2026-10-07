import XCTest
@testable import HostKit

final class DurationTests: XCTestCase {
    func testParsesUnits() {
        XCTAssertEqual(Duration.parse("45s")?.seconds, 45)
        XCTAssertEqual(Duration.parse("30m")?.seconds, 1800)
        XCTAssertEqual(Duration.parse("4h")?.seconds, 14_400)
        XCTAssertEqual(Duration.parse("1d")?.seconds, 86_400)
        XCTAssertEqual(Duration.parse("1h30m")?.seconds, 5400)
    }

    func testRejectsGarbage() {
        for bad in ["", "4", "h", "-1h", "1.5h", "4 h", "1w", "0m"] {
            XCTAssertNil(Duration.parse(bad), bad)
        }
    }

    func testFormatsLargestUnitsFirst() {
        XCTAssertEqual(Duration(seconds: 5400).formatted, "1h30m")
        XCTAssertEqual(Duration(seconds: 172_800).formatted, "2d")
        XCTAssertEqual(Duration(seconds: 59).formatted, "59s")
    }
}
