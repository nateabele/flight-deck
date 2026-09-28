import AppKit
import XCTest
@testable import FlightDeck

final class MarkdownStylerTests: XCTestCase {
    private let sample = """
    # Title

    Some **bold** and *it* and `code` and [link](http://x).

    - one
    * two
    1. three

    ```swift
    let x = 1
    ```

    | a | bb |
    |---|---|
    | ccc | d |

    """

    func testBlocksForHeadingsListsCodeTables() {
        let kinds = MarkdownStyler.blocks(sample).map(\.kind)
        XCTAssertEqual(kinds, [.heading(1), .blank, .paragraph, .blank, .listItem, .listItem, .listItem, .blank,
                               .code, .blank, .table])
        let blocks = MarkdownStyler.blocks(sample)
        let ns = sample as NSString
        XCTAssertEqual(ns.substring(with: blocks[0].range), "# Title")
        XCTAssertEqual(ns.substring(with: blocks[8].range), "```swift\nlet x = 1\n```")
        XCTAssertEqual(ns.substring(with: blocks[10].range), "| a | bb |\n|---|---|\n| ccc | d |")
        // A rule and a line opening with bold are neither list items nor headings.
        XCTAssertEqual(MarkdownStyler.blocks("---\n**b** x\n#nospace").map(\.kind), [.paragraph])
        // An unclosed fence runs to the end rather than un-fencing the rest.
        XCTAssertEqual(MarkdownStyler.blocks("```\n# not a heading").map(\.kind), [.code])
    }

    func testSyntaxRangesForBoldAndHeadings() {
        let text = "## Head **b**\nplain *i* `c` [t](u)"
        let blocks = MarkdownStyler.blocks(text)
        XCTAssertEqual(blocks.map(\.kind), [.heading(2), .paragraph])
        let ns = text as NSString
        XCTAssertEqual(blocks[0].syntaxRanges.map { ns.substring(with: $0) }, ["## ", "**", "**"])
        XCTAssertEqual(blocks[0].syntaxRanges, [NSRange(location: 0, length: 3), NSRange(location: 8, length: 2),
                                                NSRange(location: 11, length: 2)])
        XCTAssertEqual(blocks[1].syntaxRanges.map { ns.substring(with: $0) }, ["*", "*", "`", "`", "[", "](u)"])
        XCTAssertEqual(blocks[1].spans.map { ns.substring(with: $0.range) }, ["i", "c", "t"])
        // A list marker stays visible (a hidden "- " would leave no bullet), so it is not syntax.
        let list = MarkdownStyler.blocks("- item **x**")[0]
        XCTAssertEqual(list.marker, NSRange(location: 0, length: 2))
        XCTAssertEqual(list.syntaxRanges.count, 2)
    }

    func testRevealOnlyCaretBlock() {
        let text = "# A **b**\n\n# B **c**"
        let storage = NSTextStorage(string: text)
        let blocks = MarkdownStyler.blocks(text)
        MarkdownStyler.apply(to: storage, blocks: blocks, revealBlock: 0, theme: .standard)
        XCTAssertFalse(hidden(storage, at: 0), "the caret block keeps its '# ' visible")
        XCTAssertFalse(hidden(storage, at: 4), "…and its '**'")
        XCTAssertTrue(hidden(storage, at: 11), "another block hides its '# '")
        XCTAssertTrue(hidden(storage, at: 15), "…and its '**'")
        XCTAssertFalse(hidden(storage, at: 13), "content is never hidden")

        // Moving the caret restyles only the two blocks involved, and swaps which one reveals.
        MarkdownStyler.restyle(storage, blocks: blocks, indices: [0, 2], revealBlock: 2, theme: .standard)
        XCTAssertTrue(hidden(storage, at: 0))
        XCTAssertFalse(hidden(storage, at: 11))
    }

    func testStoredTextUnchangedByStyling() {
        let storage = NSTextStorage(string: sample)
        let blocks = MarkdownStyler.blocks(sample)
        for reveal in [nil, 0, 2, 8, 10] {
            MarkdownStyler.apply(to: storage, blocks: blocks, revealBlock: reveal, theme: .standard)
            XCTAssertEqual(storage.string, sample)
        }
        MarkdownStyler.restyle(storage, blocks: blocks, indices: [0, 4], revealBlock: 4, theme: .standard)
        XCTAssertEqual(storage.string, sample)
    }

    /// Columns line up by kerning each short cell's last character out to the column width —
    /// the text itself is never padded.
    func testTableColumnsAlignedByKernNotPadding() {
        let text = "| a | bb |\n| ccc | d |"
        let storage = NSTextStorage(string: text)
        MarkdownStyler.apply(to: storage, blocks: MarkdownStyler.blocks(text), revealBlock: nil, theme: .standard)
        XCTAssertEqual(storage.string, text)
        let kern = storage.attribute(.kern, at: 3, effectiveRange: nil) as? CGFloat
        XCTAssertEqual(kern ?? 0, 2 * PlanTheme.standard.monoAdvance, accuracy: 0.01, "' a ' pads 2 cells to ' ccc '")
        XCTAssertNil(storage.attribute(.kern, at: 16, effectiveRange: nil), "the widest cell needs no pad")
    }

    /// Typing inside one block leaves every other block's styling alone: only blocks that
    /// differ from the old ones (shifted by the edit) are restyled.
    func testEditRestylesOnlyChangedBlocks() {
        let old = MarkdownStyler.blocks("# A\n\npara\n\n- x")
        let new = MarkdownStyler.blocks("# A\n\npara!\n\n- x")
        XCTAssertEqual(MarkdownStyler.changedBlocks(old: old, new: new, edited: NSRange(location: 9, length: 1), delta: 1), [2])
        // Opening a fence re-kinds everything after it.
        let fenced = MarkdownStyler.blocks("# A\n\n```\n\n- x")
        let changed = MarkdownStyler.changedBlocks(old: old, new: fenced, edited: NSRange(location: 5, length: 3), delta: -1)
        XCTAssertEqual(changed, Array(fenced.indices.dropFirst(2)))
    }

    /// The spec's budget: moving the caret between blocks of a 2,000-line plan restyles within
    /// one 60 Hz frame. Measured on a real TextKit 2 view, so attribute fixing and layout
    /// invalidation are in the timing — a bare `NSTextStorage` would flatter it.
    @MainActor
    func testCaretBlockRestyleWithinAFrameOn2000Lines() {
        var lines: [String] = []
        for i in 0..<250 {
            lines += ["## Section \(i)", "", "Prose with **bold**, *italic*, `code` and [a link](http://x/\(i)).",
                      "- item one", "1. item two", "```", "let x = \(i)", "```"]
        }
        let text = lines.joined(separator: "\n")
        XCTAssertEqual(lines.count, 2000)
        let view = NSTextView(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 800)
        view.string = text
        let storage = view.textStorage!
        let blocks = MarkdownStyler.blocks(text)
        MarkdownStyler.apply(to: storage, blocks: blocks, revealBlock: nil, theme: .standard)

        let clock = ContinuousClock()
        var worst = Duration.zero
        var reveal: Int?
        for location in stride(from: 0, to: storage.length, by: storage.length / 40) {
            let elapsed = clock.measure {
                let next = MarkdownStyler.blockIndex(at: location, in: blocks)
                MarkdownStyler.restyle(storage, blocks: blocks, indices: [reveal, next].compactMap { $0 },
                                       revealBlock: next, theme: .standard)
                reveal = next
            }
            worst = max(worst, elapsed)
        }
        XCTAssertLessThan(worst, .milliseconds(16), "worst caret-block restyle: \(worst)")

        // The keystroke path (full re-parse, diff, restyle what changed) — reported, and held
        // to the same frame budget.
        let keystroke = clock.measure {
            let edited = (text as NSString).replacingCharacters(in: NSRange(location: 20, length: 0), with: "x")
            let fresh = MarkdownStyler.blocks(edited)
            let changed = MarkdownStyler.changedBlocks(old: blocks, new: fresh, edited: NSRange(location: 20, length: 1), delta: 1)
            XCTAssertEqual(changed.count, 1)
        }
        XCTAssertLessThan(keystroke, .milliseconds(16), "keystroke re-parse: \(keystroke)")
        print("PlanEditor timing: worst caret restyle \(worst), keystroke re-parse \(keystroke)")
    }

    private func hidden(_ storage: NSTextStorage, at location: Int) -> Bool {
        let font = storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
        let color = storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
        return (font?.pointSize ?? 13) < 1 && color == .clear
    }
}
