import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

final class IntakePlanProjectionTests: XCTestCase {
    private let markdown = """
    # Plan

    ## 1. Product contract

    Keep **account sign-in** in scope and `vault` keys.

    ## 7. Credential paths

    1. Require explicit proof that the chosen mode permits hosted execution.
    2. Run requests through [Beacon's gateway](https://x.test).
    """

    func testOutlineListsSecondLevelHeadingsWithTheirBlocks() {
        let blocks = PlanBlocks.split(markdown)
        let outline = IntakePlanProjection.outline(markdown: markdown, blocks: blocks, churn: [], divergingSection: nil)
        XCTAssertEqual(outline.map(\.heading), ["1. Product contract", "7. Credential paths"])
        XCTAssertEqual(outline.map(\.level), [2, 2])
        for section in outline {
            XCTAssertTrue(blocks.blocks[section.blockIndex].text.hasPrefix("## "), section.heading)
        }
    }

    func testChurnIsPerRoundAndTheDivergingSectionIsFlagged() {
        let blocks = PlanBlocks.split(markdown)
        let churn: [[String: Int]] = [
            [ConvergenceSeries.label("7. Credential paths"): 12, ConvergenceSeries.label("1. Product contract"): 3],
            [ConvergenceSeries.label("7. Credential paths"): 9],
        ]
        let outline = IntakePlanProjection.outline(markdown: markdown, blocks: blocks, churn: churn,
                                                   divergingSection: "7. Credential paths")
        XCTAssertEqual(outline[0].churn, [3, 0])
        XCTAssertEqual(outline[1].churn, [12, 9])
        XCTAssertFalse(outline[0].diverging)
        XCTAssertTrue(outline[1].diverging)
    }

    /// The engine's real keys: `PlanMetrics.sectionChurn` and `ConvergenceTrend.hotSection` name a
    /// section by its whole heading LINE, hashes and all — what the Mac's churn lane looks up.
    func testChurnAndDivergenceReadTheEnginesHeadingLineKeys() {
        let blocks = PlanBlocks.split(markdown)
        let churn: [[String: Int]] = [["## 7. Credential paths": 4, "## 1. Product contract": 2], ["## 1. Product contract": 1]]
        let outline = IntakePlanProjection.outline(markdown: markdown, blocks: blocks, churn: churn,
                                                   divergingSection: "## 7. Credential paths")
        XCTAssertEqual(outline[0].churn, [2, 1])
        XCTAssertEqual(outline[1].churn, [4, 0])
        XCTAssertEqual(outline[1].settledSince, "Round 1", "changed in round 1, still since")
        XCTAssertNil(outline[0].settledSince, "changed in the last round: not settled")
        XCTAssertTrue(outline[1].diverging)
    }

    /// A refine cycle (checkpoints 2, 3) then a polish cycle (5, 6). Polish edits the change set,
    /// not the plan, so its points carry no section churn — reading the newest cycle, as the
    /// first cut did, zeroed every row during polish while the Mac's churn lane showed movement.
    private func refineThenPolish() -> [ConvergenceCycle] {
        let refine = ConvergenceSeries.assess(.refine, [
            ConvergencePoint(checkpoint: 2, stage: .refine, round: 1, changeCount: 12, linesChurned: 20,
                             sectionChurn: ["## 7. Credential paths": 12, "## 1. Product contract": 3]),
            ConvergencePoint(checkpoint: 3, stage: .refine, round: 2, changeCount: 9, linesChurned: 9,
                             sectionChurn: ["## 7. Credential paths": 9]),
        ])
        let polish = ConvergenceSeries.assess(.polish, [
            ConvergencePoint(checkpoint: 5, stage: .polish, round: 1, changeCount: 4, linesChurned: 0),
            ConvergencePoint(checkpoint: 6, stage: .polish, round: 2, changeCount: 2, linesChurned: 0),
        ])
        return [refine, polish]
    }

    func testChurnDuringPolishReadsTheRefineCycleLikeTheMacsLane() {
        let blocks = PlanBlocks.split(markdown)
        let cycles = refineThenPolish()
        let atHead = IntakePlanProjection.churnSource(cycles, checkpoint: 6)
        let outline = IntakePlanProjection.outline(markdown: markdown, blocks: blocks, churn: atHead.churn,
                                                   divergingSection: atHead.diverging)
        XCTAssertEqual(outline[0].churn, [3, 0])
        XCTAssertEqual(outline[1].churn, [12, 9])
        XCTAssertEqual(outline[0].settledSince, "Round 1")
    }

    func testAnOlderCheckpointShowsItsOwnCycleUpToThatCheckpoint() {
        let blocks = PlanBlocks.split(markdown)
        let source = IntakePlanProjection.churnSource(refineThenPolish(), checkpoint: 2)
        let outline = IntakePlanProjection.outline(markdown: markdown, blocks: blocks, churn: source.churn,
                                                   divergingSection: source.diverging)
        XCTAssertEqual(outline[0].churn, [3])
        XCTAssertEqual(outline[1].churn, [12])
    }

    func testNoteQuotesLocateAcrossInlineMarkup() {
        let blocks = PlanBlocks.split(markdown)
        let bold = PlanNote(kind: .comment, note: "x",
                            anchor: NoteAnchor(checkpoint: 1, quote: "Keep account sign-in in scope and vault keys."))
        let link = PlanNote(kind: .question, note: "y",
                            anchor: NoteAnchor(checkpoint: 1, quote: "through Beacon's gateway"))
        let gone = PlanNote(kind: .delete, note: "z", anchor: NoteAnchor(checkpoint: 1, quote: "a sentence that no longer exists"))
        let planWide = PlanNote(kind: .comment, note: "overall", anchor: nil)
        let located = [bold, link, gone, planWide].map { IntakePlanProjection.locate($0, consumed: false, in: blocks) }
        XCTAssertTrue(blocks.blocks[located[0].blockIndex!].text.contains("account sign-in"))
        XCTAssertTrue(blocks.blocks[located[1].blockIndex!].text.contains("Beacon"))
        XCTAssertNil(located[2].blockIndex, "a vanished quote is detached, never mis-pinned")
        XCTAssertNil(located[3].blockIndex)
        XCTAssertEqual(located[1].kind, "question")
    }

    func testNotesLocateInTheRealLarkOSPlan() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/larkos-plan.md")
        let plan = try String(contentsOf: url, encoding: .utf8)
        let blocks = PlanBlocks.split(plan)
        let note = PlanNote(kind: .mustChange, note: "n",
                            anchor: NoteAnchor(checkpoint: 2, quote: "Require explicit proof that the chosen mode permits hosted and unattended execution"))
        let located = IntakePlanProjection.locate(note, consumed: false, in: blocks)
        XCTAssertNotNil(located.blockIndex)
    }

    func testBlockDiffNamesAddedAndRemovedBlocks() {
        let parent = PlanBlocks.split("# P\n\nA.\n\nB.\n\nC.")
        let current = PlanBlocks.split("# P\n\nA.\n\nB2.\n\nC.")
        let diff = IntakePlanProjection.blockDiff(current: current, parent: parent)
        XCTAssertEqual(diff.added.map { current.blocks[$0].text }, ["B2."])
        XCTAssertEqual(diff.removed, [WireRemovedBlock(after: 1, text: "B.")])
    }
}
