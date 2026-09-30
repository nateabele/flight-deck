import FleetKit
import UIKit
import XCTest
@testable import FlightDeckMobile

/// The decisions behind annotating a plan from the phone. The sheet, the edit menu's placement
/// and the keyboard are not reachable here (docs/MOBILE.md owns them); what is reachable is what
/// goes on the wire and which notes the reader believes are still on their way.
@MainActor
final class PlanNotesTests: XCTestCase {

    // MARK: Which checkpoint a note carries (R3)

    /// A passage note names the checkpoint the reader showed: its block index only means
    /// something in that checkpoint's split.
    func testAPassageNoteCarriesTheCheckpointTheReaderShows() {
        XCTAssertEqual(NoteComposer.checkpoint(for: NoteDraftTarget(block: 4, quote: "the queue"), showing: 7), 7)
        XCTAssertEqual(NoteComposer.checkpoint(for: NoteDraftTarget(block: 0, quote: nil), showing: 7), 7)
    }

    /// A plan-wide note carries neither: the Mac refuses a block without a checkpoint, and a
    /// checkpoint without a block would anchor nothing.
    func testAPlanWideNoteCarriesNoCheckpoint() {
        XCTAssertNil(NoteComposer.checkpoint(for: NoteDraftTarget(block: nil, quote: nil), showing: 7))
    }

    // MARK: Which kinds the sheet offers

    /// A Highlight is an empty comment on a selection. On the whole plan it would be a note that
    /// says nothing about nothing, so the plan-wide sheet does not offer it.
    func testThePlanWideSheetOffersNoHighlight() {
        XCTAssertEqual(NoteComposer.kinds(for: NoteDraftTarget(block: nil, quote: nil)).map(\.id),
                       ["comment", "question", "mustChange", "replace", "delete"])
        XCTAssertEqual(NoteComposer.kinds(for: NoteDraftTarget(block: 2, quote: nil)).map(\.id),
                       NoteComposer.kinds.map(\.id))
    }

    // MARK: When the reader offers notes at all

    /// Notes are left at the head only: after one lands the reader re-requests the head, which
    /// would swap an older round's text for the current plan under the maintainer's thumb.
    func testNotesAreOfferedOnlyOnTheHeadOfASteerableShapingIntake() {
        XCTAssertTrue(PlanReaderStyle.notesAllowed(detail: TransportKeysTests.detail(), checkpoint: nil))
        XCTAssertFalse(PlanReaderStyle.notesAllowed(detail: TransportKeysTests.detail(), checkpoint: 3))
        XCTAssertFalse(PlanReaderStyle.notesAllowed(detail: TransportKeysTests.detail(steer: nil), checkpoint: nil))
        XCTAssertFalse(PlanReaderStyle.notesAllowed(detail: nil, checkpoint: nil))
    }

    // MARK: The outbox

    private func draft(_ block: Int? = 1, kind: String = "question", text: String = "Why?") -> NoteDraft {
        NoteDraft(target: NoteDraftTarget(block: block, quote: "a phrase"), showing: 7, kind: kind, text: text)
    }

    /// The draft decides its checkpoint when it is made, by the same rule.
    func testADraftCarriesTheCheckpointOfThePlanItWasMadeOn() {
        XCTAssertEqual(draft(3).checkpoint, 7)
        XCTAssertNil(draft(nil).checkpoint)
    }

    /// The note's id is fixed when the draft is made, so a retry is the same note.
    func testADraftKeepsItsNoteIDAcrossEdits() {
        var d = draft()
        let id = d.id
        d.text = "Why not?"
        d.kind = "comment"
        XCTAssertEqual(d.id, id)
    }

    /// A note the Mac acked but no round has folded yet is not in the head plan (the projection
    /// reads the tape, not the command queue), so the reader keeps showing it as pending.
    func testAnAckedNoteShowsAsPendingUntilThePlanCarriesIt() {
        var outbox = NoteOutbox()
        let d = draft(kind: "highlight", text: "")
        outbox.submit(d)
        XCTAssertEqual(outbox.unsent.map(\.id), [d.id])
        XCTAssertEqual(outbox.sentNotes, [])

        outbox.acked(d.id)
        XCTAssertEqual(outbox.unsent, [])
        XCTAssertEqual(outbox.sentNotes, [WireNote(id: d.id, kind: "comment", text: "", quote: "a phrase",
                                                   consumed: false, blockIndex: 1)])

        outbox.reconcile(with: [WireNote(id: d.id, kind: "comment", text: "", blockIndex: 1)])
        XCTAssertEqual(outbox.sentNotes, [])
        XCTAssertEqual(outbox.unsent, [])
    }

    /// An unsent note the plan does not carry yet stays put across a reload; a removed one goes.
    func testReconcileKeepsUnsentNotesAndRemoveDropsOne() {
        var outbox = NoteOutbox()
        let a = draft(), b = draft(nil)
        outbox.submit(a); outbox.submit(b)
        outbox.reconcile(with: [])
        XCTAssertEqual(outbox.unsent.map(\.id), [a.id, b.id])
        outbox.remove(a.id)
        XCTAssertEqual(outbox.unsent.map(\.id), [b.id])
    }

    /// A Delete refused as `note_consumed` can never succeed, so the pending card goes; any
    /// other failure (moved on, no answer, not connected) leaves it to try again.
    func testARemoveRefusedAsConsumedDropsTheNoteAndNothingElseDoes() {
        var outbox = NoteOutbox()
        let d = draft()
        outbox.submit(d); outbox.acked(d.id)
        outbox.removeFailed(d.id, error: .server(code: "intake_moved_on"))
        outbox.removeFailed(d.id, error: .disconnected)
        outbox.removeFailed(d.id, error: nil)
        XCTAssertEqual(outbox.sentNotes.map(\.id), [d.id])
        outbox.removeFailed(d.id, error: .server(code: "note_consumed"))
        XCTAssertEqual(outbox.sentNotes, [])
    }

    /// Submitting the same draft again (a retry) replaces it rather than listing it twice.
    func testResubmittingADraftDoesNotDuplicateIt() {
        var outbox = NoteOutbox()
        var d = draft()
        outbox.submit(d)
        d.text = "Edited"
        outbox.submit(d)
        XCTAssertEqual(outbox.unsent.map(\.text), ["Edited"])
    }

    // MARK: The edit menu (R4)

    private func menu(actions: [ProseAction], range: NSRange) -> UIMenu? {
        let coordinator = SelectableProseView.Coordinator(actions: actions)
        let view = UITextView()
        view.text = "drain the queue first"
        return coordinator.textView(view, editMenuForTextIn: range, suggestedActions: [])
    }

    /// One item per action, appended after the system's in order. (Invoking a `UIAction`'s
    /// handler has no public API, so what it is handed stays on MOBILE.md's checklist.)
    func testEachActionIsAppendedAfterTheSystemItems() {
        let actions = [
            ProseAction(title: "Reply", systemImage: "arrowshape.turn.up.left") { _ in },
            ProseAction(title: "Note…", systemImage: "text.bubble") { _ in },
        ]
        let coordinator = SelectableProseView.Coordinator(actions: actions)
        let view = UITextView()
        view.text = "drain the queue first"
        let copy = UIAction(title: "Copy") { _ in }
        let m = coordinator.textView(view, editMenuForTextIn: NSRange(location: 6, length: 3), suggestedActions: [copy])
        XCTAssertEqual(m?.children.map { ($0 as? UIAction)?.title }, ["Copy", "Reply", "Note…"])
    }

    /// No actions, or no selection: the system's own menu, nothing that does nothing.
    func testNoActionsOrNoSelectionLeavesTheSystemMenu() {
        XCTAssertNil(menu(actions: [], range: NSRange(location: 0, length: 5)))
        XCTAssertNil(menu(actions: [ProseAction(title: "Reply", systemImage: "x") { _ in }],
                          range: NSRange(location: 0, length: 0)))
    }
}
