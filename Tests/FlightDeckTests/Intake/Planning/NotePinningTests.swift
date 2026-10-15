import AppKit
import IntakeKit
import XCTest
@testable import FlightDeck

/// Notes are pinned to the version of the plan they were written on: on that version they sit
/// beside their quote; on any other they are listed under the version's name, with the quote and
/// a way to open it, and never read "can't find this text any more".
///
/// The scenario is the maintainer's LarkOS intake: eight notes written on the drafts (checkpoint 1), read
/// by synthesis (checkpoint 2), whose plan rewrote every one of the quoted passages.
@MainActor
final class NotePinningTests: XCTestCase {
    private let draft = """
    # Plan

    ## Product and security decisions

    Each owner controls a specific invite list for use and can publish their own drafts after automated checks.

    ## Phase 3: durable state

    Run PostgreSQL on encrypted gp3 EBS storage as the system of record.
    """

    private let synthesis = """
    # Plan

    ## Product and security decisions

    Apps are open to the whole company unless the owner narrows them to an invite list.

    ## Phase 3: durable state

    One SQLite file per app, snapshotted nightly.
    """

    private func anchor(_ quote: String, in plan: String, checkpoint: Int) -> NoteAnchor {
        NoteAnchor(checkpoint: checkpoint, selecting: plan.range(of: quote)!, in: plan)
    }

    private lazy var invites = PlanNote(kind: .comment, note: "Invite lists are optional.",
                                        anchor: anchor("specific invite list", in: draft, checkpoint: 1))
    private lazy var postgres = PlanNote(kind: .question, note: "Why not SQLite?",
                                         anchor: anchor("Run PostgreSQL on encrypted gp3 EBS storage", in: draft, checkpoint: 1))
    private lazy var onSynthesis = PlanNote(kind: .mustChange, note: "Name the snapshot cadence.",
                                            anchor: anchor("snapshotted nightly", in: synthesis, checkpoint: 2))
    private let whole = PlanNote(kind: .comment, note: "Too long overall.")

    private let labels = [1: "Draft · Round 0", 2: "Synthesis · Round 0"]

    private func pin(_ viewing: Int) -> (TapeNote) -> NotePin? {
        { entry in
            guard let v = entry.note.anchor?.checkpoint, v != viewing else { return nil }
            return NotePin(checkpoint: v, label: self.labels[v]!)
        }
    }

    private func cards(_ notes: [TapeNote], viewing: Int, plan: String) -> [NoteCardModel] {
        NotesRailModel.cards(notes: notes, plan: plan, pinned: pin(viewing)) { CGFloat(plan.distance(from: plan.startIndex, to: $0.lowerBound)) }
    }

    // MARK: The rail

    /// After synthesis: the notes written on the drafts are not detached. They keep their quote,
    /// name their version, and sit after the version on screen's own notes.
    func testNotesFromTheDraftsAreNotLostOnTheSynthesisPlan() {
        let entries = [invites, postgres, onSynthesis, whole].map { TapeNote(note: $0, consumedBy: $0.id == onSynthesis.id || $0.id == whole.id ? nil : 2) }
        let cards = cards(entries, viewing: 2, plan: synthesis)
        XCTAssertEqual(cards.map(\.id), [whole.id, onSynthesis.id, invites.id, postgres.id],
                       "this version's first (the whole-plan note, then the anchored one), then the drafts' in the order written")
        XCTAssertFalse(cards.contains(where: \.detached), "no card says it can't find its text")
        XCTAssertEqual(cards[2].pin, NotePin(checkpoint: 1, label: "Draft · Round 0"))
        XCTAssertEqual(cards[2].quote, "specific invite list")
        XCTAssertNil(cards[2].anchorY, "it has no line in this plan")
        XCTAssertTrue(cards[2].consumed, "read by synthesis")
        XCTAssertNil(cards[1].pin)
        XCTAssertNotNil(cards[1].anchorY, "its own version anchors it as before")
    }

    /// On the version a note was written on it anchors exactly as it always did.
    func testOnItsOwnVersionANoteAnchorsAsBefore() {
        let entries = [invites, postgres].map { TapeNote(note: $0, consumedBy: 2) }
        let cards = cards(entries, viewing: 1, plan: draft)
        XCTAssertEqual(cards.map(\.id), [invites.id, postgres.id], "document order")
        XCTAssertTrue(cards.allSatisfy { $0.pin == nil && !$0.detached && $0.anchorY != nil })
    }

    /// A quote that is missing from the very version it was written on is not an expected outcome
    /// (the tape and the plan disagree): that, and only that, still reads as detached.
    func testAQuoteMissingFromItsOwnVersionIsStillDetached() {
        let cards = cards([TapeNote(note: invites, consumedBy: 2)], viewing: 1, plan: synthesis)
        XCTAssertEqual(cards.count, 1)
        XCTAssertTrue(cards[0].detached)
        XCTAssertNil(cards[0].pin)
    }

    /// Several earlier versions: grouped by version, the latest first, each in tape order.
    func testEarlierVersionsGroupedLatestFirst() {
        let refine = PlanNote(kind: .comment, note: "On refine.", anchor: NoteAnchor(checkpoint: 3, quote: "something from refine"))
        let labels = [1: "Draft · Round 0", 2: "Synthesis · Round 0", 3: "Refine 1"]
        let cards = NotesRailModel.cards(
            notes: [invites, refine, postgres, onSynthesis].map { TapeNote(note: $0, consumedBy: 4) }, plan: "",
            pinned: { entry in entry.note.anchor.map { NotePin(checkpoint: $0.checkpoint, label: labels[$0.checkpoint]!) } }) { _ in nil }
        XCTAssertEqual(cards.map(\.id), [refine.id, onSynthesis.id, invites.id, postgres.id])
        XCTAssertEqual(cards.map { $0.pin?.checkpoint }, [3, 2, 1, 1])
    }

    // MARK: The controller

    private func controller(viewing: Int, notes: [TapeNote]) -> PlanNotesController {
        let controller = PlanNotesController()
        controller.versionLabel = { self.labels[$0] }
        controller.tapeNotes = notes
        controller.checkpoint = viewing
        return controller
    }

    func testTheControllerPinsOnlyNotesFromOtherVersions() {
        let entries = [invites, onSynthesis, whole].map { TapeNote(note: $0, consumedBy: nil) }
        let c = controller(viewing: 2, notes: entries)
        XCTAssertEqual(c.pin(for: entries[0]), NotePin(checkpoint: 1, label: "Draft · Round 0"))
        XCTAssertNil(c.pin(for: entries[1]), "written on the version shown")
        XCTAssertNil(c.pin(for: entries[2]), "about the whole plan")
        c.checkpoint = nil
        XCTAssertNil(c.pin(for: entries[0]), "no plan shown, nothing to be elsewhere from")
    }

    /// A note from another version is marked in the text only where its quote is found, and
    /// dimmed; one on the version shown is marked at full strength.
    func testAMarkOnAnotherVersionIsDimmed() {
        let entries = [invites, onSynthesis].map { TapeNote(note: $0, consumedBy: nil) }
        let c = controller(viewing: 2, notes: entries)
        let marks = Dictionary(uniqueKeysWithValues: c.marks.map { ($0.id, $0) })
        XCTAssertEqual(marks[invites.id]?.consumed, true)
        XCTAssertEqual(marks[onSynthesis.id]?.consumed, false)
    }

    // MARK: Show in that version

    func testShowInThatVersionOpensTheCheckpointAndAsksForTheQuote() throws {
        let entries = [TapeNote(note: invites, consumedBy: 2)]
        let c = controller(viewing: 2, notes: entries)
        var opened: [Int] = [], shown = 0
        c.openCheckpoint = { opened.append($0) }
        c.showPlan = { shown += 1 }
        c.showInVersion(invites.id)
        XCTAssertEqual(opened, [1])
        XCTAssertEqual(shown, 1, "the plan view, even if the diff was open")
        let reveal = try XCTUnwrap(c.pendingReveal)
        XCTAssertEqual(reveal.checkpoint, 1)
        XCTAssertEqual(reveal.anchor.quote, "specific invite list")
    }

    /// Already on that version: nothing to open, the editor is told to scroll.
    func testShowInThatVersionOnTheVersionShownJustScrolls() {
        let c = controller(viewing: 1, notes: [TapeNote(note: invites, consumedBy: 2)])
        var opened: [Int] = [], revealed = 0
        c.openCheckpoint = { opened.append($0) }
        c.revealPending = { revealed += 1 }
        c.showInVersion(invites.id)
        XCTAssertEqual(opened, [])
        XCTAssertEqual(revealed, 1)
    }

    func testAWholePlanNoteHasNothingToShow() {
        let c = controller(viewing: 2, notes: [TapeNote(note: whole, consumedBy: nil)])
        c.openCheckpoint = { _ in XCTFail("no version to open") }
        c.showInVersion(whole.id)
        XCTAssertNil(c.pendingReveal)
    }

    /// The request is used once, on the text that holds the quote, and not on a text that doesn't.
    func testTheBridgeFindsTheQuoteInTheLoadedVersionOnce() throws {
        let c = controller(viewing: 2, notes: [TapeNote(note: invites, consumedBy: 2)])
        let bridge = PlanNotesBridge()
        let editor = PlanNSTextView(usingTextLayoutManager: true)
        defer { withExtendedLifetime(editor) {} }
        bridge.attach(c, to: editor)
        c.openCheckpoint = { _ in }
        c.showInVersion(invites.id)
        XCTAssertNil(bridge.takeReveal(in: synthesis), "the plan that rewrote the quote has nothing to reveal")
        XCTAssertNotNil(c.pendingReveal, "still waiting for its version")
        let range = try XCTUnwrap(bridge.takeReveal(in: draft))
        XCTAssertEqual((draft as NSString).substring(with: range), "specific invite list")
        XCTAssertNil(c.pendingReveal)
        XCTAssertNil(bridge.takeReveal(in: draft), "used once")
    }

    func testAStaleRevealIsDroppedNotAppliedToALaterText() throws {
        let c = controller(viewing: 2, notes: [TapeNote(note: invites, consumedBy: 2)])
        let bridge = PlanNotesBridge()
        let editor = PlanNSTextView(usingTextLayoutManager: true)
        defer { withExtendedLifetime(editor) {} }
        bridge.attach(c, to: editor)
        c.pendingReveal = PlanNotesController.Reveal(checkpoint: 1, anchor: try XCTUnwrap(invites.anchor),
                                                     asked: Date().addingTimeInterval(-(PlanNotesBridge.revealWindow + 1)))
        XCTAssertNil(bridge.takeReveal(in: draft))
        XCTAssertNil(c.pendingReveal)
    }

    // MARK: The other-versions section

    func testTheSectionTitleCountsNotesAndVersions() {
        func card(_ v: Int) -> NoteCardModel {
            NoteCardModel(id: UUID(), kind: .comment, quote: "q", note: "n", anchorY: nil, detached: false, consumed: true,
                          pin: NotePin(checkpoint: v, label: "L\(v)"))
        }
        XCTAssertEqual(NotesRailModel.otherVersionsTitle([card(1)]), "1 note on another version")
        XCTAssertEqual(NotesRailModel.otherVersionsTitle([card(1), card(1)]), "2 notes on another version")
        XCTAssertEqual(NotesRailModel.otherVersionsTitle([card(1), card(2), card(2)]), "3 notes on other versions")
    }

    /// Closed over a version that has notes of its own, open when it has none; the human's
    /// choice beats both.
    func testTheSectionOpensOnlyWhenNothingElseNeedsTheRoom() {
        XCTAssertFalse(NotesRailModel.otherVersionsExpanded(choice: nil, hasOwnNotes: true))
        XCTAssertTrue(NotesRailModel.otherVersionsExpanded(choice: nil, hasOwnNotes: false))
        XCTAssertTrue(NotesRailModel.otherVersionsExpanded(choice: true, hasOwnNotes: true))
        XCTAssertFalse(NotesRailModel.otherVersionsExpanded(choice: false, hasOwnNotes: false))
    }

    /// The choice is kept per intake for the session: a rail made again for the same intake
    /// finds it, another intake does not.
    func testTheChoiceIsRememberedPerIntake() {
        let a = UUID(), b = UUID()
        let first = PlanNotesController()
        first.intakeID = a
        XCTAssertNil(first.otherVersionsExpanded)
        first.otherVersionsExpanded = true
        first.reset()
        XCTAssertEqual(first.otherVersionsExpanded, true, "past a reset")
        let again = PlanNotesController()
        again.intakeID = a
        XCTAssertEqual(again.otherVersionsExpanded, true)
        again.intakeID = b
        XCTAssertNil(again.otherVersionsExpanded)
        again.intakeID = a
        again.otherVersionsExpanded = nil
    }
}
