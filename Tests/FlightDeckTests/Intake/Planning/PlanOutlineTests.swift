import AppKit
import XCTest
@testable import FlightDeck

/// The plan's outline — its sections as the block parse sees them — and the fold state kept
/// over it. Pure: no view, no layout.
final class PlanOutlineTests: XCTestCase {
    private func headings(_ text: String) -> [PlanHeading] {
        PlanOutline.headings(MarkdownStyler.blocks(text), in: text as NSString)
    }

    private func sub(_ text: String, _ r: NSRange) -> String { (text as NSString).substring(with: r) }

    func testSectionsRunToTheNextHeadingOfTheSameOrHigherLevel() {
        let text = "# Title\nintro\n## A\na body\n### A.1\ndeep\n## B\nb body\n"
        let h = headings(text)
        XCTAssertEqual(h.map(\.title), ["Title", "A", "A.1", "B"])
        XCTAssertEqual(h.map(\.level), [1, 2, 3, 2])
        XCTAssertEqual(sub(text, h[1].body), "a body\n### A.1\ndeep\n", "a ## section holds its ### subsections")
        XCTAssertEqual(sub(text, h[2].body), "deep\n", "a ### section ends at the next ##")
        XCTAssertEqual(sub(text, h[3].body), "b body\n", "the last section runs to the end")
        XCTAssertEqual(sub(text, h[0].body), "intro\n## A\na body\n### A.1\ndeep\n## B\nb body\n", "# holds everything")
    }

    func testAHashInsideACodeFenceIsNotAHeading() {
        let text = "## Rules\n```sh\n# not a heading\necho\n```\nafter\n## Next\nx"
        let h = headings(text)
        XCTAssertEqual(h.map(\.title), ["Rules", "Next"])
        XCTAssertEqual(sub(text, h[0].body), "```sh\n# not a heading\necho\n```\nafter\n")
    }

    func testAHeadingWithNothingUnderItHasAnEmptyBody() {
        let text = "## A\n## B\nb"
        let h = headings(text)
        XCTAssertEqual(h[0].body.length, 0)
        XCTAssertEqual(sub(text, h[1].body), "b")
        XCTAssertEqual(headings("## Last").first?.body.length, 0, "a heading on the last line, no newline")
    }

    func testRepeatedHeadingsAreKeyedByOccurrence() {
        let text = "## A\n### Tests\nx\n## B\n### Tests\ny"
        let keys = headings(text).map(\.key)
        XCTAssertEqual(keys[1], PlanFoldKey(text: "### Tests", occurrence: 0))
        XCTAssertEqual(keys[3], PlanFoldKey(text: "### Tests", occurrence: 1))
        XCTAssertEqual(Set(keys).count, 4)
    }

    func testInnermostSectionHoldingALocation() {
        let text = "intro\n## A\na\n### A.1\ndeep\n## B\nb"
        let h = headings(text)
        let ns = text as NSString
        XCTAssertNil(PlanOutline.innermost(containing: 0, in: h), "before the first heading")
        XCTAssertEqual(PlanOutline.innermost(containing: ns.range(of: "deep").location, in: h), 1)
        XCTAssertEqual(PlanOutline.innermost(containing: ns.range(of: "\na\n").location + 1, in: h), 0)
        XCTAssertEqual(PlanOutline.innermost(containing: ns.range(of: "## B").location, in: h), 2, "on the heading line itself")
    }

    // MARK: Folds

    func testHiddenRangesAreTheFoldedBodiesMerged() {
        let text = "## A\na\n### A.1\ndeep\n## B\nb\n## C\nc"
        let h = headings(text)
        var folds = PlanFolds()
        folds.toggle(h[1].key)
        folds.toggle(h[0].key)
        folds.toggle(h[3].key)
        XCTAssertEqual(folds.hidden(in: h).map { sub(text, $0) }, ["a\n### A.1\ndeep\n", "c"],
                       "a fold inside a folded section adds nothing; separate folds stay separate")
        folds.toggle(h[0].key)
        XCTAssertEqual(folds.hidden(in: h).map { sub(text, $0) }, ["deep\n", "c"])
    }

    func testAnEmptySectionHidesNothing() {
        let text = "## A\n## B\nb"
        let h = headings(text)
        var folds = PlanFolds()
        folds.toggle(h[0].key)
        XCTAssertEqual(folds.hidden(in: h), [])
    }

    func testFoldsSurviveANewRoundByHeadingTextAndDropVanishedHeadings() {
        let before = "## 1. Overview\no\n## 4. Dispatch rules\nd\n## 5. Mobile\nm"
        var folds = PlanFolds()
        let h = headings(before)
        folds.toggle(h[1].key)
        folds.toggle(h[2].key)
        // The round rewrote §4's body, dropped §5 and added §6.
        let after = "## 1. Overview\no, longer\n## 4. Dispatch rules\nnew rules\n## 6. Rollout\nr"
        let h2 = headings(after)
        folds.reconcile(with: h2)
        XCTAssertEqual(folds.folded, [PlanFoldKey(text: "## 4. Dispatch rules", occurrence: 0)])
        XCTAssertEqual(folds.hidden(in: h2).map { sub(after, $0) }, ["new rules\n"])
    }

    func testRenamingAFoldedHeadingKeepsItFolded() {
        let before = headings("## A\na\n## B\nb")
        var folds = PlanFolds()
        folds.toggle(before[0].key)
        let after = headings("## Aa\na\n## B\nb")
        folds.carry(from: before, to: after)
        XCTAssertTrue(folds.isFolded(after[0].key), "one heading's text changed in place: its fold follows it")
        XCTAssertFalse(folds.isFolded(after[1].key))
    }

    func testFoldedLineCountIgnoresBlankLines() {
        let text = "## A\none\n\ntwo\n- three\n\n## B"
        XCTAssertEqual(PlanOutline.lineCount(headings(text)[0].body, in: text as NSString), 3)
    }

    // MARK: Nav cues

    func testCurrentSectionIsTheLastHeadingAtOrAboveTheProbe() {
        let tops: [CGFloat] = [0, 400, 900, 1500]
        XCTAssertNil(PlanOutline.current(tops: tops, probe: -10), "above the plan")
        XCTAssertEqual(PlanOutline.current(tops: tops, probe: 0), 0)
        XCTAssertEqual(PlanOutline.current(tops: tops, probe: 899), 1)
        XCTAssertEqual(PlanOutline.current(tops: tops, probe: 900), 2)
        XCTAssertEqual(PlanOutline.current(tops: tops, probe: 9000), 3)
        XCTAssertNil(PlanOutline.current(tops: [], probe: 5))
    }
}
