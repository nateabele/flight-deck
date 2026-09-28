import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Renders the plan with its notes — three highlighted notes, one detached, a draft being
/// written, and the selection toolbar open over a selection — at 1100 pt with the rail as the
/// inspector, for design review. Skipped unless `FD_NOTES_RENDER` names the PNG to write.
///
/// The rail is laid beside the plan in an HStack rather than through `.inspector`: an
/// offscreen `layer.render` can't draw the inspector's AppKit split pane (Task 9's finding), and
/// the point is the cards lining up with their lines, which needs both halves in the picture.
@MainActor
final class NotesRailRenderTests: XCTestCase {
    func testRenderNotesRail() throws {
        guard let path = ProcessInfo.processInfo.environment["FD_NOTES_RENDER"] else {
            throw XCTSkip("set FD_NOTES_RENDER to a PNG path to render the notes rail")
        }
        let plan = """
        # Field-service scheduling

        ## 4. Dispatch rules

        Jobs are offered to technicians in **drive-time order**, filtered by availability.

        - Rank candidates by **skill match**, then drive time.
        - Skill match is soft: a dispatcher may override it.
        - A job with no candidate stays Unassigned until a dispatcher assigns it.

        ## 5. Mobile check-in

        Check-ins queue in `CheckInOutbox` while offline and replay **oldest-first** on reconnect.

        On-site states live in `VisitStatus`: `enRoute`, `onSite`, `paused`, `done`.

        ```swift
        enum VisitStatus: String, Codable {
            case enRoute, onSite, paused, done
        }
        ```

        ## 6. Out of scope

        - Invoicing and payments.
        - Route optimisation beyond drive time.
        """
        func anchor(_ quote: String) -> NoteAnchor {
            NoteAnchor(checkpoint: 2, selecting: plan.range(of: quote)!, in: plan)
        }
        let notes = [
            PlanNote(kind: .comment, note: "Drive time must come from the routing provider, not straight-line distance.",
                     anchor: anchor("drive-time order")),
            PlanNote(kind: .question, note: "What happens when two devices check in the same job while offline?",
                     anchor: anchor("oldest-first")),
            PlanNote(kind: .mustChange, note: "Drop paused. Techs clock out instead; we don't track breaks.",
                     anchor: NoteAnchor(checkpoint: 2, selecting: plan.range(of: "`paused`").map {
                         plan.index(after: $0.lowerBound)..<plan.index(before: $0.upperBound) }!, in: plan)),
            PlanNote(kind: .delete, note: "",
                     anchor: NoteAnchor(checkpoint: 1, quote: "Technicians rate each job after check-out")),
        ]
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        var tape = Tape(checkpoints: [
            Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: date),
            Checkpoint(id: 2, parent: 1, stage: .refine, round: 1, major: false, createdAt: date),
        ], target: .none, status: .paused)
        tape.pendingNotes = notes
        let load: (Int, String) -> Data? = { id, file in
            (id == 1 && file == "drafts/0.md") || (id == 2 && file == "plan.md") ? Data(plan.utf8) : nil
        }

        let controller = PlanNotesController()
        controller.tapeNotes = TapeStore(intakeDirectory: FileManager.default.temporaryDirectory).notes(in: tape)
        controller.checkpoint = 2
        let draftRange = NSRange(plan.range(of: "filtered by availability")!, in: plan)
        controller.choose(.mustChange, range: draftRange, in: plan)
        controller.draft?.text = "Include a travel buffer between jobs, not just shift hours"

        let view = HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Plan").font(.headline)
                    Spacer()
                    if let chip = controller.summary.chip {
                        Text(chip).font(.system(size: 12)).padding(.horizontal, 9).frame(height: 22)
                            .notesChipStyle()
                    }
                }
                PlanSection(intakeID: UUID(), tape: tape, loadFile: load, onSend: { _ in }, notes: controller)
            }
            .padding(20)
            Divider()
            NotesRail(controller: controller, roundName: { _ in "Refine 1" }, focusesDraft: false)
                .frame(width: 340)
        }
        let size = NSSize(width: 1100, height: 760)
        try PlanningRender.write(view, size: size, to: URL(fileURLWithPath: path)) { host in
            guard let textView = Self.find(PlanNSTextView.self, in: host) else { return XCTFail("no editor") }
            XCTAssertEqual(textView.string, plan)
            host.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(plan.range(of: "stays Unassigned until a dispatcher assigns it")!, in: plan))
        }
        XCTAssertEqual(controller.pendingCount, 4)
        XCTAssertEqual(controller.summary.tooltip, "Sends your 4 notes")
    }

    /// A note on text the human inserted: the edit layer's green background and the note's
    /// underline band both show (`DecorationLayer` — each layer keeps to its own keys), and the
    /// next-round tooltip counts the edit from the edit layer's hunks. Written beside
    /// `FD_NOTES_RENDER` as `<name>-overlap.png`.
    func testRenderNoteOverInsertion() throws {
        guard let path = ProcessInfo.processInfo.environment["FD_NOTES_RENDER"] else {
            throw XCTSkip("set FD_NOTES_RENDER to a PNG path to render the notes rail")
        }
        let generated = """
        # Field-service scheduling

        ## 4. Dispatch rules

        Jobs are offered to technicians in drive-time order, filtered by availability.

        - Skill match is soft: a dispatcher may override it.
        - A job with no candidate stays Unassigned until a dispatcher assigns it.
        """
        let edited = generated.replacingOccurrences(
            of: "a dispatcher may override it.",
            with: "a dispatcher may override it, and the board records the reason on the job.")
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        var tape = Tape(checkpoints: [
            Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: date),
            Checkpoint(id: 2, parent: 1, stage: .refine, round: 1, major: false, createdAt: date),
        ], target: .none, status: .paused)
        let note = PlanNote(kind: .question, note: "Is the reason required, or can the dispatcher skip it?",
                            anchor: NoteAnchor(checkpoint: 2, selecting: edited.range(of: "records the reason")!, in: edited))
        tape.pendingNotes = [note]
        let load: (Int, String) -> Data? = { id, file in
            switch (id, file) {
            case (1, "drafts/0.md"), (2, "plan.md"): Data(generated.utf8)
            case (2, PlanLayers.userName): Data(edited.utf8)
            default: nil
            }
        }
        let controller = PlanNotesController()
        controller.tapeNotes = TapeStore(intakeDirectory: FileManager.default.temporaryDirectory).notes(in: tape)

        let view = HStack(spacing: 0) {
            PlanSection(intakeID: UUID(), tape: tape, loadFile: load, onSend: { _ in }, notes: controller)
                .padding(20)
            Divider()
            NotesRail(controller: controller, roundName: { _ in "Refine 1" }, focusesDraft: false)
                .frame(width: 340)
        }
        let out = URL(fileURLWithPath: path).deletingPathExtension().path + "-overlap.png"
        try PlanningRender.write(view, size: NSSize(width: 1100, height: 420), to: URL(fileURLWithPath: out))
        XCTAssertEqual(controller.edits, 1, "the edit count is the edit layer's hunks")
        XCTAssertEqual(controller.summary.tooltip, "Sends your 1 edit and 1 note")
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let match = find(type, in: sub) { return match } }
        return nil
    }
}
