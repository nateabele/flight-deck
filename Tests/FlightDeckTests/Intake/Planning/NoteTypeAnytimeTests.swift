import IntakeKit
import XCTest
@testable import FlightDeck

/// A note's type is changeable any time: while it is a draft, after the field loses focus
/// and the note is committed, and from its card — until a round has read it.
@MainActor
final class NoteTypeAnytimeTests: XCTestCase {
    private let plan = "# Plan\n\nOffered by drive time.\n"

    private func controller(sent: @escaping (TapeCommand) -> Void = { _ in }, undo: UndoManager? = nil) -> PlanNotesController {
        let notes = PlanNotesController()
        notes.send = sent
        notes.undoManager = undo
        notes.checkpoint = 2
        notes.editorChanged(plan)
        return notes
    }

    private func range(_ quote: String) -> NSRange { NSRange(plan.range(of: quote)!, in: plan) }

    /// The bug: blur committed the draft, and the committed card had no type control at all.
    func testTheTypeChangesAfterTheFieldLosesFocus() throws {
        var sent: [TapeCommand] = []
        let notes = controller { sent.append($0) }
        notes.choose(.comment, range: range("drive time"), in: plan)
        notes.draft?.text = "Which provider?"
        notes.draftLostFocus()
        XCTAssertNil(notes.draft, "blur committed the note")
        let id = try XCTUnwrap(notes.notes.first?.id)

        XCTAssertTrue(notes.canSetKind(id, to: .question))
        notes.setKind(id, to: .question)
        XCTAssertEqual(notes.notes.first?.note.kind, .question, "shown at once")
        XCTAssertEqual(sent.last, .setNoteKind(id, .question), "and persisted through the tape command")
        XCTAssertEqual(notes.marks.first?.kind, .question, "the plan's band follows")
        XCTAssertEqual(notes.notes.first?.note.note, "Which provider?", "the words are kept")
    }

    /// An empty draft is not dropped by blur: the human may have gone for the pop-up first.
    func testAnEmptyDraftSurvivesBlurAndItsTypeStillChanges() {
        let notes = controller()
        notes.choose(.comment, range: range("drive time"), in: plan)
        notes.draftLostFocus()
        XCTAssertNotNil(notes.draft)
        let id = notes.draft!.id
        notes.setKind(id, to: .mustChange)
        XCTAssertEqual(notes.draft?.kind, .mustChange)
    }

    func testTheRetypeOverridesTheTapeUntilTheTapeAgrees() throws {
        let notes = controller()
        let note = PlanNote(kind: .comment, note: "x")
        notes.tapeNotes = [TapeNote(note: note, consumedBy: nil)]
        notes.setKind(note.id, to: .delete)
        XCTAssertEqual(notes.notes.first?.note.kind, .delete)
        notes.tapeNotes = [TapeNote(note: note, consumedBy: nil)]  // a stale read before the runner folds it
        XCTAssertEqual(notes.notes.first?.note.kind, .delete, "no flip back")
        var folded = note; folded.kind = .delete
        notes.tapeNotes = [TapeNote(note: folded, consumedBy: nil)]
        var later = note; later.kind = .question
        notes.tapeNotes = [TapeNote(note: later, consumedBy: nil)]
        XCTAssertEqual(notes.notes.first?.note.kind, .question, "once the tape agrees, the tape is the record")
    }

    func testRetypingIsUndoableAndRedoable() throws {
        let undo = UndoManager()
        undo.groupsByEvent = false
        var sent: [TapeCommand] = []
        let notes = controller(sent: { sent.append($0) }, undo: undo)
        let note = PlanNote(kind: .comment, note: "x")
        notes.tapeNotes = [TapeNote(note: note, consumedBy: nil)]

        undo.beginUndoGrouping()
        notes.setKind(note.id, to: .question)
        undo.endUndoGrouping()
        XCTAssertEqual(undo.undoActionName, "Change Note Type")
        undo.undo()
        XCTAssertEqual(sent.last, .setNoteKind(note.id, .comment))
        XCTAssertEqual(notes.notes.first?.note.kind, .comment)
        undo.redo()
        XCTAssertEqual(sent.last, .setNoteKind(note.id, .question))
        XCTAssertEqual(notes.notes.first?.note.kind, .question)
    }

    /// Consumed: the round read it as what it was and no later round reads it again.
    func testAConsumedNoteKeepsItsTypeAndSendsNothing() {
        var sent: [TapeCommand] = []
        let notes = controller { sent.append($0) }
        let read = PlanNote(kind: .comment, note: "x")
        notes.tapeNotes = [TapeNote(note: read, consumedBy: 2)]
        XCTAssertFalse(notes.canSetKind(read.id, to: .question))
        notes.setKind(read.id, to: .question)
        XCTAssertEqual(notes.notes.first?.note.kind, .comment)
        XCTAssertTrue(sent.isEmpty)
    }

    func testATypeTheWordsCannotCarryIsNotOffered() {
        let notes = controller()
        let highlight = PlanNote(kind: .comment, note: "")
        notes.tapeNotes = [TapeNote(note: highlight, consumedBy: nil)]
        XCTAssertFalse(notes.canSetKind(highlight.id, to: .question))
        XCTAssertTrue(notes.canSetKind(highlight.id, to: .delete))
    }
}
