import XCTest
@testable import FleetKit

final class TimelinePlaceholderTests: XCTestCase {
    func testAFreshBodyIsNotAPlaceholder() {
        XCTAssertFalse(TimelineItem.Body(text: "hi").isPlaceholder)
    }

    func testSpilledPlaceholderKeepsEverythingButTheFullText() {
        let body = TimelineItem.Body(
            text: "first line of a long body\nsecond line\nthird",
            summary: "sum", tool: "Bash", callID: "tA", truncatedBytes: 42, isError: true
        )
        let placeholder = body.spilledPlaceholder()
        XCTAssertTrue(placeholder.isPlaceholder)
        XCTAssertEqual(placeholder.text, "first line of a long body", "preview is the first line")
        XCTAssertEqual(placeholder.summary, "sum")
        XCTAssertEqual(placeholder.tool, "Bash")
        XCTAssertEqual(placeholder.callID, "tA")
        XCTAssertEqual(placeholder.truncatedBytes, 42)
        XCTAssertTrue(placeholder.isError)
    }

    /// The wire contract is untouched: `isPlaceholder` never crosses the wire, so a decoded
    /// body is never a placeholder however it was encoded.
    func testIsPlaceholderNeverRoundTripsThroughCoding() throws {
        var body = TimelineItem.Body(text: "x")
        body.isPlaceholder = true
        let data = try JSONEncoder().encode(body)
        let decoded = try JSONDecoder().decode(TimelineItem.Body.self, from: data)
        XCTAssertFalse(decoded.isPlaceholder, "a decoded body is never a placeholder")
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("isPlaceholder"),
                       "the flag is not an encoded key")
    }
}
