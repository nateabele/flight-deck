import AppKit
import XCTest
@testable import FlightDeck

/// A proposed edit drawn in place of its paragraph (D17): the styler hides the source and holds
/// it to the proposal's height, as it does a table row's.
@MainActor
final class PlanProposalTests: XCTestCase {
    private func theme() -> PlanTheme {
        var theme = PlanTheme.standard
        theme.contentWidth = 320
        return theme
    }

    private let text = "# Title\n\nFirst line of the paragraph\nsecond line of it, with the old words.\n\nA different block."

    private func styled(proposals: [PlanProposal], reveal: Int? = nil) -> (NSTextStorage, [MarkdownBlock]) {
        let storage = NSTextStorage(string: text)
        let blocks = MarkdownStyler.blocks(text)
        MarkdownStyler.apply(to: storage, blocks: blocks, revealBlock: reveal, proposals: proposals, theme: theme())
        return (storage, blocks)
    }

    private func proposal(for blocks: [MarkdownBlock], new: String) -> PlanProposal {
        let block = blocks.first { $0.kind == .paragraph }!
        return PlanProposal(diff: UUID(), block: block.range, source: new, old: (text as NSString).substring(with: block.range))
    }

    func testAParagraphWithAProposalIsHiddenAndHeldToTheProposedHeight() throws {
        let blocks = MarkdownStyler.blocks(text)
        let p = proposal(for: blocks, new: "A shorter paragraph.")
        let (storage, _) = styled(proposals: [p])
        let start = p.block.location
        let ref = try XCTUnwrap(storage.attribute(.planProposal, at: start, effectiveRange: nil) as? PlanProposalRef)
        XCTAssertTrue(ref.lead)
        let style = try XCTUnwrap(storage.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.minimumLineHeight, ref.layout.restHeight, accuracy: 0.01)
        XCTAssertEqual(style.maximumLineHeight, ref.layout.restHeight, accuracy: 0.01)
        XCTAssertGreaterThan(ref.layout.restHeight, 10)
        XCTAssertEqual(storage.attribute(.foregroundColor, at: start, effectiveRange: nil) as? NSColor, .clear, "the source is not drawn")
        // The second source line of the same block takes no room of its own.
        let second = start + ("First line of the paragraph\n" as NSString).length
        let rest = try XCTUnwrap(storage.attribute(.planProposal, at: second, effectiveRange: nil) as? PlanProposalRef)
        XCTAssertFalse(rest.lead)
        let restStyle = try XCTUnwrap(storage.attribute(.paragraphStyle, at: second, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertLessThan(restStyle.maximumLineHeight, 0.01)
        // Other blocks are untouched.
        XCTAssertNil(storage.attribute(.planProposal, at: 0, effectiveRange: nil))
        XCTAssertNil(storage.attribute(.planProposal, at: (text as NSString).range(of: "A different").location, effectiveRange: nil))
    }

    func testTheReservedHeightFollowsTheProposedText() {
        let blocks = MarkdownStyler.blocks(text)
        let short = PlanProposalLayout(source: "Short.", old: "x", theme: theme(), width: 320)
        let long = PlanProposalLayout(source: String(repeating: "A much longer proposal that wraps. ", count: 8), old: "x",
                                      theme: theme(), width: 320)
        XCTAssertGreaterThan(long.restHeight, short.restHeight * 2)
        _ = blocks
    }

    func testUnderThePointerTheRoomOpensForTheOldTextAndTheToolbar() {
        let layout = PlanProposalLayout(source: "New words.", old: "Old words that were there before.", theme: theme(), width: 320)
        XCTAssertGreaterThan(layout.hoverHeight, layout.restHeight + PlanProposalLayout.toolbarRow)
        XCTAssertEqual(layout.height(hovered: false), layout.restHeight)
        XCTAssertEqual(layout.height(hovered: true), layout.hoverHeight)
    }

    func testTheSourceShowsAgainWhileTheCaretIsInTheParagraph() {
        let blocks = MarkdownStyler.blocks(text)
        let p = proposal(for: blocks, new: "Something else.")
        let at = blocks.firstIndex { $0.kind == .paragraph }!
        let (storage, _) = styled(proposals: [p], reveal: at)
        XCTAssertNil(storage.attribute(.planProposal, at: p.block.location, effectiveRange: nil))
        XCTAssertNotEqual(storage.attribute(.foregroundColor, at: p.block.location, effectiveRange: nil) as? NSColor, .clear)
    }

    func testAProposalForAnotherBlockRangeDoesNothing() {
        let blocks = MarkdownStyler.blocks(text)
        var p = proposal(for: blocks, new: "x")
        p = PlanProposal(diff: p.diff, block: NSRange(location: p.block.location + 1, length: p.block.length), source: "x", old: "y")
        let (storage, _) = styled(proposals: [p])
        XCTAssertNil(storage.attribute(.planProposal, at: p.block.location, effectiveRange: nil))
    }

    func testATableOrACodeBlockIsNotDrawnInPlace() {
        let tableText = "| a | b |\n| - | - |\n| 1 | 2 |\n"
        let storage = NSTextStorage(string: tableText)
        let blocks = MarkdownStyler.blocks(tableText)
        let p = PlanProposal(diff: UUID(), block: blocks[0].range, source: "x", old: "y")
        MarkdownStyler.apply(to: storage, blocks: blocks, revealBlock: nil, proposals: [p], theme: theme())
        XCTAssertNil(storage.attribute(.planProposal, at: 0, effectiveRange: nil), "tables keep the bar and the card")
    }

    func testTheCacheKeyFollowsTheThemesTypeface() {
        var big = theme()
        big.body = PlanTheme.serif(22)
        var sans = theme()
        sans.body = NSFont.systemFont(ofSize: 16)
        let base = PlanProposalLayout.cacheKey(source: "s", old: "o", theme: theme(), width: 320)
        XCTAssertNotEqual(base, PlanProposalLayout.cacheKey(source: "s", old: "o", theme: big, width: 320), "font size")
        XCTAssertNotEqual(base, PlanProposalLayout.cacheKey(source: "s", old: "o", theme: sans, width: 320), "font family")
        XCTAssertNotEqual(base, PlanProposalLayout.cacheKey(source: "s", old: "o", theme: theme(), width: 400), "width")
        XCTAssertEqual(base, PlanProposalLayout.cacheKey(source: "s", old: "o", theme: theme(), width: 320))
        let a = PlanProposalLayout.cached(source: "A longer line of words to wrap across the width.", old: "o", theme: theme(), width: 320)
        let b = PlanProposalLayout.cached(source: "A longer line of words to wrap across the width.", old: "o", theme: big, width: 320)
        XCTAssertGreaterThan(b.restHeight, a.restHeight, "a bigger type must not get the smaller type's cached height")
    }

    func testProposalsMoveWithAnEditAboveThemAndDropWhenTheEditIsInside() {
        let p = PlanProposal(diff: UUID(), block: NSRange(location: 40, length: 20), source: "s", old: "o", hovered: true)
        let above = PlanProposal.moved([p], by: TextEdit(range: NSRange(location: 5, length: 3), delta: 3))
        XCTAssertEqual(above.map(\.block), [NSRange(location: 43, length: 20)])
        XCTAssertEqual(above.first?.diff, p.diff)
        XCTAssertEqual(above.first?.hovered, true)
        let below = PlanProposal.moved([p], by: TextEdit(range: NSRange(location: 100, length: 1), delta: 1))
        XCTAssertEqual(below.map(\.block), [p.block])
        let inside = PlanProposal.moved([p], by: TextEdit(range: NSRange(location: 45, length: 1), delta: 1))
        XCTAssertTrue(inside.isEmpty, "an edit inside the block reveals its source; the refresh lays the proposal again")
    }
}
