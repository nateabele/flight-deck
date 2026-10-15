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

    /// The rail with committed notes, each wearing its type pop-up, one of them read by a round
    /// (disabled, its help saying why). Written beside `FD_NOTES_RENDER` as
    /// `<name>-types-light.png` and `<name>-types-dark.png`.
    func testRenderCommittedNoteTypeControls() throws {
        guard let path = ProcessInfo.processInfo.environment["FD_NOTES_RENDER"] else {
            throw XCTSkip("set FD_NOTES_RENDER to a PNG path to render the notes rail")
        }
        let plan = "# Plan\n\nJobs are offered in drive-time order.\n\nCheck-ins replay oldest-first.\n\nPaused stays.\n"
        func anchor(_ quote: String) -> NoteAnchor { NoteAnchor(checkpoint: 2, selecting: plan.range(of: quote)!, in: plan) }
        let pending = PlanNote(kind: .question, note: "What happens when two devices check in the same job?", anchor: anchor("oldest-first"))
        let highlight = PlanNote(kind: .comment, note: "", anchor: anchor("drive-time order"))
        let read = PlanNote(kind: .mustChange, note: "Drop paused.", anchor: anchor("Paused stays"))
        let controller = PlanNotesController()
        controller.tapeNotes = [TapeNote(note: read, consumedBy: 1), TapeNote(note: pending, consumedBy: nil),
                                TapeNote(note: highlight, consumedBy: nil)]
        controller.checkpoint = 2
        // Where the editor would have found each quote, so no card reads "can't find this text".
        controller.editorChanged(plan, located: Dictionary(uniqueKeysWithValues: [read, pending, highlight].map {
            ($0.id, NSRange($0.anchor!.locate(in: plan)!, in: plan)) }))
        let view = NotesRail(controller: controller, roundName: { _ in "Refine 1" }, focusesDraft: false)
            .frame(width: 340)
            .padding(20)
        let base = URL(fileURLWithPath: path).deletingPathExtension().path
        try PlanningRender.write(view, size: NSSize(width: 380, height: 520), to: URL(fileURLWithPath: base + "-types-dark.png"))
        try PlanningRender.write(view, size: NSSize(width: 380, height: 520), to: URL(fileURLWithPath: base + "-types-light.png"),
                                 appearance: .aqua)
    }

    // MARK: Notes pinned to the version they were written on

    private static let draftPlan = """
    # Field-service scheduling

    ## Storage

    Run PostgreSQL on encrypted gp3 EBS storage as the system of record for every app.

    ## Access

    Each owner controls a specific invite list for use and can publish their own drafts after automated checks.
    """

    private static let synthesisPlan = """
    # Field-service scheduling

    ## Storage

    One SQLite file per app, on a volume the platform snapshots nightly.

    ## Access

    Apps are open to the whole company unless the owner narrows them to an invite list.
    """

    /// The tape after synthesis: two notes written on the drafts (checkpoint 1) and read by
    /// synthesis (checkpoint 2), one written on the synthesis plan and still pending.
    private func pinnedTape() -> (tape: Tape, controller: PlanNotesController, load: (Int, String) -> Data?) {
        let draft = Self.draftPlan, synthesis = Self.synthesisPlan
        func anchor(_ quote: String, in plan: String, checkpoint: Int) -> NoteAnchor {
            NoteAnchor(checkpoint: checkpoint, selecting: plan.range(of: quote)!, in: plan)
        }
        let postgres = PlanNote(kind: .question, note: "Why not SQLite? Most of the state can live in memory anyway.",
                                anchor: anchor("Run PostgreSQL on encrypted gp3 EBS storage", in: draft, checkpoint: 1))
        let invites = PlanNote(kind: .comment, note: "Invite lists are optional. By default, apps are open to everyone.",
                               anchor: anchor("specific invite list", in: draft, checkpoint: 1))
        let cadence = PlanNote(kind: .mustChange, note: "Say how long snapshots are kept.",
                               anchor: anchor("snapshots nightly", in: synthesis, checkpoint: 2))
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        var tape = Tape(checkpoints: [
            Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: date),
            Checkpoint(id: 2, parent: 1, stage: .synthesis, round: 0, major: true, createdAt: date),
        ], target: .none, status: .paused)
        tape.checkpoints[1].record.annotations = [postgres, invites]
        tape.pendingNotes = [cadence]
        let load: (Int, String) -> Data? = { id, file in
            switch (id, file) {
            case (1, "drafts/0.md"): Data(draft.utf8)
            case (2, "plan.md"): Data(synthesis.utf8)
            default: nil
            }
        }
        let controller = PlanNotesController()
        controller.versionLabel = { id in tape.checkpoints.first { $0.id == id }.map(NoteVersion.label(of:)) }
        controller.tapeNotes = TapeStore(intakeDirectory: FileManager.default.temporaryDirectory).notes(in: tape)
        return (tape, controller, load)
    }

    /// The rail on the synthesis plan, showing the notes written on the drafts under their
    /// version. Written beside `FD_NOTES_RENDER` as `<name>-pinned-light.png` / `-pinned-dark.png`.
    func testRenderNotesPinnedToAnEarlierVersion() throws {
        guard let path = ProcessInfo.processInfo.environment["FD_NOTES_RENDER"] else {
            throw XCTSkip("set FD_NOTES_RENDER to a PNG path to render the notes rail")
        }
        let (tape, controller, load) = pinnedTape()
        controller.checkpoint = 2
        let view = HStack(spacing: 0) {
            PlanSection(intakeID: UUID(), tape: tape, loadFile: load, onSend: { _ in }, notes: controller)
                .padding(20)
            Divider()
            NotesRail(controller: controller, roundName: { _ in "Synthesis" }, focusesDraft: false)
                .frame(width: 340)
        }
        let base = URL(fileURLWithPath: path).deletingPathExtension().path
        let size = NSSize(width: 1000, height: 820)
        try PlanningRender.write(view, size: size, to: URL(fileURLWithPath: base + "-pinned-dark.png"))
        try PlanningRender.write(view, size: size, to: URL(fileURLWithPath: base + "-pinned-light.png"), appearance: .aqua)
        XCTAssertEqual(controller.pendingCount, 1)
    }

    /// What "Show in that version" arrives at: the drafts' plan, the note beside its own quote
    /// (no version header, anchored as always), and the synthesis-plan note now the one listed
    /// under another version. Written as `<name>-shown-light.png` / `-shown-dark.png`.
    func testRenderShowInThatVersionResult() throws {
        guard let path = ProcessInfo.processInfo.environment["FD_NOTES_RENDER"] else {
            throw XCTSkip("set FD_NOTES_RENDER to a PNG path to render the notes rail")
        }
        let (tape, controller, load) = pinnedTape()
        controller.checkpoint = 2
        let postgres = try XCTUnwrap(controller.notes.first { $0.note.note.hasPrefix("Why not SQLite") })
        controller.showInVersion(postgres.id)
        XCTAssertNotNil(controller.pendingReveal, "waiting for the drafts' plan to load")
        let view = HStack(spacing: 0) {
            PlanSection(intakeID: UUID(), tape: tape, loadFile: load, onSend: { _ in }, selection: .constant(1), notes: controller)
                .padding(20)
            Divider()
            NotesRail(controller: controller, roundName: { _ in "Synthesis" }, focusesDraft: false)
                .frame(width: 340)
        }
        let base = URL(fileURLWithPath: path).deletingPathExtension().path
        let size = NSSize(width: 1000, height: 820)
        try PlanningRender.write(view, size: size, to: URL(fileURLWithPath: base + "-shown-dark.png"))
        XCTAssertNil(controller.pendingReveal, "the drafts' plan loaded and used the request")
        controller.pendingReveal = nil
        try PlanningRender.write(view, size: size, to: URL(fileURLWithPath: base + "-shown-light.png"), appearance: .aqua)
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let match = find(type, in: sub) { return match } }
        return nil
    }
}
