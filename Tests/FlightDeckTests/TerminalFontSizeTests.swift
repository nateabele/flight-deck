import XCTest
@testable import FlightDeck

final class TerminalFontSizeTests: XCTestCase {
    // MARK: - resolved

    func testResolvedFallsBackToDefaultWhenNil() {
        XCTAssertEqual(TerminalFontSize.resolved(nil, default: 12), 12)
    }

    func testResolvedPrefersTheStoredValueWhenSet() {
        XCTAssertEqual(TerminalFontSize.resolved(18, default: 12), 18)
    }

    // MARK: - bigger / smaller

    func testBiggerSteps() {
        XCTAssertEqual(TerminalFontSize.bigger(12), 13)
    }

    func testSmallerSteps() {
        XCTAssertEqual(TerminalFontSize.smaller(12), 11)
    }

    // MARK: - clamping, both ends

    func testBiggerClampsAtTheTopOfRange() {
        XCTAssertEqual(TerminalFontSize.bigger(TerminalFontSize.range.upperBound), TerminalFontSize.range.upperBound)
    }

    func testSmallerClampsAtTheBottomOfRange() {
        XCTAssertEqual(TerminalFontSize.smaller(TerminalFontSize.range.lowerBound), TerminalFontSize.range.lowerBound)
    }

    // MARK: - action(points:)

    /// The exact string libghostty parses: `%.1f`, never bare interpolation of a `Float`
    /// (which would print `14.0` on some values and `14` on others).
    func testActionFormatsWithAnExplicitDecimal() {
        XCTAssertEqual(TerminalFontSize.action(points: 14), "set_font_size:14.0")
    }

    func testActionPreservesFractionalPoints() {
        XCTAssertEqual(TerminalFontSize.action(points: 13.5), "set_font_size:13.5")
    }
}
