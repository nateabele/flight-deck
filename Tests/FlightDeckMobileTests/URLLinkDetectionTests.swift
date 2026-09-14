import XCTest
@testable import FlightDeckMobile

/// The shared bare-URL detector every prose renderer that does not already autolink runs
/// through — see `URLLinkDetection`'s own doc comment for why the plain-text kinds and the
/// attributed path both need one and MarkdownUI does not.
final class URLLinkDetectionTests: XCTestCase {

    func testABareHTTPURLIsDetected() {
        let matches = URLLinkDetection.matches(in: "see http://example.com for details")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.url.absoluteString, "http://example.com")
    }

    func testABareHTTPSURLIsDetected() {
        let matches = URLLinkDetection.matches(in: "see https://example.com/path?q=1 for details")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.url.absoluteString, "https://example.com/path?q=1")
    }

    /// No scheme at all — `NSDataDetector` still recognises it, and gives it one back.
    func testAWWWURLWithNoSchemeIsDetected() {
        let matches = URLLinkDetection.matches(in: "check www.example.com first")
        XCTAssertEqual(matches.count, 1, "www.example.com")
        XCTAssertEqual(matches.first?.url.host, "www.example.com")
    }

    /// **The reason this is worth its own test and not an assumption.** A URL sentence ends
    /// naturally in the punctuation that ends the sentence, and a link that swallowed it would
    /// open a page that 404s on the trailing dot.
    func testTrailingSentencePunctuationIsExcludedFromTheMatch() {
        let matches = URLLinkDetection.matches(in: "see https://example.com.")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(
            matches.first?.url.absoluteString, "https://example.com",
            "the trailing period ends the sentence, not the address"
        )
    }

    /// A URL already wrapped in Markdown link syntax detects as the one substring it is — no
    /// overlapping second match off the same address, and no swallowing of the closing `)`
    /// that is Markdown's, not the URL's. `URLLinkDetection` itself does not know about
    /// Markdown; this is what the overlap guards downstream (`TimelineProseText`) rely on.
    func testAURLInsideMarkdownLinkSyntaxIsDetectedOnce() {
        let matches = URLLinkDetection.matches(in: "see [here](https://example.com) for details")
        XCTAssertEqual(matches.count, 1, "one URL, one match — not two overlapping ones")
        XCTAssertEqual(matches.first?.url.absoluteString, "https://example.com")
    }

    func testNoURLYieldsNoMatches() {
        XCTAssertTrue(URLLinkDetection.matches(in: "nothing to see here").isEmpty)
    }

    func testAnEmptyStringYieldsNoMatches() {
        XCTAssertTrue(URLLinkDetection.matches(in: "").isEmpty)
    }
}
