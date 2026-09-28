import AppKit
import IntakeKit
import XCTest
@testable import FlightDeck

final class EditLayerTests: XCTestCase {
    /// A whole inserted line is green over the line itself; a whole deleted line is a ghost at
    /// the start of the line that now follows it; a one-line change is compared inside the
    /// line, so only the words the human changed are marked — "Unassigned ~~for 24 hours~~
    /// until a dispatcher assigns it", as in the mockup, not the whole sentence twice.
    func testMarksForInsertAndDelete() {
        let generated = """
        # Plan
        Keep this.
        A job stays Unassigned for 24 hours.
        Drop this line.
        End.
        """
        let edited = """
        # Plan
        Keep this.
        Brand new line.
        A job stays Unassigned until a dispatcher assigns it.
        End.
        """
        let (marks, hunks) = EditLayer.marks(generated: generated, edited: edited)
        let ns = edited as NSString
        XCTAssertFalse(hunks.isEmpty)

        let inserted = marks.filter { $0.kind == .inserted }.map { ns.substring(with: $0.range) }
        XCTAssertTrue(inserted.contains("Brand new line.\n"), "a whole inserted line, its newline included: \(inserted)")
        XCTAssertTrue(inserted.contains("until a dispatcher assigns it"), "only the changed words: \(inserted)")

        let ghosts = marks.filter { $0.kind == .deleted }
        let inline = ghosts.first { $0.ghost == "for 24 hours" }
        XCTAssertNotNil(inline, "the removed words, not the whole old line: \(ghosts.map(\.ghost))")
        XCTAssertEqual(inline?.inline, true)
        XCTAssertEqual(inline?.range, NSRange(location: ns.range(of: "until").location, length: 0),
                       "the ghost sits where the removed words were, before the inserted ones")
        let line = ghosts.first { $0.ghost == "Drop this line." }
        XCTAssertNotNil(line, "a whole deleted line: \(ghosts.map(\.ghost))")
        XCTAssertEqual(line?.inline, false)
        XCTAssertEqual(line?.range, NSRange(location: ns.range(of: "End.").location, length: 0),
                       "a deleted line is drawn above the line that follows it")
        // Every mark is attributed to a hunk the diff actually has.
        XCTAssertTrue(marks.allSatisfy { hunks.indices.contains($0.hunk) })
    }

    func testNoMarksWhenNoUserEdits() {
        let plan = "# Plan\n\n- one\n- two\n"
        let (marks, hunks) = EditLayer.marks(generated: plan, edited: plan)
        XCTAssertTrue(marks.isEmpty)
        XCTAssertTrue(hunks.isEmpty)
        XCTAssertNil(EditLayer.chip(hunks), "no chip without edits")
    }

    func testChipCounts() {
        let generated = "a\nb\nc\nd\ne\n"
        XCTAssertEqual(EditLayer.chip(PlanLayers.userDiff(generated: generated, edited: "a\nB\nc\nd\ne\n")), "1 edit by you")
        XCTAssertEqual(EditLayer.chip(PlanLayers.userDiff(generated: generated, edited: "A\nb\nC\nd\nE\n")), "3 edits by you")
    }

    /// Revert on one hunk puts back exactly that hunk: the other edits survive, and reverting
    /// them all gives back the agents' plan byte for byte (which the runner then stores as "no
    /// edits" — `TapeStore.writeUserEdits`).
    func testRevertOneHunkRoundTrips() throws {
        let generated = "# Plan\n\nalpha\nbeta\ngamma\n"
        let edited = "# Plan\n\nALPHA\nbeta\ngamma\ndelta\n"
        let (_, hunks) = EditLayer.marks(generated: generated, edited: edited)
        XCTAssertEqual(hunks.count, 2)
        let once = try XCTUnwrap(PlanLayers.revert(hunks[0], generated: generated, edited: edited))
        XCTAssertEqual(once, "# Plan\n\nalpha\nbeta\ngamma\ndelta\n")
        let left = EditLayer.marks(generated: generated, edited: once).hunks
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(PlanLayers.revert(left[0], generated: generated, edited: once), generated)
    }

    func testConflictBannerText() {
        let names: (Int) -> String = { [3: "Refine 2", 4: "Refine 3"][$0] ?? "checkpoint \($0)" }
        XCTAssertNil(EditLayer.conflictBanner([], names: names))
        XCTAssertEqual(EditLayer.conflictBanner([EditConflict(edits: 3, landedIn: 4)], names: names),
                       "Your edits to Refine 2 conflicted with this round")

        // The notice is on the new head only: once another round lands over it, the conflict
        // is history, not news.
        let notice = EditLayer.conflictNotice([EditConflict(edits: 3, landedIn: 4)], head: 4, names: names)
        XCTAssertEqual(notice, EditConflictNotice(title: "Your edits to Refine 2 conflicted with this round",
                                                  openLabel: "Open Refine 2", open: 3))
        XCTAssertNil(EditLayer.conflictNotice([EditConflict(edits: 3, landedIn: 4)], head: 5, names: names))
    }

    /// Ruling: the deletion ghosts and every other part of the layer are attributes and drawing,
    /// never characters — the editor's text stays byte-identical to `plan.user.md`, or the
    /// next commit would write the ghosts into the plan.
    @MainActor
    func testStoredTextStaysByteIdenticalUnderTheLayer() {
        let generated = "# Plan\n\nA job stays Unassigned for 24 hours.\nDrop this line.\nEnd.\n"
        let edited = "# Plan\n\nA job stays Unassigned until assigned.\nNew line.\nEnd.\n"
        let container = PlanEditorContainer(onShow: {})
        container.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let view = container.textView
        view.string = edited
        let storage = view.textStorage!
        MarkdownStyler.apply(to: storage, blocks: MarkdownStyler.blocks(edited), revealBlock: nil, theme: .standard)
        let marks = EditLayer.marks(generated: generated, edited: edited).marks
        XCTAssertTrue(marks.contains { $0.kind == .deleted })
        EditLayer.apply(marks, to: storage, within: nil, theme: .standard)
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)

        XCTAssertEqual(Data(view.string.utf8), Data(edited.utf8))
        XCTAssertEqual(storage.length, (edited as NSString).length)
        XCTAssertFalse(storage.string.contains("\u{FFFC}"), "no attachment characters")
    }

    /// Carried from Task 10: an edit committed after the head moved on is three-way merged
    /// onto the new head and sent for it. The merge runs off the main actor — called from it,
    /// as `PlanSection` does.
    @MainActor
    func testRetargetCleanMergeSendsForTheNewHead() async {
        let runner = MergeSpy(result: CommandResult(stdout: Data("merged plan\n".utf8), stderr: "", exitCode: 0))
        let outcome = await EditLayer.retarget(markdown: "edited\n", typedOn: 2, base: "base\n", head: 3,
                                               headPlan: "head\n", runner: runner)
        XCTAssertEqual(outcome, EditLayer.Retarget(command: .editPlan(checkpoint: 3, markdown: "merged plan\n"), conflict: nil))
        XCTAssertEqual(runner.calls.first?.arguments, ["merge-file", "-p", "ours.md", "base.md", "theirs.md"])
        XCTAssertEqual(runner.calls.first?.files, ["ours.md": "head\n", "base.md": "base\n", "theirs.md": "edited\n"])
        XCTAssertEqual(runner.calls.first?.onMain, false, "git runs off the main actor")
    }

    /// A conflict keeps the edit on the checkpoint it was typed on, as before, and reports it
    /// for the banner.
    @MainActor
    func testRetargetConflictKeepsTheEditOnItsCheckpoint() async {
        let runner = MergeSpy(result: CommandResult(stdout: Data("<<<<<<<".utf8), stderr: "", exitCode: 1))
        let outcome = await EditLayer.retarget(markdown: "edited\n", typedOn: 2, base: "base\n", head: 3,
                                               headPlan: "head\n", runner: runner)
        XCTAssertEqual(outcome, EditLayer.Retarget(command: .editPlan(checkpoint: 2, markdown: "edited\n"),
                                                   conflict: EditConflict(edits: 2, landedIn: 3)))
    }

    /// The real tool, once: an edit to one section and a round's change to another merge.
    func testRetargetWithRealGitMergesDisjointChanges() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { throw XCTSkip("no git") }
        let base = "# Plan\n\n## A\none\n\n## B\ntwo\n\n## C\nthree\n"
        let head = "# Plan\n\n## A\none, refined\n\n## B\ntwo\n\n## C\nthree\n"
        let edited = "# Plan\n\n## A\none\n\n## B\ntwo\n\n## C\nthree, mine\n"
        let outcome = await EditLayer.retarget(markdown: edited, typedOn: 2, base: base, head: 3, headPlan: head,
                                               runner: SystemCommandRunner())
        XCTAssertEqual(outcome.command, .editPlan(checkpoint: 3, markdown: "# Plan\n\n## A\none, refined\n\n## B\ntwo\n\n## C\nthree, mine\n"))
        XCTAssertNil(outcome.conflict)
    }

    /// The layer's diff runs on every keystroke, next to the styler's pass (Task 10 budget).
    func testMarksWithinAFrameOn2000Lines() {
        var lines: [String] = []
        for i in 0..<250 {
            lines += ["## Section \(i)", "", "Prose with **bold** and `code` \(i).", "- item one", "1. item two",
                      "```", "let x = \(i)", "```"]
        }
        let generated = lines.joined(separator: "\n")
        var editedLines = lines
        editedLines[400] = "Prose with **bold** and a human's change."
        editedLines.insert("- a new item", at: 1203)
        editedLines.remove(at: 1800)
        let edited = editedLines.joined(separator: "\n")
        let clock = ContinuousClock()
        var marks: [EditMark] = []
        let elapsed = clock.measure { marks = EditLayer.marks(generated: generated, edited: edited).marks }
        XCTAssertFalse(marks.isEmpty)
        print("EditLayer timing: marks on 2000 lines \(elapsed)")
        XCTAssertLessThan(elapsed, .milliseconds(16))
    }
}

extension EditLayerTests {
    private final class Commits { var all: [String] = [] }

    @MainActor
    private func editor(_ text: String, generated: String, _ commits: Commits) -> (PlanTextView.Coordinator, PlanEditorContainer) {
        let view = PlanTextView(text: .constant(text), editable: true, onCommit: { commits.all.append($0) },
                                incoming: nil, onShowIncoming: {}).editLayer(generated: generated)
        let coordinator = view.makeCoordinator()
        let container = PlanEditorContainer(onShow: {})
        container.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        coordinator.textView = container.textView
        coordinator.revertButton = container.revert
        container.revert.onRevert = { [weak coordinator] in coordinator?.revert(hunk: $0) }
        container.textView.delegate = coordinator
        container.textView.textStorage?.delegate = coordinator
        coordinator.load(text)
        return (coordinator, container)
    }

    /// The layer's attributes where the plan is laid out from scratch, for comparison.
    @MainActor
    private func layerSignature(_ view: NSTextView) -> [String] {
        let storage = view.textStorage!
        var out = renderingRuns(view.textLayoutManager!, .backgroundColor).map { "tint \($0)" }
        let all = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.planEditInserted, in: all) { v, r, _ in if v != nil { out.append("ins \(r)") } }
        storage.enumerateAttribute(.planEditGhosts, in: all) { v, r, _ in
            if let g = v as? EditGhosts { out.append("ghost \(r.location) \(g.all.map(\.text))") }
        }
        storage.enumerateAttribute(.kern, in: all) { v, r, _ in if let k = v as? CGFloat, k != 0 { out.append("kern \(r) \(k)") } }
        storage.enumerateAttribute(.paragraphStyle, in: all) { v, r, _ in
            if let p = v as? NSParagraphStyle, p.paragraphSpacingBefore > 0 || p.paragraphSpacing > 0 || p.firstLineHeadIndent > 0 {
                out.append("para \(r) \(p.paragraphSpacingBefore) \(p.paragraphSpacing) \(p.firstLineHeadIndent)")
            }
        }
        return out
    }

    /// Keystrokes restyle only what changed (Task 10), and the layer rides along: after typing
    /// that grows, splits and removes hunks, the attributes equal a from-scratch layout of the
    /// same text — nothing stale left behind, no ghost's room added twice.
    @MainActor
    func testTypingKeepsTheLayerEqualToAFreshLayout() {
        let generated = "# Plan\n\n- one\n- two stays for now.\n- three\n\n## Next\n\nfour\n"
        let (_, container) = editor(generated, generated: generated, Commits())
        let view = container.textView
        func type(_ s: String, at location: Int) {
            view.setSelectedRange(NSRange(location: location, length: 0))
            view.insertText(s, replacementRange: view.selectedRange())
        }
        func delete(_ range: NSRange) { view.insertText("", replacementRange: range) }
        var ns: NSString { view.string as NSString }
        type(" added", at: ns.range(of: "- one").upperBound)
        delete(ns.range(of: "for now"))
        type("later", at: ns.range(of: "stays ").upperBound)
        delete(ns.range(of: "- three\n"))
        type("- new line\n", at: ns.range(of: "four").location)
        type("x", at: ns.range(of: "# Plan").upperBound)

        let text = view.string
        let fresh = editor(text, generated: generated, Commits()).1.textView
        XCTAssertTrue(layerSignature(fresh).contains { $0.hasPrefix("tint") })
        XCTAssertEqual(layerSignature(view), layerSignature(fresh))
    }

    /// Hover Revert puts one hunk back and commits at once — an explicit action, not typing
    /// to wait out — leaving the other edits in place.
    @MainActor
    func testRevertFromTheEditorCommitsAtOnce() {
        let generated = "# Plan\n\nalpha\nbeta\ngamma\n"
        let edited = "# Plan\n\nALPHA\nbeta\ngamma\ndelta\n"
        let commits = Commits()
        let (coordinator, container) = editor(edited, generated: generated, commits)
        XCTAssertEqual(coordinator.hunks.count, 2)
        container.revert.enabled = true
        container.revert.show(0)
        XCTAssertFalse(container.revert.button.isHidden)
        container.revert.button.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(container.textView.string, "# Plan\n\nalpha\nbeta\ngamma\ndelta\n")
        XCTAssertEqual(commits.all, ["# Plan\n\nalpha\nbeta\ngamma\ndelta\n"])
        XCTAssertEqual(coordinator.hunks.count, 1)
        coordinator.timer?.invalidate()
    }
}

/// UTF-16 ranges of the rendering-attribute runs carrying `key`, adjacent runs merged.
@MainActor
func renderingRuns(_ layout: NSTextLayoutManager, _ key: NSAttributedString.Key) -> [NSRange] {
    let content = layout.textContentManager!
    let start = content.documentRange.location
    var out: [NSRange] = []
    layout.enumerateRenderingAttributes(from: start, reverse: false) { _, attributes, range in
        guard attributes[key] != nil else { return true }
        let run = NSRange(location: content.offset(from: start, to: range.location),
                          length: content.offset(from: range.location, to: range.endLocation))
        // Adjacent runs draw as one; the layout manager splits a run where text was typed.
        if let last = out.last, NSMaxRange(last) == run.location { out[out.count - 1].length += run.length } else { out.append(run) }
        return true
    }
    return out
}

final class DecorationLayerTests: XCTestCase {
    /// Controller's rule: each layer clears only what it set. A refresh of the edit tint
    /// leaves a notes layer's underline — and a note layer's own background, were it to use
    /// one — where they were; and after text is typed before the tint (which moves it), the
    /// refresh still finds and clears the moved run instead of leaving it behind.
    @MainActor
    func testEachLayerClearsOnlyItsOwnRangesWhereverEditsMovedThem() {
        let view = NSTextView(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        view.string = "hello world\nsecond line\n"
        let layout = view.textLayoutManager!
        let edits = DecorationLayer(key: "edits"), notes = DecorationLayer(key: "notes")
        edits.apply([(NSRange(location: 6, length: 5), [.backgroundColor: NSColor.green])], to: layout)
        notes.apply([(NSRange(location: 0, length: 5), [.backgroundColor: NSColor.yellow]),
                     (NSRange(location: 6, length: 5), [.underlineStyle: NSUnderlineStyle.thick.rawValue])], to: layout)

        view.insertText("XXX", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(renderingRuns(layout, .backgroundColor), [NSRange(location: 3, length: 5), NSRange(location: 9, length: 5)],
                       "the layout manager moved both backgrounds with the text")
        edits.apply([(NSRange(location: 15, length: 6), [.backgroundColor: NSColor.green])], to: layout)

        XCTAssertEqual(renderingRuns(layout, .backgroundColor), [NSRange(location: 3, length: 5), NSRange(location: 15, length: 6)],
                       "the moved edit tint is gone, the note's background stays, the new tint is set")
        XCTAssertEqual(renderingRuns(layout, .underlineStyle), [NSRange(location: 9, length: 5)], "the note's underline is untouched")
        edits.apply([], to: layout)
        XCTAssertEqual(renderingRuns(layout, .backgroundColor), [NSRange(location: 3, length: 5)])
    }
}

/// Records what `git merge-file` would have been handed, and from which thread.
private final class MergeSpy: CommandRunner, @unchecked Sendable {
    struct Call { var arguments: [String]; var files: [String: String]; var onMain: Bool }
    let result: CommandResult
    private(set) var calls: [Call] = []
    init(result: CommandResult) { self.result = result }

    func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
             processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?) async throws -> CommandResult {
        var files: [String: String] = [:]
        for name in ["ours.md", "base.md", "theirs.md"] {
            files[name] = try? String(contentsOf: cwd.appendingPathComponent(name), encoding: .utf8)
        }
        calls.append(Call(arguments: arguments, files: files, onMain: Thread.isMainThread))
        return result
    }
}
