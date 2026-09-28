import AppKit
import XCTest
@testable import FlightDeck

final class PlanTextViewPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// `commands.jsonl` never compacts, so an edit per keystroke would grow it by a whole plan
    /// per character typed. Commits wait for `EditPolicy.idle` seconds of quiet.
    func testCommitAfterIdleNotPerKeystroke() {
        var session = PlanEditSession(text: "# Plan")
        session.editing = true
        for (i, text) in ["# Plan!", "# Plan!!", "# Plan!!!"].enumerated() {
            session.type(text, at: t0.addingTimeInterval(Double(i) * 0.5))
            XCTAssertNil(session.commitIfIdle(now: t0.addingTimeInterval(Double(i) * 0.5 + 0.4)), "no commit per keystroke")
        }
        XCTAssertTrue(session.dirty)
        XCTAssertNil(session.commitIfIdle(now: t0.addingTimeInterval(1.0 + EditPolicy.idle - 0.01)), "not before the idle window")
        XCTAssertEqual(session.commitIfIdle(now: t0.addingTimeInterval(1.0 + EditPolicy.idle)), "# Plan!!!")
        XCTAssertFalse(session.dirty)
        XCTAssertNil(session.commitIfIdle(now: t0.addingTimeInterval(60)), "one commit per burst, not one per tick")

        // Ending the edit commits at once, without waiting out the window — and only if dirty.
        session.type("# Plan?", at: t0.addingTimeInterval(100))
        XCTAssertEqual(session.endEditing(), "# Plan?")
        XCTAssertNil(session.endEditing())
        XCTAssertFalse(session.editing)
    }

    /// Review Focus 3: a round landing while the human types must not swap the text out from
    /// under them. The head is held back (the banner offers it) and not one keystroke is lost.
    func testIncomingHeadDoesNotReplaceTextWhileEditing() {
        XCTAssertFalse(EditPolicy.shouldReplace(editing: true, dirty: true))
        var session = PlanEditSession(text: "# Plan")
        session.editing = true
        session.type("# Plan, edited", at: t0)
        XCTAssertFalse(session.offer("# Plan v2"))
        XCTAssertEqual(session.current, "# Plan, edited")
        XCTAssertEqual(session.held, "# Plan v2")
        XCTAssertTrue(session.dirty, "the typed text is still uncommitted, not overwritten")
    }

    func testIncomingHeadReplacesWhenIdleAndClean() {
        XCTAssertTrue(EditPolicy.shouldReplace(editing: false, dirty: false))
        XCTAssertTrue(EditPolicy.shouldReplace(editing: true, dirty: false), "focused but committed: nothing to lose")
        XCTAssertTrue(EditPolicy.shouldReplace(editing: false, dirty: true), "not focused: the edit is committed on the way out")
        var session = PlanEditSession(text: "# Plan")
        XCTAssertTrue(session.offer("# Plan v2"))
        XCTAssertEqual(session.current, "# Plan v2")
        XCTAssertNil(session.held)
        XCTAssertFalse(session.dirty)
    }

    // MARK: - Coordinator

    /// A detached editor whose focus and input-method state the test sets directly.
    private final class StubTextView: PlanNSTextView {
        var marked = false
        override func hasMarkedText() -> Bool { marked }
    }

    private final class Recorder {
        var commits: [String] = []
        var shows = 0
    }

    private func coordinator(_ text: String, _ recorder: Recorder) -> (PlanTextView.Coordinator, StubTextView) {
        let view = PlanTextView(text: .constant(text), editable: true, onCommit: { recorder.commits.append($0) },
                                incoming: nil, onShowIncoming: { recorder.shows += 1 })
        let coordinator = view.makeCoordinator()
        let textView = StubTextView(usingTextLayoutManager: true)
        coordinator.textView = textView
        textView.delegate = coordinator
        coordinator.load(text)
        return (coordinator, textView)
    }

    /// Commits and `onShowIncoming` hop to the next main-queue turn.
    private func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    /// Undo history belongs to the text it was typed into: replayed after a new head was
    /// loaded, ⌘Z would splice stale ranges into it — and the idle timer commit the result.
    func testLoadClearsUndoHistory() throws {
        let (coordinator, textView) = coordinator("# Plan", Recorder())
        let undo = try XCTUnwrap(coordinator.undoManager(for: textView))
        undo.registerUndo(withTarget: textView) { _ in }
        XCTAssertTrue(undo.canUndo)
        coordinator.load("# Plan v2")
        XCTAssertFalse(undo.canUndo, "a loaded text starts with nothing to undo")
        // Without a window, NSTextView never asks its delegate; in one, it must get ours.
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = textView
        XCTAssertTrue(textView.undoManager === undo, "the editor's undo is its own, not the window's")
        // Real typing lands on that stack, and a load empties it.
        textView.allowsUndo = true
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        textView.insertText("!", replacementRange: textView.selectedRange())
        drain()  // the undo group typing opened closes at the end of the run-loop turn
        XCTAssertTrue(undo.canUndo, "typing registered on the editor's own undo")
        coordinator.load("# Plan v3")
        XCTAssertFalse(undo.canUndo)
    }

    /// An input method mid-composition: committing now would send half a character.
    func testIdleCommitWaitsOutMarkedText() {
        let recorder = Recorder()
        let (coordinator, textView) = coordinator("# Plan", recorder)
        coordinator.session.type("# Plan か", at: t0)
        textView.marked = true
        coordinator.idleFired(now: t0.addingTimeInterval(EditPolicy.idle + 1))
        drain()
        XCTAssertEqual(recorder.commits, [])
        XCTAssertTrue(coordinator.session.dirty)
        XCTAssertNotNil(coordinator.timer, "rescheduled, not dropped")
        textView.marked = false
        coordinator.idleFired(now: t0.addingTimeInterval(EditPolicy.idle + 3))
        drain()
        XCTAssertEqual(recorder.commits, ["# Plan か"])
        coordinator.timer?.invalidate()
    }

    /// Review Focus 3 at the view: a new head under a focused, dirty editor is held for the
    /// banner; the same head under an unfocused editor is taken.
    func testReceiveHoldsNewHeadWhileFocusedAndDirty() {
        let recorder = Recorder()
        let (coordinator, textView) = coordinator("# Plan", recorder)
        textView.isFocused = true
        coordinator.session.type("# Plan, typed", at: t0)
        coordinator.receive("# Plan v2", navigation: false)
        drain()
        XCTAssertEqual(coordinator.session.held, "# Plan v2")
        XCTAssertEqual(recorder.shows, 0)
        XCTAssertEqual(recorder.commits, [], "nothing committed behind the human's back")

        let (clean, cleanView) = self.coordinator("# Plan", recorder)
        cleanView.isFocused = false
        clean.receive("# Plan v2", navigation: false)
        drain()
        XCTAssertEqual(recorder.shows, 1)
        XCTAssertNil(clean.session.held)
    }

    /// Choosing another round is the human's own move, not news: the typed edit is committed
    /// to the checkpoint it was typed on and the chosen round loads — no "A new round landed".
    func testSelectionChangeFlushesAndLoadsEvenWhileEditing() {
        let recorder = Recorder()
        let (coordinator, textView) = coordinator("# Plan", recorder)
        textView.isFocused = true
        coordinator.session.type("# Plan, typed", at: t0)
        coordinator.receive("# Refine 1 plan", navigation: true)
        drain()
        XCTAssertNil(coordinator.session.held)
        XCTAssertEqual(recorder.commits, ["# Plan, typed"])
        XCTAssertEqual(recorder.shows, 1)
    }

    /// The caret block's syntax shows only while the editor has focus: an unfocused plan
    /// reads fully rendered, with no stray `##` where the caret last sat.
    func testSyntaxRevealedOnlyWhileFocused() throws {
        let (coordinator, textView) = coordinator("## Head\n\nbody", Recorder())
        let storage = try XCTUnwrap(textView.textStorage)
        func hashHidden() -> Bool {
            (storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == .clear
        }
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        XCTAssertTrue(hashHidden(), "unfocused: rendered")
        textView.isFocused = true
        coordinator.focusChanged()
        XCTAssertFalse(hashHidden(), "focused: the caret block reveals its syntax")
        textView.isFocused = false
        coordinator.focusChanged()
        XCTAssertTrue(hashHidden(), "focus left: rendered again")
    }
}
