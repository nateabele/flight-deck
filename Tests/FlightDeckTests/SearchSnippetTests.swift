import XCTest
@testable import FlightDeck

/// Turning FTS5's marked-up snippet into something the row can draw.
///
/// The markers are U+0002/U+0003 rather than anything printable because the marked-up text
/// is arbitrary conversation content — an agent discussing HTML would otherwise produce a
/// snippet that highlights the wrong span.
final class SearchSnippetTests: XCTestCase {
    private func runs(_ attributed: AttributedString) -> [(String, Bool)] {
        attributed.runs.map { run in
            (String(attributed[run.range].characters), run.inlinePresentationIntent == .stronglyEmphasized)
        }
    }

    func testSentinelsBecomeEmphasisAndAreRemoved() {
        let result = SearchSnippet.attributed("don't fire a \u{2}rename\u{3} when")

        XCTAssertFalse(String(result.characters).contains(SnippetSentinel.open))
        XCTAssertFalse(String(result.characters).contains(SnippetSentinel.close))
        XCTAssertEqual(String(result.characters), "don't fire a rename when")
        XCTAssertEqual(runs(result).filter(\.1).map(\.0), ["rename"])
    }

    func testEveryMatchedTermIsEmphasised() {
        let result = SearchSnippet.attributed("\u{2}Rename\u{3} and \u{2}rename\u{3} again")
        XCTAssertEqual(runs(result).filter(\.1).map(\.0), ["Rename", "rename"])
    }

    func testTextWithNoSentinelsIsUnchangedAndUnemphasised() {
        let result = SearchSnippet.attributed("no markers here")

        XCTAssertEqual(String(result.characters), "no markers here")
        XCTAssertTrue(runs(result).filter(\.1).isEmpty)
    }

    /// A snippet truncated by FTS5's window can end mid-highlight. An unbalanced sentinel
    /// must degrade to plain text, never drop the rest of the line.
    func testAnUnclosedSentinelDoesNotSwallowTheRemainder() {
        let result = SearchSnippet.attributed("a \u{2}rename that never closes")
        XCTAssertEqual(String(result.characters), "a rename that never closes")
    }
}
