import AppKit
import IntakeKit
import XCTest
@testable import FlightDeck

/// The plan editor's W4 review fixes, where the edit layer, notes and convergence meet: undo
/// for both kinds of Revert and for notes, a merged plan that must not clobber typing, merges
/// that re-read a moving head, and the notes and churn lane doing their work only where an
/// edit lands.
final class PlanEditorW4Tests: XCTestCase {
    private final class Commits { var all: [String] = [] }

    /// A windowed editor with the edit layer over `generated`, focused, typing through the
    /// real `insertText` path so the undo stack is the one a human's typing builds.
    @MainActor
    private func editor(_ text: String, generated: String, _ commits: Commits = Commits())
        -> (PlanTextView.Coordinator, PlanEditorContainer, NSWindow) {
        let view = PlanTextView(text: .constant(text), editable: true, onCommit: { commits.all.append($0) },
                                incoming: nil, onShowIncoming: {}).editLayer(generated: generated)
        let coordinator = view.makeCoordinator()
        let container = PlanEditorContainer(onShow: {})
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = container
        coordinator.textView = container.textView
        coordinator.revertButton = container.revert
        container.revert.onRevert = { [weak coordinator] in coordinator?.revert(hunk: $0) }
        container.textView.delegate = coordinator
        container.textView.textStorage?.delegate = coordinator
        coordinator.load(text)
        window.makeFirstResponder(container.textView)
        return (coordinator, container, window)
    }

    /// The undo group typing opens closes at the end of the run-loop turn; commits hop a turn.
    private func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    @MainActor
    private func type(_ s: String, at location: Int, in view: NSTextView) {
        view.setSelectedRange(NSRange(location: location, length: 0))
        view.insertText(s, replacementRange: view.selectedRange())
        drain()
    }

    // MARK: 1 · Revert all

    /// Revert all is one undoable change through the editor: ⌘Z brings every edit back at
    /// once, and the typing under it is still on the stack (it used to be a load, which
    /// emptied the stack — Revert all was final).
    @MainActor
    func testRevertAllIsOneUndoableChangeAndKeepsTheStack() throws {
        let generated = "# Plan\n\nalpha\nbeta\ngamma\n"
        let commits = Commits()
        let (coordinator, container, window) = editor(generated, generated: generated, commits)
        defer { coordinator.timer?.invalidate(); window.close() }
        let view = container.textView
        let undo = try XCTUnwrap(view.undoManager)
        type("A", at: (view.string as NSString).range(of: "alpha").location, in: view)
        type(" and more", at: (view.string as NSString).range(of: "gamma").upperBound, in: view)
        let edited = view.string
        XCTAssertEqual(coordinator.hunks.count, 2)
        // The typing is committed, as it would be after the idle window.
        coordinator.idleFired(now: Date().addingTimeInterval(EditPolicy.idle + 1))
        drain()
        XCTAssertEqual(commits.all, [edited])

        let handle = PlanEditorHandle()
        handle.coordinator = coordinator
        handle.revertAll()
        drain()
        XCTAssertEqual(view.string, generated)
        XCTAssertEqual(commits.all.last, generated, "committed at once, like any explicit action")
        XCTAssertEqual(undo.undoActionName, "Revert All Edits")

        undo.undo()
        drain()
        XCTAssertEqual(view.string, edited, "one ⌘Z brings back every edit")
        XCTAssertEqual(coordinator.hunks.count, 2, "and the layer with them")
        coordinator.idleFired(now: Date().addingTimeInterval(EditPolicy.idle + 1))
        drain()
        XCTAssertEqual(commits.all.last, edited, "and the undone edits are what the next round gets")
        XCTAssertTrue(undo.canUndo, "the typing before it is still on the stack")
        undo.undo()
        drain()
        XCTAssertNotEqual(view.string, edited, "the next ⌘Z undoes the typing")
    }

    func testRevertAllPromptCountsTheEdits() {
        XCTAssertEqual(EditLayer.revertAllPrompt(3), "Revert all 3 edits?")
        XCTAssertEqual(EditLayer.revertAllPrompt(1), "Revert your edit?")
    }

    // MARK: 9 · Per-hunk Revert

    /// Type, Revert that hunk, ⌘Z: the undo takes back the Revert only — the typing it
    /// followed is not coalesced into it.
    @MainActor
    func testRevertThenUndoUndoesOnlyTheRevert() throws {
        let generated = "# Plan\n\nalpha\nbeta\n"
        let (coordinator, container, window) = editor(generated, generated: generated)
        defer { coordinator.timer?.invalidate(); window.close() }
        let view = container.textView
        let undo = try XCTUnwrap(view.undoManager)
        // Typing, then (a separate event) the Revert: NSTextView keeps coalescing typing into
        // one undo action across events until something breaks it, and the Revert used to be
        // folded into the typing's action — ⌘Z then took back both.
        type("!", at: (view.string as NSString).range(of: "beta").upperBound, in: view)
        let typed = view.string
        coordinator.revert(hunk: 0)
        drain()
        XCTAssertEqual(view.string, generated)
        XCTAssertEqual(undo.undoActionName, "Revert Edit")
        undo.undo()
        drain()
        XCTAssertEqual(view.string, typed, "⌘Z undid the Revert and nothing more")
    }

    // MARK: 2 · A merged plan never clobbers typing

    /// The merge's plan for the head on screen is offered as `incoming` — a new text for the
    /// same checkpoint — not written into `text` (a load).
    func testMergedPlanIsOfferedAsIncoming() {
        typealias Loaded = PlanSectionBody.Loaded
        let shown = Loaded(checkpoint: 4, text: "# v4", editable: true)
        XCTAssertEqual(PlanSectionBody.offer("# merged", for: 4, shown: shown, incoming: nil),
                       Loaded(checkpoint: 4, text: "# merged", editable: true))
        let waiting = Loaded(checkpoint: 5, text: "# v5", editable: true)
        XCTAssertEqual(PlanSectionBody.offer("# merged", for: 5, shown: shown, incoming: waiting)?.text, "# merged",
                       "a head waiting behind the banner takes the merge")
        XCTAssertNil(PlanSectionBody.offer("# merged", for: 4, shown: Loaded(checkpoint: 2, text: "# v2", editable: false), incoming: nil),
                     "the human is on another round: its reload picks the merge up")
    }

    /// …and the editor's hold rule applies to it: focused and dirty, the merge waits behind
    /// the banner and not a keystroke is lost; clean, it is shown at once.
    @MainActor
    func testMergedPlanWaitsBehindTheBannerWhileTyping() {
        let generated = "# Plan\n\nalpha\n"
        var shows = 0
        let view = PlanTextView(text: .constant(generated), editable: true, onCommit: { _ in }, incoming: nil,
                                onShowIncoming: { shows += 1 })
        let coordinator = view.makeCoordinator()
        let container = PlanEditorContainer(onShow: {})
        coordinator.textView = container.textView
        container.textView.delegate = coordinator
        coordinator.load(generated)
        container.textView.isFocused = true
        coordinator.session.type("# Plan\n\nalpha, typing\n", at: Date())
        coordinator.receive("# Plan\n\nalpha\nmerged\n", navigation: false)
        drain()
        XCTAssertEqual(coordinator.session.held, "# Plan\n\nalpha\nmerged\n", "held for the banner")
        XCTAssertEqual(coordinator.session.current, "# Plan\n\nalpha, typing\n", "the typing is untouched")
        XCTAssertEqual(shows, 0)
        coordinator.timer?.invalidate()
    }

    // MARK: 3 · Stale head

    private func tape(heads: [Int], conflictAt head: Int? = nil, for edits: Int? = nil) -> Tape {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        return Tape(checkpoints: heads.map { id in
            Checkpoint(id: id, stage: id == 1 ? .draft : .refine, round: max(id - 1, 0), major: id == 1, createdAt: date,
                       record: RoundRecord(editConflict: id == head ? edits : nil))
        })
    }

    private final class Box<T> { var value: T; init(_ v: T) { value = v } }

    /// A fake `git merge-file`: records each merge's "ours", lets the test move the head while
    /// it "runs", and answers with a clean merge (ours + the edit's marker) or a conflict.
    private final class MergeRunner: CommandRunner, @unchecked Sendable {
        var ours: [String] = []
        var during: [() -> Void] = []
        var conflict = false
        func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
                 processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?) async throws -> CommandResult {
            let ours = (try? String(contentsOf: cwd.appendingPathComponent("ours.md"), encoding: .utf8)) ?? ""
            let call = self.ours.count
            self.ours.append(ours)
            if call < during.count { await MainActor.run { during[call]() } }
            if conflict { return CommandResult(stdout: Data("<<<<<<<".utf8), stderr: "", exitCode: 1) }
            return CommandResult(stdout: Data((ours + "+edit").utf8), stderr: "", exitCode: 0)
        }
    }

    @MainActor
    private func router(_ live: Box<Tape>, _ runner: MergeRunner, sent: Box<[TapeCommand]>, conflicts: Box<[EditConflict]>,
                        delivered: Box<[Int]>) -> PlanEditRouter {
        let router = PlanEditRouter()
        router.env = PlanEditRouter.Env(tape: { live.value },
                                        loadFile: { id, path in path == "plan.md" ? Data("plan \(id)".utf8) : nil },
                                        send: { sent.value.append($0) }, onConflict: { conflicts.value.append($0) },
                                        deliver: { checkpoint, _ in delivered.value.append(checkpoint) }, runner: runner)
        return router
    }

    /// The head moves while a merge runs — twice. Each time the merge is redone against the
    /// head as it is now, and the edit lands on the newest head, merged onto ITS plan.
    @MainActor
    func testHeadMovingTwiceDuringTheMergeMergesAgainOntoTheNewest() async {
        let live = Box(tape(heads: [1, 2, 3]))
        let runner = MergeRunner()
        runner.during = [{ live.value = self.tape(heads: [1, 2, 3, 4]) }, { live.value = self.tape(heads: [1, 2, 3, 4, 5]) }]
        let sent = Box<[TapeCommand]>([]), conflicts = Box<[EditConflict]>([]), delivered = Box<[Int]>([])
        let router = router(live, runner, sent: sent, conflicts: conflicts, delivered: delivered)

        router.commit("typed on 2", typedOn: 2, loaded: "plan 2", editable: true)
        await router.settle()
        XCTAssertEqual(runner.ours, ["plan 3", "plan 4", "plan 5"], "each merge re-read the head")
        XCTAssertEqual(sent.value, [.editPlan(checkpoint: 5, markdown: "plan 5+edit")])
        XCTAssertEqual(conflicts.value, [])
        XCTAssertEqual(delivered.value, [5], "offered to the editor, never loaded")
    }

    /// A head that keeps moving past the cap: the edit stays on its own round and the banner
    /// says so, rather than chasing the head forever.
    @MainActor
    func testHeadThatKeepsMovingLeavesTheEditOnItsRound() async {
        let live = Box(tape(heads: [1, 2, 3]))
        let runner = MergeRunner()
        runner.during = (4...6).map { n in { live.value = self.tape(heads: Array(1...n)) } }
        let sent = Box<[TapeCommand]>([]), conflicts = Box<[EditConflict]>([]), delivered = Box<[Int]>([])
        let router = router(live, runner, sent: sent, conflicts: conflicts, delivered: delivered)

        router.commit("typed on 2", typedOn: 2, loaded: "plan 2", editable: true)
        await router.settle()
        XCTAssertEqual(runner.ours.count, PlanEditRouter.maxMerges)
        XCTAssertEqual(sent.value, [.editPlan(checkpoint: 2, markdown: "typed on 2")])
        XCTAssertEqual(conflicts.value, [EditConflict(edits: 2, landedIn: 6)])
        XCTAssertTrue(router.stuck.contains(2))
    }

    /// A merge queued behind another re-reads the head when its turn comes: the round that
    /// landed meanwhile recorded that it could not carry this checkpoint's edits, so the edit
    /// is stuck behind that conflict — sent to its own round, not merged onto the head.
    @MainActor
    func testQueuedMergeSeesTheConflictThatLandedWhileItWaited() async {
        let live = Box(tape(heads: [1, 2, 3]))
        let runner = MergeRunner()
        runner.during = [{ live.value = self.tape(heads: [1, 2, 3, 4], conflictAt: 4, for: 2) }]
        let sent = Box<[TapeCommand]>([]), conflicts = Box<[EditConflict]>([]), delivered = Box<[Int]>([])
        let router = router(live, runner, sent: sent, conflicts: conflicts, delivered: delivered)

        router.commit("first", typedOn: 2, loaded: "plan 2", editable: true)
        router.commit("second", typedOn: 2, loaded: "plan 2", editable: true)
        await router.settle()
        XCTAssertTrue(router.stuck.contains(2))
        XCTAssertEqual(sent.value.last, .editPlan(checkpoint: 2, markdown: "second"), "stuck behind the round's conflict")
        XCTAssertFalse(sent.value.contains(.editPlan(checkpoint: 4, markdown: "plan 4+edit")), "never merged onto the head that refused it")
    }

    /// A merge conflict at git keeps the edit on its round and raises the banner, as before.
    @MainActor
    func testConflictKeepsTheEditOnItsRound() async {
        let live = Box(tape(heads: [1, 2, 3]))
        let runner = MergeRunner()
        runner.conflict = true
        let sent = Box<[TapeCommand]>([]), conflicts = Box<[EditConflict]>([]), delivered = Box<[Int]>([])
        let router = router(live, runner, sent: sent, conflicts: conflicts, delivered: delivered)
        router.commit("typed", typedOn: 2, loaded: "plan 2", editable: true)
        await router.settle()
        XCTAssertEqual(sent.value, [.editPlan(checkpoint: 2, markdown: "typed")])
        XCTAssertEqual(conflicts.value, [EditConflict(edits: 2, landedIn: 3)])
        // Later commits of the same edit stay with it, without trying the merge again.
        router.commit("typed more", typedOn: 2, loaded: "plan 2", editable: true)
        await router.settle()
        XCTAssertEqual(runner.ours.count, 1)
        XCTAssertEqual(sent.value.last, .editPlan(checkpoint: 2, markdown: "typed more"))
    }

    /// On the head with nothing queued, a commit is sent at once — a Step pressed right after
    /// typing must find it already sent.
    @MainActor
    func testCommitOnTheHeadIsSentSynchronously() {
        let live = Box(tape(heads: [1, 2]))
        let sent = Box<[TapeCommand]>([]), conflicts = Box<[EditConflict]>([]), delivered = Box<[Int]>([])
        let router = router(live, MergeRunner(), sent: sent, conflicts: conflicts, delivered: delivered)
        router.commit("typed", typedOn: 2, loaded: "plan 2", editable: true)
        XCTAssertEqual(sent.value, [.editPlan(checkpoint: 2, markdown: "typed")])
    }

    // MARK: 7 · Annotate §N

    @MainActor
    func testAnnotateSectionAnchorsOnItsHeading() throws {
        let plan = "# Plan\n\n## 3. Jobs\nJobs.\n\n## 4. Dispatch rules\nOffered by drive time.\n"
        let notes = PlanNotesController()
        notes.checkpoint = 7
        notes.editorChanged(plan)
        notes.selection = NSRange(location: 0, length: 6)  // a selection elsewhere must not win
        notes.annotate(section: "## 4. Dispatch rules")
        let anchor = try XCTUnwrap(notes.draft?.anchor)
        var expected = NoteAnchor(checkpoint: 7, selecting: plan.range(of: "## 4. Dispatch rules")!, in: plan)
        expected.section = "## 4. Dispatch rules"
        XCTAssertEqual(anchor, expected)
        XCTAssertEqual(anchor.section, "## 4. Dispatch rules", "the note is about §4, not the section above its heading")
        XCTAssertEqual(anchor.locate(in: plan).map { String(plan[$0]) }, "## 4. Dispatch rules")
        XCTAssertEqual(notes.draft?.kind, .comment)

        // A heading renamed since the verdict still matches by its § number.
        notes.cancelDraft()
        notes.annotate(section: "## 4. Dispatch")
        XCTAssertEqual(notes.draft?.anchor?.quote, "## 4. Dispatch rules")

        // Gone from the plan: a note about the whole plan rather than a guess.
        notes.cancelDraft()
        notes.annotate(section: "## 9. Nowhere")
        XCTAssertNotNil(notes.draft)
        XCTAssertNil(notes.draft?.anchor)
    }

    // MARK: 10 · Note undo

    /// Adding and removing a note go on the editor's undo stack, and each undo sends the
    /// command that reverses it.
    @MainActor
    func testNoteAddAndRemoveAreUndoable() throws {
        let plan = "# Plan\n\nOffered by drive time.\n"
        let undo = UndoManager()
        undo.groupsByEvent = false
        let notes = PlanNotesController()
        var sent: [TapeCommand] = []
        notes.send = { sent.append($0) }
        notes.undoManager = undo
        notes.checkpoint = 2
        notes.editorChanged(plan)

        undo.beginUndoGrouping()
        notes.choose(nil, range: NSRange(plan.range(of: "drive time")!, in: plan), in: plan)
        undo.endUndoGrouping()
        guard case .note(let note)? = sent.last else { return XCTFail("a highlight is sent at once: \(sent)") }
        XCTAssertEqual(undo.undoActionName, "Add Note")

        undo.undo()
        XCTAssertEqual(sent.last, .removeNote(note.id), "undoing the add withdraws it")
        XCTAssertEqual(notes.pendingCount, 0)
        undo.redo()
        XCTAssertEqual(sent.last, .note(note), "redo sends it again")
        XCTAssertEqual(notes.pendingCount, 1)

        undo.beginUndoGrouping()
        notes.remove(note.id)
        undo.endUndoGrouping()
        XCTAssertEqual(undo.undoActionName, "Remove Note")
        XCTAssertEqual(notes.pendingCount, 0)
        undo.undo()
        XCTAssertEqual(sent.last, .note(note), "undoing the removal sends the note back")
        XCTAssertEqual(notes.pendingCount, 1)
        XCTAssertEqual(notes.notes.map(\.id), [note.id])
    }

    // MARK: 5 · Scroll beats

    /// A burst of scroll events is one geometry beat a frame, not one per event.
    @MainActor
    func testGeometryBeatsAtMostOncePerFrame() {
        let geometry = NotesGeometry()
        for _ in 0..<50 { geometry.bump() }
        XCTAssertEqual(geometry.beat, 0, "coalesced to the next frame")
        RunLoop.main.run(until: Date().addingTimeInterval(NotesGeometry.frame * 2))
        XCTAssertEqual(geometry.beat, 1)
    }

    // MARK: 4, 5 · Notes follow edits without re-finding every quote

    /// Typing before a note moves its cached range by the edit's length (no search); typing
    /// that deletes its quote re-finds it — and finds it gone.
    @MainActor
    func testNoteRangesMoveWithEditsAndDetachWhenTheQuoteGoes() throws {
        let plan = "# Plan\n\nOffered by drive time.\n\nLater text.\n"
        let (coordinator, container, window) = editor(plan, generated: plan)
        defer { coordinator.timer?.invalidate(); window.close() }
        let notes = PlanNotesController()
        notes.checkpoint = 2
        let anchor = NoteAnchor(checkpoint: 2, selecting: plan.range(of: "Later text")!, in: plan)
        notes.tapeNotes = [TapeNote(note: PlanNote(note: "n", anchor: anchor), consumedBy: nil)]
        coordinator.notesBridge.attach(notes, to: container.textView)
        let id = notes.tapeNotes[0].id
        drain()
        let view = container.textView
        XCTAssertEqual(notes.located[id], (view.string as NSString).range(of: "Later text"))

        type("New words. ", at: (view.string as NSString).range(of: "Offered").location, in: view)
        drain()
        XCTAssertEqual(notes.located[id], (view.string as NSString).range(of: "Later text"), "moved with the text")

        view.insertText("", replacementRange: (view.string as NSString).range(of: "Later text"))
        drain()
        XCTAssertNil(notes.located[id], "its quote is gone: detached")
        type("Later text", at: (view.string as NSString).length - 2, in: view)
        drain()
        XCTAssertNotNil(notes.located[id], "typed back: found again")
    }

    /// Kind shows through the tag and the band's hover, never through colour: every band is
    /// the one highlight tint, whatever its kind.
    @MainActor
    func testBandsAreOneTintAndHoverSaysTheKind() {
        let plan = "# Plan\n\nOffered by drive time.\n\nCut this line.\n"
        let (coordinator, container, window) = editor(plan, generated: plan)
        defer { coordinator.timer?.invalidate(); window.close() }
        let notes = PlanNotesController()
        notes.checkpoint = 2
        func note(_ kind: NoteKind, _ quote: String, _ text: String) -> TapeNote {
            TapeNote(note: PlanNote(kind: kind, note: text, anchor: NoteAnchor(checkpoint: 2, selecting: plan.range(of: quote)!, in: plan)),
                     consumedBy: nil)
        }
        notes.tapeNotes = [note(.question, "drive time", "Which provider?"), note(.delete, "Cut this line.", "")]
        coordinator.notesBridge.attach(notes, to: container.textView)
        container.textView.textLayoutManager?.ensureLayout(for: container.textView.textLayoutManager!.documentRange)
        let bands = container.textView.subviews.compactMap { $0 as? NoteBandView }.first
        XCTAssertEqual(bands?.marks.count, 2)
        XCTAssertEqual(Set(bands?.marks.map(\.color) ?? []).count, 1, "one tint for every kind")
        XCTAssertEqual(bands?.marks.first?.color, NoteStyle.highlight.withAlphaComponent(NoteStyle.highlightAlpha))

        func point(over quote: String) -> NSPoint {
            let range = (container.textView.string as NSString).range(of: quote)
            let layout = container.textView.textLayoutManager!, content = layout.textContentManager!
            let start = content.location(content.documentRange.location, offsetBy: range.location)!
            var frame = CGRect.zero
            layout.enumerateTextSegments(in: NSTextRange(location: start, end: content.location(start, offsetBy: range.length))!,
                                         type: .standard, options: []) { _, f, _, _ in frame = f; return false }
            let origin = container.textView.textContainerOrigin
            return NSPoint(x: frame.midX + origin.x, y: frame.midY + origin.y)
        }
        XCTAssertEqual(coordinator.notesBridge.hoverText(at: point(over: "drive time")), "Question: Which provider?")
        XCTAssertEqual(coordinator.notesBridge.hoverText(at: point(over: "Cut this")), "Delete")
    }

    // MARK: 4, 6 · The churn lane

    /// Typing in a body line only moves the lane's offsets; a keystroke on a heading rescans.
    @MainActor
    func testChurnLaneRescansOnlyForHeadingEdits() {
        let (coordinator, container, _, window) = PlanEditorKeystrokeTests.editor()
        defer { coordinator.timer?.invalidate(); window.close() }
        let view = container.textView
        let lane = container.churnLane
        let before = lane.rescans
        type("abc", at: (view.string as NSString).range(of: "Techs check in on arrival 130.").location, in: view)
        XCTAssertEqual(lane.rescans, before, "a body edit moves offsets, no rescan")
        type("!", at: (view.string as NSString).range(of: "## 7. Section 7").upperBound, in: view)
        XCTAssertEqual(lane.rescans, before + 1, "a heading edit rescans")
        XCTAssertFalse(lane.isHidden)
    }

    /// The lane measures only what is on screen: drawing it must not lay out the plan down
    /// to a far-off marker (`.ensuresLayout` for an off-screen heading did exactly that).
    @MainActor
    func testChurnLaneMeasuresOnlyVisibleMarkers() {
        let (coordinator, container, _, window) = PlanEditorKeystrokeTests.editor()
        defer { coordinator.timer?.invalidate(); window.close() }
        let lane = container.churnLane
        let all = lane.markerRects(all: true)
        let shown = lane.markerRects()
        XCTAssertGreaterThan(all.count, shown.count, "markers below the fold are skipped")
        XCTAssertTrue(shown.allSatisfy { $0.1.minY < container.textView.visibleRect.maxY + 200 })
    }

    // MARK: 4 · Decoration layers walk only their own span

    /// A layer's refresh walks only the span its runs can be in — moved by edits — and still
    /// clears every run it set.
    @MainActor
    func testDecorationLayerKeepsItsExtentThroughEdits() {
        let view = NSTextView(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        view.string = "hello world\nsecond line\nthird line\n"
        let layout = view.textLayoutManager!
        let layer = DecorationLayer(key: "t")
        layer.apply([(NSRange(location: 12, length: 6), [.backgroundColor: NSColor.green])], to: layout)
        XCTAssertEqual(layer.extent, NSRange(location: 12, length: 6))
        view.insertText("XXXX", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(layer.extent, NSRange(location: 16, length: 6), "moved with the text")
        layer.apply([], to: layout)
        XCTAssertEqual(renderingRuns(layout, .backgroundColor), [], "the moved run was found and cleared")
        XCTAssertNil(layer.extent)
    }

    func testTextEditShift() {
        let edit = TextEdit(range: NSRange(location: 10, length: 3), delta: 3)  // typed "abc" at 10
        XCTAssertEqual(edit.shift(NSRange(location: 0, length: 5)), NSRange(location: 0, length: 5), "before: unmoved")
        XCTAssertEqual(edit.shift(NSRange(location: 10, length: 4)), NSRange(location: 13, length: 4), "typed right before it: moved")
        XCTAssertEqual(edit.shift(NSRange(location: 5, length: 5)), NSRange(location: 5, length: 5), "typed right after it: not in it")
        XCTAssertNil(edit.shift(NSRange(location: 8, length: 5)), "typed inside: re-find it")
        let cut = TextEdit(range: NSRange(location: 4, length: 0), delta: -4)  // deleted 4..<8
        XCTAssertEqual(cut.shift(NSRange(location: 8, length: 2)), NSRange(location: 4, length: 2))
        XCTAssertNil(cut.shift(NSRange(location: 6, length: 4)))
    }
}
