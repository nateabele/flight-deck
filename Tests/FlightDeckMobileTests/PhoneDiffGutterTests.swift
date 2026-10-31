import FleetKit
import XCTest
@testable import FlightDeckMobile

/// What a block draws for the agent's proposed changes, and the Sessions row's needs-you badge.
final class PhoneDiffGutterTests: XCTestCase {
    private func diff(block: Int? = 2, old: String = "ship on Friday", new: String = "ship on Monday",
                      state: String = "pending") -> WirePendingDiff {
        WirePendingDiff(id: UUID(), thread: UUID(), checkpoint: 3, blockIndex: block, old: old, new: new, state: state)
    }

    func testAPendingDiffReadsAsItsNewTextWithABar() {
        let d = diff()
        let result = PhoneDiffGutter.apply(to: "We ship on Friday.", block: 2, diffs: [d], outbox: ThreadOutbox())
        XCTAssertEqual(result.text, "We ship on Monday.")
        XCTAssertEqual(result.bars, [d])
        XCTAssertTrue(result.loose.isEmpty)
    }

    func testADiffForAnotherBlockIsLeftAlone() {
        let result = PhoneDiffGutter.apply(to: "We ship on Friday.", block: 1, diffs: [diff()], outbox: ThreadOutbox())
        XCTAssertEqual(result.text, "We ship on Friday.")
        XCTAssertTrue(result.bars.isEmpty && result.loose.isEmpty)
    }

    /// Found twice is ambiguous, found never is moved: both are listed under the block, not guessed in.
    func testAPassageNotFoundExactlyOnceIsLoose() {
        let d = diff()
        for text in ["Ship on Monday only.", "ship on Friday, then ship on Friday"] {
            let result = PhoneDiffGutter.apply(to: text, block: 2, diffs: [d], outbox: ThreadOutbox())
            XCTAssertEqual(result.text, text)
            XCTAssertEqual(result.loose, [d])
        }
    }

    func testAStaleDiffIsLooseAndNeverApplied() {
        let d = diff(state: "stale")
        let result = PhoneDiffGutter.apply(to: "We ship on Friday.", block: 2, diffs: [d], outbox: ThreadOutbox())
        XCTAssertEqual(result.text, "We ship on Friday.")
        XCTAssertEqual(result.loose, [d])
    }

    func testAcceptedReadsAsNewWithNoBarAndRejectedAsOld() {
        let d = diff()
        var outbox = ThreadOutbox()
        outbox.decided(d.id, accept: true)
        var result = PhoneDiffGutter.apply(to: "We ship on Friday.", block: 2, diffs: [d], outbox: outbox)
        XCTAssertEqual(result.text, "We ship on Monday.")
        XCTAssertTrue(result.bars.isEmpty)
        outbox.decided(d.id, accept: false)
        result = PhoneDiffGutter.apply(to: "We ship on Friday.", block: 2, diffs: [d], outbox: outbox)
        XCTAssertEqual(result.text, "We ship on Friday.")
        XCTAssertTrue(result.bars.isEmpty && result.loose.isEmpty)
    }

    func testDetachedDiffsAreThoseTheMacCouldNotPlace() {
        XCTAssertEqual(PhoneDiffGutter.detached([diff(block: nil), diff(block: 1)], outbox: ThreadOutbox()).count, 1)
    }

    func testOnlyAPendingDiffOfASteerableIntakeCanBeDecided() {
        func detail(threads: Bool?, state: String) -> WireIntakeDetail {
            WireIntakeDetail(etag: "e", project: UUID(),
                             summary: WireIntakeSummary(id: UUID(), title: "t", state: state, needsAttention: false, createdAt: Date()),
                             intent: "i", servedAt: Date(), steer: true, threads: threads)
        }
        XCTAssertTrue(PhoneDiffGutter.canDecide(diff(), detail: detail(threads: true, state: "shaping")))
        XCTAssertFalse(PhoneDiffGutter.canDecide(diff(state: "stale"), detail: detail(threads: true, state: "shaping")))
        XCTAssertFalse(PhoneDiffGutter.canDecide(diff(), detail: detail(threads: nil, state: "shaping")))
        XCTAssertFalse(PhoneDiffGutter.canDecide(diff(), detail: detail(threads: true, state: "review")))
    }

    /// VoiceOver reads the label, so it gets the words and not the markup.
    func testSpokenTextHasNoMarkdownMarkup() {
        XCTAssertEqual(DiffText.spoken("wait until **every producer** has `paused`, see [docs](https://x.y)"),
                       "wait until every producer has paused, see docs")
        XCTAssertEqual(DiffText.spoken("plain text"), "plain text")
    }

    // MARK: - Needs you

    private func summary(attention: Bool = false, threads: Int? = nil) -> WireIntakeSummary {
        WireIntakeSummary(id: UUID(), title: "t", state: "shaping", needsAttention: attention, createdAt: Date(), threadsNeedingYou: threads)
    }

    func testAnIntakeWithAsksWaitingCountsAsNeedingYouAndSaysWhy() {
        XCTAssertNil(IntakeRowStyle.badge([summary()]))
        XCTAssertEqual(IntakeRowStyle.badge([summary(threads: 2), summary(attention: true), summary()]), "2 need you")
        XCTAssertEqual(IntakeRowStyle.threadsBadge(summary(threads: 1)), "1 ask needs you")
        XCTAssertEqual(IntakeRowStyle.threadsBadge(summary(threads: 3)), "3 asks need you")
        XCTAssertNil(IntakeRowStyle.threadsBadge(summary()))
    }

    func testRowsWithAsksWaitingSortWithTheOnesThatNeedYou() {
        let quiet = summary(), asking = summary(threads: 1)
        XCTAssertEqual(IntakeRowStyle.ordered([quiet, asking]).first?.id, asking.id)
    }
}
