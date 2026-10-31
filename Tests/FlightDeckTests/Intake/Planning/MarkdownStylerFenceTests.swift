import AppKit
import XCTest
@testable import FlightDeck

/// The fence rules the visual blocks (planning v2 §7) hang on: a fence's info string is read, a
/// closing fence must match the opening one's character and be at least as long, and `fd-visual`
/// opens a visual block. The first half pins what plans parsed as BEFORE any of that — it is
/// written against the old parser and must keep passing, because a plan that already exists
/// must not change under the user.
final class MarkdownStylerFenceTests: XCTestCase {
    /// A block's kind as a stable word, so the "before" expectations below do not name `.visual`
    /// and compile against the parser that predates it.
    private func label(_ kind: MarkdownBlock.Kind) -> String {
        switch kind {
        case .heading(let level): "h\(level)"
        case .paragraph: "p"
        case .listItem: "li"
        case .code: "code"
        case .table: "table"
        case .quote: "quote"
        case .blank: "blank"
        default: "other"
        }
    }

    private func summary(_ text: String) -> [String] {
        let ns = text as NSString
        return MarkdownStyler.blocks(text).map { b in
            let word = label(b.kind)
            return word == "code" ? "code[\(ns.substring(with: b.range))]" : word
        }
    }

    // MARK: - Existing plans parse as they always did

    private static let ordinaryPlan = """
    # Add retry to the uploader

    ## Approach

    Wrap `Uploader.send` in a **bounded** retry; see [the design](docs/retry.md).

    - Back off 1s, 2s, 4s
    - Give up after three tries

    ```swift
    func send() async throws {
        try await retry(times: 3) { try await post() }
    }
    ```

    ## Risks

    > A retry on a non-idempotent call double-charges.

    | call | idempotent |
    |---|---|
    | POST /pay | no |

    ~~~
    plain tilde fence
    ~~~

    Done.
    """

    func testAnOrdinaryPlanParsesAsItAlwaysDid() {
        XCTAssertEqual(summary(Self.ordinaryPlan), [
            "h1", "blank", "h2", "blank", "p", "blank", "li", "li", "blank",
            "code[```swift\nfunc send() async throws {\n    try await retry(times: 3) { try await post() }\n}\n```]",
            "blank", "h2", "blank", "quote", "blank", "table", "blank",
            "code[~~~\nplain tilde fence\n~~~]", "blank", "p",
        ])
    }

    func testAnUnclosedFenceStillRunsToTheEnd() {
        XCTAssertEqual(summary("Intro\n\n```\n# not a heading\n- not a list"), ["p", "blank", "code[```\n# not a heading\n- not a list]"])
    }

    func testAFenceWithAnInfoStringIsStillOneCodeBlock() {
        XCTAssertEqual(summary("```json {\"a\": 1}\n{}\n```"), ["code[```json {\"a\": 1}\n{}\n```]"])
    }

    func testAnIndentedFenceAndAFourSpaceLineBehaveAsBefore() {
        XCTAssertEqual(summary("   ```\n   x\n   ```"), ["code[   ```\n   x\n   ```]"])
        XCTAssertEqual(summary("    ```\n    x"), ["p"])
    }

    func testTwoBackticksAreNotAFence() {
        XCTAssertEqual(summary("``\nx\n``"), ["p"])
    }

    func testAnEditedPlanReparsesTheSameAsAFreshParse() {
        // The incremental parse resumes mid-plan; a fence rule that carried state across the
        // resume point would make this differ.
        let old = Self.ordinaryPlan
        let edited = old.replacingOccurrences(of: "Done.", with: "Done and dusted.")
        let delta = edited.utf16.count - old.utf16.count
        let at = (old as NSString).range(of: "Done.")
        let incremental = MarkdownStyler.blocks(edited, after: MarkdownStyler.blocks(old),
                                                edited: NSRange(location: at.location, length: at.length + delta), delta: delta)
        XCTAssertEqual(incremental, MarkdownStyler.blocks(edited))
    }

    // MARK: - The new rules

    private func visuals(_ text: String) -> [MarkdownBlock.Kind] {
        MarkdownStyler.blocks(text).map(\.kind).filter { if case .visual = $0 { true } else { false } }
    }

    func testAnFdVisualFenceIsAVisualBlockWithItsId() {
        let text = "Intro\n\n```fd-visual id=pairing-handshake\nPairing handshake: phone, Mac and hostd\n```\n\nAfter"
        let blocks = MarkdownStyler.blocks(text)
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .blank, .visual(id: "pairing-handshake", pending: false), .blank, .paragraph])
        // Same range and hidden fences as a code block: the plan is still plain text.
        XCTAssertEqual((text as NSString).substring(with: blocks[2].range),
                       "```fd-visual id=pairing-handshake\nPairing handshake: phone, Mac and hostd\n```")
        XCTAssertEqual(blocks[2].syntaxRanges.count, 2)
    }

    func testPendingMarksAPlaceholder() {
        XCTAssertEqual(visuals("```fd-visual id=x pending\ncaption\n```"), [.visual(id: "x", pending: true)])
        XCTAssertEqual(visuals("```fd-visual pending id=x\n```"), [.visual(id: "x", pending: true)])
    }

    func testAnFdVisualWithNoUsableIdIsOrdinaryCode() {
        for info in ["fd-visual", "fd-visual id=", "fd-visual id=../../etc", "fd-visualx id=a", "fd-visual-2 id=a", "FD-VISUAL id=a"] {
            XCTAssertEqual(MarkdownStyler.blocks("```\(info)\nx\n```").map(\.kind), [.code], info)
        }
    }

    func testTildesOpenAVisualToo() {
        XCTAssertEqual(visuals("~~~fd-visual id=a\ncap\n~~~"), [.visual(id: "a", pending: false)])
    }

    func testAClosingFenceMustMatchTheOpeningCharacter() {
        // A ~~~ line does not close a ``` block: it is code inside it.
        XCTAssertEqual(summary("```\n~~~\nstill code\n```\nafter"), ["code[```\n~~~\nstill code\n```]", "p"])
        XCTAssertEqual(summary("~~~\n```\nstill code\n~~~"), ["code[~~~\n```\nstill code\n~~~]"])
    }

    func testAClosingFenceMustBeAtLeastAsLongAsTheOpeningOne() {
        let text = "Example:\n\n````markdown\n```swift\nlet x = 1\n```\n````\n\nAfter."
        XCTAssertEqual(summary(text), ["p", "blank", "code[````markdown\n```swift\nlet x = 1\n```\n````]", "blank", "p"])
        // Longer than the opening still closes it.
        XCTAssertEqual(summary("```\nx\n`````\nafter"), ["code[```\nx\n`````]", "p"])
    }

    func testAVisualFenceShownInsideALongerFenceIsJustCode() {
        let text = "````markdown\n```fd-visual id=a\ncap\n```\n````"
        XCTAssertEqual(MarkdownStyler.blocks(text).map(\.kind), [.code])
    }

    func testAVisualOpenedByTypingAndNeverClosedRunsToTheEnd() {
        XCTAssertEqual(MarkdownStyler.blocks("```fd-visual id=a\n# not a heading").map(\.kind), [.visual(id: "a", pending: false)])
    }

    func testAVisualBlockSurvivesAnIncrementalReparse() {
        let old = "# T\n\n```fd-visual id=a\ncap\n```\n\nTail"
        let edited = old.replacingOccurrences(of: "Tail", with: "Tail!")
        let at = (old as NSString).range(of: "Tail")
        let incremental = MarkdownStyler.blocks(edited, after: MarkdownStyler.blocks(old),
                                                edited: NSRange(location: at.location, length: at.length + 1), delta: 1)
        XCTAssertEqual(incremental, MarkdownStyler.blocks(edited))
        XCTAssertEqual(visuals(edited), [.visual(id: "a", pending: false)])
    }

    // MARK: - CommonMark closing and opening (M1)

    func testAClosingFenceCannotCarryAnInfoString() {
        // "```swift" inside an open fence is code, not the end of it.
        XCTAssertEqual(summary("```\nx\n```swift\ny\n```\nafter"), ["code[```\nx\n```swift\ny\n```]", "p"])
    }

    func testABacktickFenceWhoseInfoContainsABacktickIsNotAFence() {
        // It is inline code on a line of prose, as the phone's reader sees it.
        XCTAssertEqual(summary("```code``` and more\ntext"), ["p"])
        // A tilde fence may contain a backtick in its info.
        XCTAssertEqual(summary("~~~a`b\nx\n~~~"), ["code[~~~a`b\nx\n~~~]"])
    }

    func testAnUppercaseIdIsNotAVisual() {
        XCTAssertEqual(MarkdownStyler.blocks("```fd-visual id=Foo\nx\n```").map(\.kind), [.code])
    }
}
