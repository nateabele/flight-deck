import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Writing a note on a version of the plan other than the first, driven through the real plan
/// section the way the detail pane hosts it: select text, choose a kind from the selection
/// toolbar (`PlanNotesController.choose`, what each of its buttons calls), commit, and the note
/// that is sent is anchored to the version that was on screen.
@MainActor
final class NotesOnLaterVersionTests: XCTestCase {
    private final class Shown: ObservableObject { @Published var checkpoint: Int? }

    private let drafts = "# Plan\n\n## Storage\n\nRun PostgreSQL on encrypted storage as the system of record.\n"
    private let synthesis = "# Plan\n\n## Storage\n\nOne SQLite file per app, snapshotted nightly by the platform.\n"

    private func tape() -> Tape {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        return Tape(checkpoints: [
            Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: date),
            Checkpoint(id: 2, parent: 1, stage: .synthesis, round: 0, major: true, createdAt: date),
        ], target: .none, status: .paused)
    }

    private func load(_ id: Int, _ file: String) -> Data? {
        switch (id, file) {
        case (1, "drafts/0.md"): Data(drafts.utf8)
        case (2, "plan.md"): Data(synthesis.utf8)
        default: nil
        }
    }

    /// The detail pane's own order of events: the plan section appears (and tells the notes which
    /// checkpoint it shows) and the pane binds the notes for its intake (`bindNotes`, which resets).
    private struct Pane: View {
        let tape: Tape
        let load: (Int, String) -> Data?
        let notes: PlanNotesController
        @ObservedObject var shown: Shown
        var body: some View {
            PlanSection(intakeID: UUID(), tape: tape, loadFile: load, onSend: { _ in },
                        selection: Binding(get: { shown.checkpoint }, set: { shown.checkpoint = $0 }), notes: notes)
                .onChange(of: 0, initial: true) { notes.reset() }
        }
    }

    private func host(_ notes: PlanNotesController, shown: Shown) -> (NSWindow, NSView) {
        let pane = Pane(tape: tape(), load: load, notes: notes, shown: shown)
        let view = NSHostingView(rootView: pane.frame(width: 700, height: 500))
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 700, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        return (window, view)
    }

    private func settle(_ seconds: TimeInterval = 0.5) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func editor(in view: NSView) -> PlanNSTextView? {
        if let match = view as? PlanNSTextView { return match }
        for sub in view.subviews { if let match = editor(in: sub) { return match } }
        return nil
    }

    /// Selects `quote` in what the editor shows and chooses each kind, asserting a draft opens
    /// on the version shown and that committing it sends a note anchored there.
    private func assertEveryKindWorks(_ notes: PlanNotesController, view: NSView, version: Int, quote: String,
                                      sent: () -> [PlanNote], file: StaticString = #filePath, line: UInt = #line) throws {
        let textView = try XCTUnwrap(editor(in: view), file: file, line: line)
        let text = textView.string
        let range = NSRange(try XCTUnwrap(text.range(of: quote), file: file, line: line), in: text)
        for kind in NoteStyle.kinds {
            let before = sent().count
            notes.choose(kind, range: range, in: text)
            let draft = try XCTUnwrap(notes.draft, "\(kind) opened no draft on checkpoint \(version)", file: file, line: line)
            XCTAssertEqual(draft.anchor?.checkpoint, version, file: file, line: line)
            XCTAssertEqual(draft.anchor?.quote, quote, file: file, line: line)
            // The rail shows it as a card of this version, not one listed under another.
            XCTAssertNil(notes.pin(for: TapeNote(note: PlanNote(kind: kind, note: "x", anchor: draft.anchor), consumedBy: nil)),
                         file: file, line: line)
            notes.draft?.text = "words"
            notes.commitDraft()
            XCTAssertEqual(sent().count, before + 1, "\(kind) on checkpoint \(version) sent nothing", file: file, line: line)
            XCTAssertEqual(sent().last?.anchor?.checkpoint, version, file: file, line: line)
            XCTAssertEqual(sent().last?.kind, kind, file: file, line: line)
        }
        let highlights = sent().count
        notes.choose(nil, range: range, in: text)
        XCTAssertEqual(sent().count, highlights + 1, "Highlight sends at once", file: file, line: line)
        XCTAssertEqual(sent().last?.anchor?.checkpoint, version, file: file, line: line)
    }

    func testEveryKindWritesANoteOnTheLaterVersionAndAfterSwitchingBackAndForth() throws {
        let notes = PlanNotesController()
        var commands: [TapeCommand] = []
        notes.send = { commands.append($0) }
        let sent: () -> [PlanNote] = { commands.compactMap { if case .note(let n) = $0 { n } else { nil } } }
        let shown = Shown()
        let (window, view) = host(notes, shown: shown)
        defer { window.close() }

        // Following the head: the synthesis plan, a version that is not the first.
        settle()
        XCTAssertEqual(notes.checkpoint, 2, "the notes know which version is on screen")
        try assertEveryKindWorks(notes, view: view, version: 2, quote: "snapshotted nightly", sent: sent)

        // Back to the drafts, and to the synthesis plan again, twice over.
        for version in [1, 2, 1, 2] {
            shown.checkpoint = version
            settle()
            XCTAssertEqual(notes.checkpoint, version)
            let quote = version == 1 ? "Run PostgreSQL" : "snapshotted nightly"
            try assertEveryKindWorks(notes, view: view, version: version, quote: quote, sent: sent)
        }
    }

    /// A real click on the real toolbar's Comment button: select text with the editor focused, wait
    /// for the toolbar's panel, and press the mouse on it.
    private func clickComment(_ view: NSView, in window: NSWindow, quote: String) throws -> Bool {
        let textView = try XCTUnwrap(editor(in: view))
        window.makeFirstResponder(textView)
        let text = textView.string
        textView.setSelectedRange(NSRange(try XCTUnwrap(text.range(of: quote)), in: text))
        settle(0.5)
        guard let panel = window.childWindows?.first(where: { $0 is NSPanel }) else { return false }
        // Over the first item (Comment): inside the card's padding, a little way in, mid-height.
        let point = NSPoint(x: 34 + 3 + 30, y: panel.frame.height / 2)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            panel.sendEvent(event)
        }
        settle(0.3)
        return true
    }

    func testClickingTheToolbarOnTheLaterVersionOpensADraft() throws {
        let notes = PlanNotesController()
        var commands: [TapeCommand] = []
        notes.send = { commands.append($0) }
        // What the pane holds after synthesis: notes written on the drafts, read by it.
        let written = ["Run PostgreSQL", "system of record", "Storage"].map { q in
            PlanNote(kind: .question, note: "why", anchor: NoteAnchor(checkpoint: 1, selecting: drafts.range(of: q)!, in: drafts))
        }
        notes.tapeNotes = written.map { TapeNote(note: $0, consumedBy: 2) }
        let shown = Shown()
        let (window, view) = host(notes, shown: shown)
        defer { window.close() }
        settle()
        for (version, quote) in [(2, "snapshotted nightly"), (1, "Run PostgreSQL"), (2, "snapshotted nightly")] {
            shown.checkpoint = version
            settle()
            notes.cancelDraft()
            XCTAssertTrue(try clickComment(view, in: window, quote: quote), "the toolbar opened on checkpoint \(version)")
            XCTAssertEqual(notes.draft?.anchor?.checkpoint, version, "clicking Comment on checkpoint \(version) opened a draft")
        }
    }
}
