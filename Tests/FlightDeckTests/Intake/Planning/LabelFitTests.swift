import AppKit
import XCTest
@testable import FlightDeck

/// Spec §5.3: a label shows its full name when it fits its measured slot, else its code. The
/// measure is injected so the rule is tested without font metrics; one test pins the real one.
final class LabelFitTests: XCTestCase {
    /// Ten points a character: easy arithmetic, and nothing like any real font.
    private let tenPerChar: (String) -> CGFloat = { CGFloat($0.count) * 10 }

    func testChoosesFullWhenItFits() {
        XCTAssertEqual(LabelFit.choose(full: "Synthesis", code: "SYN", width: 200, measure: tenPerChar), "Synthesis")
    }

    func testChoosesCodeWhenTooNarrow() {
        XCTAssertEqual(LabelFit.choose(full: "Synthesis", code: "SYN", width: 60, measure: tenPerChar), "SYN")
    }

    func testPaddingCounts() {
        // "Refine 2" measures 80: it fits 88 only with the default 8 of padding, and 87 not at all.
        XCTAssertEqual(LabelFit.choose(full: "Refine 2", code: "RF2", width: 88, measure: tenPerChar), "Refine 2")
        XCTAssertEqual(LabelFit.choose(full: "Refine 2", code: "RF2", width: 87, measure: tenPerChar), "RF2")
        XCTAssertEqual(LabelFit.choose(full: "Refine 2", code: "RF2", width: 88, padding: 12, measure: tenPerChar), "RF2")
        XCTAssertEqual(LabelFit.choose(full: "Refine 2", code: "RF2", width: 80, padding: 0, measure: tenPerChar), "Refine 2")
    }

    /// A slot sized to exactly the name's fit width comes back from layout pixel-rounded, a hair
    /// narrower than the fractional measurement. Rounding both sides up keeps it on the full name
    /// instead of dropping NOW to its code with room to spare.
    func testFitWidthSurvivesPixelRounding() {
        let fractional: (String) -> CGFloat = { _ in 91.3 }
        let fit = LabelFit.fitWidth(full: "Refine 2", measure: fractional)
        XCTAssertEqual(fit, 100)
        XCTAssertEqual(LabelFit.choose(full: "Refine 2", code: "RF2", width: 99.25, measure: fractional), "Refine 2")
        XCTAssertEqual(LabelFit.choose(full: "Refine 2", code: "RF2", width: 98.9, measure: fractional), "RF2")
    }

    func testMeasureWithRealFont() {
        let width = LabelFit.measureWith(.monospacedSystemFont(ofSize: 13, weight: .semibold))("Synthesis")
        XCTAssertGreaterThan(width, 60)
        XCTAssertLessThan(width, 100)
    }
}
