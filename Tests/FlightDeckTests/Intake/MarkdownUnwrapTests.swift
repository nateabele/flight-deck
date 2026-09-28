import XCTest
import IntakeKit

/// `MarkdownUnwrap`: the seats hard-wrap plan prose at ~80–100 columns, and a hard-wrapped
/// paragraph reflows into ragged half-lines the moment the human edits it in the plan editor.
/// Every case here is a construct whose line breaks MEAN something and must survive, or a
/// soft wrap that must not.
final class MarkdownUnwrapTests: XCTestCase {
    func assertUnwrap(_ input: String, _ expected: String, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let once = MarkdownUnwrap.unwrap(input)
        XCTAssertEqual(once, expected, message, file: file, line: line)
        XCTAssertEqual(MarkdownUnwrap.unwrap(once), once, "idempotent: \(message)", file: file, line: line)
    }

    // MARK: - Joined

    func testParagraphJoinsIntoOneLine() {
        assertUnwrap("The sync engine polls every\nminute and backs off on\nfailure.\n",
                     "The sync engine polls every minute and backs off on failure.\n")
    }

    func testParagraphsStaySeparatedByTheirBlankLine() {
        assertUnwrap("One two\nthree.\n\nFour five\nsix.", "One two three.\n\nFour five six.")
    }

    func testListItemContinuationJoinsUnderItsItem() {
        assertUnwrap("- First item wraps\n  onto a second line\n- Second item\n  also wraps\n",
                     "- First item wraps onto a second line\n- Second item also wraps\n")
        assertUnwrap("1. Ordered item\n   continues here\n2) Another\n   one\n",
                     "1. Ordered item continues here\n2) Another one\n")
    }

    func testNestedListKeepsItsStructure() {
        assertUnwrap("""
        - Parent item that
          wraps
          - Child item that
            also wraps
          - Second child
        - Next parent
        """, """
        - Parent item that wraps
          - Child item that also wraps
          - Second child
        - Next parent
        """)
    }

    func testSecondParagraphOfAListItemJoinsButStaysInTheItem() {
        assertUnwrap("- Item\n\n  Second paragraph\n  wrapped.\n- Next\n", "- Item\n\n  Second paragraph wrapped.\n- Next\n")
    }

    func testBlockquoteJoinsWithinTheQuote() {
        assertUnwrap("> Quoted text that\n> wraps twice\n> here.\n\nAfter.", "> Quoted text that wraps twice here.\n\nAfter.")
        assertUnwrap("> > Nested quote\n> > wraps\n> Outer\n", "> > Nested quote wraps\n> Outer\n", "a depth change is a boundary")
        assertUnwrap("> - Quoted item\n>   wraps\n", "> - Quoted item wraps\n")
    }

    func testTrailingSingleSpaceAndIndentAreNotDoubled() {
        assertUnwrap("Ends with a space \n    and an indented continuation\n", "Ends with a space and an indented continuation\n")
        assertUnwrap("Tab\t\nnext", "Tab next")
    }

    func testCRLFIsJoinedAndKeptCRLF() {
        assertUnwrap("# Plan\r\n\r\nOne two\r\nthree.\r\n- item\r\n  more\r\n", "# Plan\r\n\r\nOne two three.\r\n- item more\r\n")
    }

    // MARK: - Untouched

    func testFencedCodeIsUntouched() {
        let fenced = "Before the\nfence.\n\n```swift\nlet a = 1\nlet b = 2\n```\n\n~~~~\nraw\ntext\n~~~~\n"
        assertUnwrap(fenced, "Before the fence.\n\n```swift\nlet a = 1\nlet b = 2\n```\n\n~~~~\nraw\ntext\n~~~~\n")
        assertUnwrap("- Item\n  ```\n  code\n  more\n  ```\n", "- Item\n  ```\n  code\n  more\n  ```\n", "a fence inside an item")
        assertUnwrap("```\nunclosed\nfence\n", "```\nunclosed\nfence\n")
    }

    func testIndentedCodeIsUntouched() {
        assertUnwrap("Para.\n\n    code line one\n    code line two\n\nAfter.\n", "Para.\n\n    code line one\n    code line two\n\nAfter.\n")
    }

    func testTablesAreUntouched() {
        let table = "| Seat | Model |\n| --- | :---: |\n| drafter | codex |\n| synth | claude |\n"
        assertUnwrap("Intro\nline.\n\n" + table, "Intro line.\n\n" + table)
        assertUnwrap("Seat | Model\n--- | ---\na | b\n", "Seat | Model\n--- | ---\na | b\n", "a table without outer pipes")
    }

    func testHeadingsAreNeverJoined() {
        assertUnwrap("# Title\n## Section\nBody text\nwraps.\n### Next\nMore.\n", "# Title\n## Section\nBody text wraps.\n### Next\nMore.\n")
        assertUnwrap("Setext title\n============\nBody\n\nOther\n-----\n", "Setext title\n============\nBody\n\nOther\n-----\n")
    }

    func testThematicBreakIsNeverJoined() {
        assertUnwrap("Above\n***\nBelow\n\n- - -\n", "Above\n***\nBelow\n\n- - -\n")
    }

    func testHTMLBlocksAreUntouched() {
        assertUnwrap("<details>\n<summary>More</summary>\nhidden\ntext\n</details>\n\nPara\njoins.\n",
                     "<details>\n<summary>More</summary>\nhidden\ntext\n</details>\n\nPara joins.\n")
        assertUnwrap("<!-- a comment\nthat spans\n\nlines -->\nText\nhere\n", "<!-- a comment\nthat spans\n\nlines -->\nText here\n")
    }

    func testFrontMatterIsUntouched() {
        assertUnwrap("---\ntitle: Plan\ntags:\n  - a\n---\nBody\ntext\n", "---\ntitle: Plan\ntags:\n  - a\n---\nBody text\n")
    }

    func testHardBreaksStayExplicit() {
        assertUnwrap("Two spaces  \nkeep the break\nbut this joins\n", "Two spaces  \nkeep the break but this joins\n")
        assertUnwrap("Backslash\\\nkeeps too\n", "Backslash\\\nkeeps too\n")
    }

    func testListItemBoundariesAndBlankLinesSurvive() {
        let list = "- a\n- b\n\n\n* c\n+ d\n10. e\n"
        assertUnwrap(list, list)
    }

    func testLinkReferenceDefinitionsAreUntouched() {
        assertUnwrap("See [the spec][s]\nfor more.\n\n[s]: https://example.com/spec\n[t]: https://example.com/t \"Title\"\n",
                     "See [the spec][s] for more.\n\n[s]: https://example.com/spec\n[t]: https://example.com/t \"Title\"\n")
    }

    func testAlreadyUnwrappedIsUnchanged() {
        let plan = "# Plan\n\n## Scope\n\nOne paragraph on one line.\n\n- item one\n- item two\n"
        XCTAssertEqual(MarkdownUnwrap.unwrap(plan), plan)
        XCTAssertEqual(MarkdownUnwrap.unwrap(""), "")
    }

    /// The shape a seat actually hands back — every construct at once — reaches a fixed point in
    /// one pass.
    func testRealisticWrappedPlanIsIdempotent() {
        let wrapped = """
        ---
        intake: fieldOS
        ---
        # Offline sync

        ## Goals
        Make the field app usable with no signal: every form a technician fills in is
        saved locally first and synced when the device is back online, without the
        technician having to think about it.

        1. Queue writes in SQLite, keyed by
           form id.
           - Retries back off exponentially,
             capped at 5 minutes.
        2. Surface a pending badge.

        > Open question: do we need conflict
        > resolution beyond last-write-wins?

        | Table | Rows |
        |-------|------|
        | forms | ~10k |

        ```sql
        CREATE TABLE queue (id TEXT,
          body BLOB);
        ```

        Line with a hard break\u{20}\u{20}
        stays two lines.
        """
        let once = MarkdownUnwrap.unwrap(wrapped)
        XCTAssertEqual(MarkdownUnwrap.unwrap(once), once)
        XCTAssertTrue(once.contains("Make the field app usable with no signal: every form a technician fills in is saved locally first and synced when the device is back online, without the technician having to think about it.\n"), once)
        XCTAssertTrue(once.contains("1. Queue writes in SQLite, keyed by form id.\n   - Retries back off exponentially, capped at 5 minutes.\n2. Surface"), once)
        XCTAssertTrue(once.contains("> Open question: do we need conflict resolution beyond last-write-wins?\n"), once)
        XCTAssertTrue(once.contains("CREATE TABLE queue (id TEXT,\n  body BLOB);"), once)
        XCTAssertTrue(once.contains("---\nintake: fieldOS\n---\n# Offline sync"), once)
        XCTAssertTrue(once.contains("Line with a hard break  \nstays two lines."), once)
    }
}
