import CoreGraphics
import IntakeKit
import XCTest
@testable import FlightDeck

/// The notes rail (spec §7.3), decided without a view: which cards show, in what order, where
/// each one sits beside its anchor, and what the summary chip and the next-round tooltip say.
final class NotesRailModelTests: XCTestCase {
    private let plan = """
    # Plan

    ## Dispatch
    Jobs are offered in drive-time order, filtered by availability.

    ## Check-in
    Check-ins replay oldest-first on reconnect.
    """

    private func anchor(_ quote: String, checkpoint: Int = 2) -> NoteAnchor {
        let range = plan.range(of: quote)!
        return NoteAnchor(checkpoint: checkpoint, selecting: range, in: plan)
    }

    /// A line's Y is its character offset — enough to tell document order apart, and to check
    /// the card carries the Y the closure measured for its own range.
    private func offsetY(_ range: Range<String.Index>) -> CGFloat? {
        CGFloat(plan.distance(from: plan.startIndex, to: range.lowerBound))
    }

    func testCardsOrderedByAnchor() {
        let late = PlanNote(kind: .question, note: "Two devices?", anchor: anchor("oldest-first"))
        let early = PlanNote(kind: .comment, note: "Routing provider", anchor: anchor("drive-time order"))
        let middle = PlanNote(kind: .mustChange, note: "Add a buffer", anchor: anchor("filtered by availability"))
        let cards = NotesRailModel.cards(notes: [late, early, middle].map { TapeNote(note: $0, consumedBy: nil) },
                                         plan: plan, lineY: offsetY)
        XCTAssertEqual(cards.map(\.id), [early.id, middle.id, late.id], "document order, not the order they were made")
        XCTAssertEqual(cards[0].anchorY, offsetY(plan.range(of: "drive-time order")!))
        XCTAssertEqual(cards[0].quote, "drive-time order")
        XCTAssertEqual(cards[0].kind, .comment)
        XCTAssertEqual(cards[0].note, "Routing provider")
        XCTAssertFalse(cards.contains { $0.detached || $0.consumed })
    }

    /// Review Focus 4: a note whose quote the plan no longer holds is still the human's note —
    /// it shows at the top, with its quote, rather than vanishing or highlighting a guess.
    func testUnlocatableNoteIsDetachedNotDropped() {
        let anchored = PlanNote(kind: .comment, note: "fine", anchor: anchor("oldest-first"))
        let gone = PlanNote(kind: .mustChange, note: "Drop it",
                            anchor: NoteAnchor(checkpoint: 1, quote: "techs clock out for breaks"))
        let general = PlanNote(kind: .comment, note: "Whole plan: too long", anchor: nil)
        let cards = NotesRailModel.cards(notes: [anchored, gone, general].map { TapeNote(note: $0, consumedBy: nil) },
                                         plan: plan, lineY: offsetY)
        XCTAssertEqual(cards.count, 3, "nothing dropped")
        XCTAssertEqual(cards[0].id, gone.id, "detached goes to the top")
        XCTAssertTrue(cards[0].detached)
        XCTAssertNil(cards[0].anchorY)
        XCTAssertEqual(cards[0].quote, "techs clock out for breaks", "the quote is what lets the human recognise it")
        XCTAssertEqual(cards[1].id, general.id, "an unanchored note is about the whole plan: top, but not detached")
        XCTAssertFalse(cards[1].detached)
        XCTAssertNil(cards[1].quote)
        XCTAssertEqual(cards[2].id, anchored.id)
        XCTAssertNotNil(cards[2].anchorY)
    }

    /// A round that consumed a note keeps it on the rail, dimmed and read-only, after the
    /// pending ones — the human can see what the last round was told.
    func testConsumedNotesShownDimmedAfterRound() {
        let old = PlanNote(kind: .comment, note: "earlier", anchor: anchor("drive-time order"))
        let new = PlanNote(kind: .question, note: "now", anchor: anchor("oldest-first"))
        let cards = NotesRailModel.cards(notes: [TapeNote(note: old, consumedBy: 3), TapeNote(note: new, consumedBy: nil)],
                                         plan: plan, lineY: offsetY)
        XCTAssertEqual(cards.map(\.id), [new.id, old.id], "pending first")
        XCTAssertTrue(cards[1].consumed)
        XCTAssertFalse(cards[0].consumed)
        XCTAssertNotNil(cards[1].anchorY, "a consumed note still sits beside its text")
    }

    /// Cards sit at their anchor's Y and are pushed down only as far as the one above needs.
    func testLayoutAvoidsOverlap() {
        func card(_ y: CGFloat?, detached: Bool = false) -> NoteCardModel {
            NoteCardModel(id: UUID(), kind: .comment, quote: "q", note: "n", anchorY: y, detached: detached, consumed: false)
        }
        let a = card(100), b = card(110), c = card(300), d = card(120), top = card(nil, detached: true)
        let heights = [a.id: 40, b.id: 40, c.id: 40, d.id: 40, top.id: 40] as [UUID: CGFloat]
        let placed = NotesRailModel.layout([a, b, c, d, top], heights: heights, minGap: 8)
        XCTAssertEqual(placed[a.id], 100, "the first card sits on its anchor")
        XCTAssertEqual(placed[b.id], 148, "pushed below a, one gap apart")
        XCTAssertEqual(placed[d.id], 196, "pushed below b in anchor order, whatever order it came in")
        XCTAssertEqual(placed[c.id], 300, "room above: back on its own anchor")
        XCTAssertNil(placed[top.id], "no anchor, no place in the aligned lane")
        // Without measured heights, cards still never share a Y.
        let bare = NotesRailModel.layout([a, b], minGap: 8)
        XCTAssertEqual(bare[b.id], 110)
        XCTAssertEqual(NotesRailModel.layout([a, card(100)], minGap: 8).values.sorted(), [100, 108])
    }

    func testSummaryStrings() {
        XCTAssertEqual(NotesRailModel.summary(pending: 4, edits: 3).chip, "4 notes for the next round")
        XCTAssertEqual(NotesRailModel.summary(pending: 4, edits: 3).tooltip, "Sends your 3 edits and 4 notes")
        XCTAssertEqual(NotesRailModel.summary(pending: 1, edits: 1).chip, "1 note for the next round")
        XCTAssertEqual(NotesRailModel.summary(pending: 1, edits: 1).tooltip, "Sends your 1 edit and 1 note")
        XCTAssertEqual(NotesRailModel.summary(pending: 2, edits: 0).tooltip, "Sends your 2 notes")
        XCTAssertNil(NotesRailModel.summary(pending: 0, edits: 2).chip, "no notes, no chip")
        XCTAssertEqual(NotesRailModel.summary(pending: 0, edits: 2).tooltip, "Sends your 2 edits")
        XCTAssertNil(NotesRailModel.summary(pending: 0, edits: 0).tooltip, "nothing to send, nothing to say")
    }

    /// A draft commits on ⌘↩ or blur only when it says something — except Delete, whose kind
    /// is the whole request — and Replace needs its replacement.
    func testDraftCommitsOnlyWithSomethingToSay() {
        XCTAssertFalse(NotesRailModel.draftCommits(kind: .comment, text: "  \n"))
        XCTAssertTrue(NotesRailModel.draftCommits(kind: .comment, text: "Why?"))
        XCTAssertFalse(NotesRailModel.draftCommits(kind: .replace, text: ""))
        XCTAssertTrue(NotesRailModel.draftCommits(kind: .delete, text: ""))
    }
}
