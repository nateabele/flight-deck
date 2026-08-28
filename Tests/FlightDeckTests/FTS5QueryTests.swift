import XCTest
@testable import FlightDeck

/// Typed text is data, never syntax.
///
/// FTS5's MATCH argument is a query language: `NEAR`, `AND`, `OR`, `NOT`, `-`, `*`, `:` and
/// `"` all mean something in it. A search field that passes text straight through either
/// errors out on a stray quote or quietly runs a different query than the one shown. Every
/// token is quoted; only the trailing `*` is ours.
final class FTS5QueryTests: XCTestCase {
    func testEachTokenIsQuotedAndTheLastGetsAPrefixStar() {
        XCTAssertEqual(FTS5Query.match(for: "fix the rename"), #""fix" "the" "rename"*"#)
    }

    /// Prefix matching on the final token is what makes results narrow as you type rather
    /// than appearing only when a word is finished.
    func testASingleTokenIsAPrefixQuery() {
        XCTAssertEqual(FTS5Query.match(for: "renam"), #""renam"*"#)
    }

    /// Punctuation inside a token must survive as literal text. `unicode61` will split it
    /// into terms itself; what matters is that FTS5 never reads the `.` as syntax.
    func testPunctuationInsideATokenIsPreserved() {
        XCTAssertEqual(FTS5Query.match(for: "SessionStore.rename"), #""SessionStore.rename"*"#)
    }

    /// The crash case. A bare double quote terminates the quoted string and leaves FTS5
    /// parsing the remainder as syntax; doubling it is FTS5's own escape.
    func testEmbeddedQuotesAreDoubledRatherThanTerminatingTheToken() {
        XCTAssertEqual(FTS5Query.match(for: #"say "hi""#), #""say" """hi"""*"#)
    }

    /// Reserved words are only reserved when bare. Quoted, they are the words the user
    /// typed — which is what someone searching for the phrase "near miss" means.
    func testReservedWordsAreNeutralisedByQuoting() {
        XCTAssertEqual(FTS5Query.match(for: "near miss"), #""near" "miss"*"#)
        XCTAssertEqual(FTS5Query.match(for: "this AND that"), #""this" "AND" "that"*"#)
    }

    /// A leading `-` is FTS5 negation. Someone typing a flag name is not asking to exclude
    /// anything.
    func testALeadingHyphenIsNotNegation() {
        XCTAssertEqual(FTS5Query.match(for: "--resume"), #""--resume"*"#)
    }

    /// A star the user typed is a literal star, not a second prefix operator — otherwise
    /// `a*b` becomes a syntax error.
    func testUserSuppliedStarsAreLiteral() {
        XCTAssertEqual(FTS5Query.match(for: "a*b"), #""a*b"*"#)
    }

    /// Nothing to search for is not an error and not an empty match-everything query — it
    /// is the empty-query state, which shows recent sessions instead (§7).
    func testBlankInputProducesNoQuery() {
        XCTAssertNil(FTS5Query.match(for: ""))
        XCTAssertNil(FTS5Query.match(for: "   \n\t "))
    }

    func testRunsOfWhitespaceCollapse() {
        XCTAssertEqual(FTS5Query.match(for: "  fix   rename  "), #""fix" "rename"*"#)
    }
}
