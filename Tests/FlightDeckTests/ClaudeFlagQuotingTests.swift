import XCTest
@testable import FlightDeck

final class ClaudeFlagQuotingTests: XCTestCase {
    // MARK: tokenize

    func testSplitsOnWhitespace() throws {
        XCTAssertEqual(try ClaudeFlagQuoting.tokenize("--model opus"), ["--model", "opus"])
    }

    func testCollapsesRunsOfWhitespaceAndTrims() throws {
        XCTAssertEqual(try ClaudeFlagQuoting.tokenize("  --a   --b  "), ["--a", "--b"])
    }

    func testSingleQuotesPreserveSpacesAndAreLiteral() throws {
        XCTAssertEqual(
            try ClaudeFlagQuoting.tokenize("--name 'my session $x'"),
            ["--name", "my session $x"]
        )
    }

    func testDoubleQuotesPreserveSpaces() throws {
        XCTAssertEqual(try ClaudeFlagQuoting.tokenize("--name \"a b\""), ["--name", "a b"])
    }

    func testBackslashEscapeInsideDoubleQuotes() throws {
        XCTAssertEqual(try ClaudeFlagQuoting.tokenize("\"a\\\"b\""), ["a\"b"])
    }

    func testBackslashEscapeOutsideQuotes() throws {
        XCTAssertEqual(try ClaudeFlagQuoting.tokenize("a\\ b"), ["a b"])
    }

    func testAdjacentQuotedRunsConcatenateIntoOneToken() throws {
        XCTAssertEqual(try ClaudeFlagQuoting.tokenize("'a'b'c'"), ["abc"])
    }

    func testEmptyQuotedStringIsAToken() throws {
        XCTAssertEqual(try ClaudeFlagQuoting.tokenize("--tools ''"), ["--tools", ""])
    }

    func testEmptyInputProducesNoTokens() throws {
        XCTAssertEqual(try ClaudeFlagQuoting.tokenize("   "), [])
    }

    func testUnterminatedSingleQuoteThrows() {
        XCTAssertThrowsError(try ClaudeFlagQuoting.tokenize("--name 'oops")) { error in
            XCTAssertEqual(error as? ClaudeFlagQuoting.TokenizeError, .unterminatedQuote)
        }
    }

    func testUnterminatedDoubleQuoteThrows() {
        XCTAssertThrowsError(try ClaudeFlagQuoting.tokenize("--name \"oops")) { error in
            XCTAssertEqual(error as? ClaudeFlagQuoting.TokenizeError, .unterminatedQuote)
        }
    }

    // MARK: quoteIfNeeded

    func testSafeValueIsNotQuoted() {
        XCTAssertEqual(ClaudeFlagQuoting.quoteIfNeeded("opus"), "opus")
        XCTAssertEqual(ClaudeFlagQuoting.quoteIfNeeded("../shared/dir"), "../shared/dir")
        XCTAssertEqual(ClaudeFlagQuoting.quoteIfNeeded("a-b_c.d:e=f@g%h+i,j"), "a-b_c.d:e=f@g%h+i,j")
    }

    func testValueWithSpaceIsSingleQuoted() {
        XCTAssertEqual(ClaudeFlagQuoting.quoteIfNeeded("my session"), "'my session'")
    }

    func testShellMetacharactersAreQuotedNotStripped() {
        XCTAssertEqual(ClaudeFlagQuoting.quoteIfNeeded("$HOME"), "'$HOME'")
        XCTAssertEqual(ClaudeFlagQuoting.quoteIfNeeded("a;b"), "'a;b'")
    }

    func testEmbeddedSingleQuoteIsEscaped() {
        XCTAssertEqual(ClaudeFlagQuoting.quoteIfNeeded("it's"), "'it'\\''s'")
    }

    func testEmptyStringBecomesEmptyQuotes() {
        XCTAssertEqual(ClaudeFlagQuoting.quoteIfNeeded(""), "''")
    }

    // MARK: the invariant these two exist to uphold

    func testQuoteThenTokenizeRoundTripsIncludingInjectionAttempt() throws {
        let hostile = "'; rm -rf ~; '"
        let quoted = ClaudeFlagQuoting.quoteIfNeeded(hostile)
        XCTAssertEqual(try ClaudeFlagQuoting.tokenize(quoted), [hostile])
    }

    func testQuoteThenTokenizeRoundTripsAcrossAwkwardValues() throws {
        for value in ["a b", "", "$(whoami)", "back\\slash", "new\nline", "quote\"dq", "it's"] {
            let quoted = ClaudeFlagQuoting.quoteIfNeeded(value)
            XCTAssertEqual(try ClaudeFlagQuoting.tokenize(quoted), [value], "failed for \(value)")
        }
    }
}
