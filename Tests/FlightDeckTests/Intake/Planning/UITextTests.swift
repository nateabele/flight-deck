import XCTest
@testable import FlightDeck

/// `UIText`'s pure string transforms, pinned directly rather than only through whatever view
/// happens to call them — `sentenceCase` in particular: fix round 2 caught a comment (not the
/// function) claiming it matched `.capitalized` everywhere, when "stress test" is exactly the
/// case where the two diverge ("Stress test" vs. "Stress Test").
final class UITextTests: XCTestCase {
    func testSentenceCaseUppersOnlyTheFirstLetter() {
        XCTAssertEqual(UIText.sentenceCase("cross-check agent"), "Cross-check agent")
        XCTAssertEqual(UIText.sentenceCase("stress test"), "Stress test")
        XCTAssertEqual(UIText.sentenceCase("reviewer"), "Reviewer")
        XCTAssertEqual(UIText.sentenceCase(""), "")
    }
}
