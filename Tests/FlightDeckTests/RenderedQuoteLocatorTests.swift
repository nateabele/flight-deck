import XCTest
import IntakeKit

final class RenderedQuoteLocatorTests: XCTestCase {
    private func locate(_ q: String, in md: String) -> String? {
        RenderedQuoteLocator.range(of: q, within: md.startIndex..<md.endIndex, of: md).map { String(md[$0]) }
    }

    func testPlainTextMatchesVerbatim() {
        XCTAssertEqual(locate("chosen mode", in: "Require that the chosen mode permits."), "chosen mode")
    }
    func testBoldSpansMapToTheirSource() {
        XCTAssertEqual(locate("account sign-in and API", in: "separate **account sign-in** and **API credential** paths"),
                       "account sign-in** and **API")
    }
    func testCodeAndLinksMapToTheirSource() {
        XCTAssertEqual(locate("keep vault keys", in: "keep `vault` keys"), "keep `vault` keys")
        XCTAssertEqual(locate("through Beacon's gateway now", in: "through [Beacon's gateway](https://x.test) now"),
                       "through [Beacon's gateway](https://x.test) now")
    }
    func testWrappedWhitespaceStillMatches() {
        XCTAssertEqual(locate("hosted and unattended", in: "hosted\n  and   unattended"), "hosted\n  and   unattended")
    }
    func testHeadingPrefixIsIgnored() {
        XCTAssertEqual(locate("7. Credential paths", in: "## 7. Credential paths"), "7. Credential paths")
    }
    func testNotFoundIsNil() {
        XCTAssertNil(locate("nowhere to be seen", in: "Some other text."))
    }
    func testScopeLimitsTheSearch() {
        let md = "alpha beta\n\nalpha gamma"
        let second = md.range(of: "alpha gamma")!
        let r = RenderedQuoteLocator.range(of: "alpha", within: second, of: md)!
        XCTAssertEqual(md.distance(from: md.startIndex, to: r.lowerBound), md.distance(from: md.startIndex, to: second.lowerBound))
    }
    func testALongRealisticPlan() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sample-plan.md")
        let md = try String(contentsOf: url, encoding: .utf8)
        let r = RenderedQuoteLocator.range(of: "Require explicit proof that the chosen mode permits hosted and unattended execution",
                                           within: md.startIndex..<md.endIndex, of: md)
        XCTAssertNotNil(r)
    }
}
