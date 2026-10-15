import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// A reading position in the plan's own text (`PlanReadingAnchor`): where it moves when text is
/// edited above it, and where it lands when a round replaces the plan. Pure.
final class PlanReadingAnchorTests: XCTestCase {
    private static func plan(_ sections: [Int], extra: String = "") -> String {
        sections.map { "## \($0). Section \($0)\n\nWords of section \($0), which are long enough to be told from the rest.\(extra)" }
            .joined(separator: "\n\n") + "\n"
    }

    private func anchor(_ text: String, at needle: String, within: CGFloat = 4) -> PlanReadingAnchor {
        let ns = text as NSString
        let headings = PlanOutline.headings(MarkdownStyler.blocks(text), in: ns)
        return .at(ns.range(of: needle).location, within: within, in: ns, headings: headings)
    }

    private func headings(_ text: String) -> [PlanHeading] {
        PlanOutline.headings(MarkdownStyler.blocks(text), in: text as NSString)
    }

    func testTheAnchorNamesTheParagraphAndTheSectionItIsIn() {
        let text = Self.plan(Array(0..<5))
        let a = anchor(text, at: "Words of section 3")
        XCTAssertEqual(a.paragraph, "Words of section 3, which are long enough to be told from the rest.")
        XCTAssertEqual(a.into, 0)
        XCTAssertEqual(a.occurrence, 0)
        XCTAssertEqual(a.section, PlanFoldKey(text: "## 3. Section 3", occurrence: 0))
        XCTAssertEqual(a.within, 4)
    }

    func testAnEditAboveMovesTheAnchorWithItsLineAndOneBelowLeavesItBe() {
        let text = Self.plan(Array(0..<5))
        let a = anchor(text, at: "Words of section 3")
        let above = TextEdit(range: NSRange(location: 3, length: 4), delta: 4)
        XCTAssertEqual(a.shifted(by: above).offset, a.offset + 4)
        let below = TextEdit(range: NSRange(location: a.offset + 20, length: 1), delta: 1)
        XCTAssertEqual(a.shifted(by: below).offset, a.offset)
        let removal = TextEdit(range: NSRange(location: 3, length: 0), delta: -6)
        XCTAssertEqual(a.shifted(by: removal).offset, a.offset - 6)
        // An edit across the line itself leaves the anchor at the edit, not past it.
        let across = TextEdit(range: NSRange(location: a.offset - 2, length: 10), delta: 2)
        XCTAssertEqual(a.shifted(by: across).offset, a.offset - 2)
    }

    func testTheSameParagraphWhereItWasIsUnchanged() {
        let text = Self.plan(Array(0..<5))
        let a = anchor(text, at: "Words of section 3")
        let found = a.relocated(in: text as NSString, headings: headings(text))
        XCTAssertEqual(found.match, .unchanged)
        XCTAssertEqual(found.anchor, a)
    }

    /// A round that put a section above, or reworded another one, leaves the paragraph where it
    /// is by its words, not by its offset.
    func testAParagraphMovedByAnEditAboveIsFoundByItsWords() {
        let old = Self.plan(Array(0..<5))
        let a = anchor(old, at: "Words of section 3", within: 7)
        let new = Self.plan([0, 1, 9, 2, 3, 4])
        let found = a.relocated(in: new as NSString, headings: headings(new))
        XCTAssertEqual(found.match, .paragraph)
        XCTAssertEqual(found.anchor.offset, (new as NSString).range(of: "Words of section 3").location)
        XCTAssertEqual(found.anchor.within, 7, "the line stays as far under the edge")
    }

    func testOneOfSeveralIdenticalParagraphsIsFoundAsThatOne() {
        let line = "- Run the full suite before and after, on both machines."
        let old = "## A\n\n\(line)\n\n## B\n\n\(line)\n\n## C\n\n\(line)\n"
        /// The `line` under heading `heading` of `text`.
        func under(_ heading: String, in text: String) -> Int {
            let ns = text as NSString
            let from = ns.range(of: heading).location
            return ns.range(of: line, options: [], range: NSRange(location: from, length: ns.length - from)).location
        }
        let a = PlanReadingAnchor.at(under("## B", in: old), within: 0, in: old as NSString, headings: headings(old))
        XCTAssertEqual(a.occurrence, 1)
        let new = "## Z\n\nNew.\n\n" + old
        let found = a.relocated(in: new as NSString, headings: headings(new))
        XCTAssertEqual(found.match, .paragraph)
        XCTAssertEqual(found.anchor.offset, under("## B", in: new))
    }

    func testAGoneParagraphFallsBackToItsSectionsHeading() {
        let old = Self.plan(Array(0..<5))
        let a = anchor(old, at: "Words of section 3", within: 7)
        let new = old.replacingOccurrences(of: "Words of section 3, which are long enough to be told from the rest.", with: "A different plan altogether.")
        let found = a.relocated(in: new as NSString, headings: headings(new))
        XCTAssertEqual(found.match, .section)
        XCTAssertEqual(found.anchor.offset, (new as NSString).range(of: "## 3. Section 3").location)
        XCTAssertEqual(found.anchor.within, 0, "the heading sits at the reading line")
    }

    func testWithTheSectionGoneTooItIsTheTopOfThePlan() {
        let old = Self.plan(Array(0..<5))
        let a = anchor(old, at: "Words of section 3", within: 7)
        let new = Self.plan([0, 1, 2, 4])
        let found = a.relocated(in: new as NSString, headings: headings(new))
        XCTAssertEqual(found.match, .top)
        XCTAssertEqual(found.anchor.offset, 0)
        XCTAssertEqual(found.anchor.within, 0)
    }
}

/// The reading position and caret across editors (`PlanScrollMemory`): an editor made again for
/// the same memory comes back to the line that was being read — through a new width, a fold above
/// it, a round that replaced the text — with the caret where it was. The page is an
/// `NSScrollView` holding the editor under a stand-in header, as `PlanEditorOneScrollTests`.
@MainActor
final class PlanReadingMemoryTests: XCTestCase {
    private final class Page: NSView { override var isFlipped: Bool { true } }

    private static let header: CGFloat = 300
    private static let obscured: CGFloat = 60

    private final class Rig {
        let window: NSWindow
        let outer: NSScrollView
        var page = Page(frame: .zero)
        var container: PlanEditorContainer!
        var coordinator: PlanTextView.Coordinator!
        var view: PlanNSTextView { container.textView }

        init(width: CGFloat = 900) {
            window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 700))
            outer.hasVerticalScroller = true
            window.contentView = outer
            window.orderFrontRegardless()
        }

        deinit { window.close() }

        /// What `PlanTextView.makeNSView` does, with SwiftUI's part (`fit`) done by hand.
        func mount(_ text: String, memory: PlanScrollMemory?, folds: PlanFoldStore? = nil, notes: PlanNotesController? = nil) {
            let editor = PlanTextView(text: .constant(text), editable: true, onCommit: { _ in }, incoming: nil, onShowIncoming: {})
            let coordinator = editor.makeCoordinator()
            let container = PlanEditorContainer(onShow: {})
            coordinator.textView = container.textView
            coordinator.revertButton = container.revert
            container.textView.delegate = coordinator
            container.textView.textStorage?.delegate = coordinator
            container.textView.onFocusChange = { [weak coordinator] in coordinator?.focusChanged() }
            container.textView.onContainerWidth = { [weak coordinator] in coordinator?.containerWidthChanged() }
            container.textView.onWindowChange = { [weak coordinator] entering in
                if entering { coordinator?.stepReadingRestore() } else { coordinator?.leavingReading() }
            }
            container.textView.obscuredTop = PlanReadingMemoryTests.obscured
            if let folds { coordinator.foldStore = folds }
            coordinator.readingMemory = memory
            if let notes { MainActor.assumeIsolated { coordinator.notesBridge.attach(notes, to: container.textView) } }
            coordinator.load(text)
            // The page is made again, at the top, as the project view's document is.
            let page = Page(frame: NSRect(x: 0, y: 0, width: outer.frame.width, height: 700))
            page.addSubview(container)
            self.page = page
            self.container = container
            self.coordinator = coordinator
            outer.documentView = page
            outer.contentView.scroll(to: .zero)
            fit()
        }

        func fit() {
            container.frame = NSRect(x: 20, y: PlanReadingMemoryTests.header, width: page.frame.width - 40, height: container.contentHeight)
            page.frame.size.height = PlanReadingMemoryTests.header + container.contentHeight + 40
            page.layoutSubtreeIfNeeded()
        }

        func scroll(to y: CGFloat) {
            let end = max(0, page.frame.height - outer.contentView.bounds.height)
            outer.contentView.scroll(to: NSPoint(x: 0, y: min(y, end)))
            outer.reflectScrolledClipView(outer.contentView)
        }

        var origin: CGFloat { outer.contentView.bounds.minY }

        /// Until the whole plan is laid out and any restore has landed, the page growing to the
        /// editor as SwiftUI would.
        func ready(timeout: TimeInterval = 20) {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                fit()
                settleMainRunLoop(0.02)
            } while (view.layingOutWholePlan || coordinator.scrolling.target != nil) && Date() < deadline
            fit()
            settleMainRunLoop(0.05)
        }

        /// Scrolls to `y`, lets the position be saved (the scroll is quiet), and returns what is read.
        func read(at y: CGFloat) throws -> PlanReadingAnchor {
            scroll(to: y)
            settleMainRunLoop(PlanTextView.Coordinator.readingQuiet + 0.3)
            return try XCTUnwrap(coordinator.readingAnchor())
        }
    }

    static func plan(_ sections: Range<Int> = 0..<120) -> String {
        sections.map { i in
            "## \(i). Section \(i)\n\n"
                + "Section \(i) has words enough to wrap at the width of the page once or twice over, and a few more besides so that it does. "
                + "Techs check in on arrival \(i).\n\n- item one of \(i)\n- item two of \(i)"
        }.joined(separator: "\n\n") + "\n"
    }

    private func lineHeight(_ rig: Rig) -> CGFloat { 22 }

    func testAnEditorMadeAgainComesBackToTheLineBeingRead() throws {
        let memory = PlanScrollMemory()
        let rig = Rig()
        rig.mount(Self.plan(), memory: memory)
        rig.ready()
        let before = try rig.read(at: 9_000)
        XCTAssertGreaterThan(before.offset, 1_000)
        XCTAssertEqual(memory.anchor?.offset, before.offset, "saved once the scroll was quiet")
        let scrolledTo = rig.origin

        rig.mount(Self.plan(), memory: memory)
        XCTAssertEqual(rig.origin, 0, "a new page starts at the top")
        rig.ready()
        let after = try XCTUnwrap(rig.coordinator.readingAnchor())
        XCTAssertEqual(after.offset, before.offset)
        XCTAssertEqual(after.within, before.within, accuracy: 1)
        XCTAssertEqual(rig.origin, scrolledTo, accuracy: lineHeight(rig))
        XCTAssertEqual(memory.anchor?.offset, before.offset, "the way back did not overwrite it")
    }

    func testTheSameLineAtAnotherWidth() throws {
        let memory = PlanScrollMemory()
        let wide = Rig(width: 1_100)
        wide.mount(Self.plan(), memory: memory)
        wide.ready()
        let before = try wide.read(at: 9_000)
        let scrolledTo = wide.origin

        let narrow = Rig(width: 640)
        narrow.mount(Self.plan(), memory: memory)
        narrow.ready()
        let after = try XCTUnwrap(narrow.coordinator.readingAnchor())
        XCTAssertEqual(after.offset - after.into, before.offset - before.into, "the same paragraph")
        XCTAssertEqual(after.within, before.within, accuracy: lineHeight(narrow))
        XCTAssertGreaterThan(abs(narrow.origin - scrolledTo), 500, "the pixels are not what was kept")
    }

    func testTheSameLineWithASectionFoldedAboveIt() throws {
        let memory = PlanScrollMemory()
        let folds = PlanFoldStore()
        let rig = Rig()
        rig.mount(Self.plan(), memory: memory, folds: folds)
        rig.ready()
        let before = try rig.read(at: 9_000)
        let scrolledTo = rig.origin
        let folded = (0..<8).map { PlanFoldKey(text: "## \($0). Section \($0)", occurrence: 0) }
        folded.forEach { folds.folds.set($0, folded: true) }

        rig.mount(Self.plan(), memory: memory, folds: folds)
        rig.ready()
        let after = try XCTUnwrap(rig.coordinator.readingAnchor())
        XCTAssertEqual(after.offset, before.offset)
        XCTAssertEqual(after.within, before.within, accuracy: 1)
        XCTAssertGreaterThan(abs(rig.origin - scrolledTo), 100, "the folds moved the line; the page followed it")
    }

    func testTheCaretAndTheKeyboardComeBack() throws {
        let memory = PlanScrollMemory()
        let rig = Rig()
        rig.mount(Self.plan(), memory: memory)
        rig.ready()
        _ = try rig.read(at: 6_000)
        XCTAssertTrue(rig.window.makeFirstResponder(rig.view))
        let selection = NSRange(location: (try XCTUnwrap(rig.coordinator.readingAnchor())).offset + 300, length: 5)
        rig.view.setSelectedRange(selection)
        // Revealing the selection may have moved the page: the position is the one it ended at.
        settleMainRunLoop(PlanTextView.Coordinator.readingQuiet + 0.3)
        let before = try XCTUnwrap(rig.coordinator.readingAnchor())

        rig.mount(Self.plan(), memory: memory)
        rig.ready()
        XCTAssertTrue(rig.window.firstResponder === rig.view, "the editor had the keyboard")
        XCTAssertEqual(rig.view.selectedRange(), selection)
        let after = try XCTUnwrap(rig.coordinator.readingAnchor())
        XCTAssertEqual(after.offset, before.offset)
        XCTAssertEqual(after.within, before.within, accuracy: 1)
    }

    func testAnEditorThatHadNoKeyboardComesBackWithoutIt() throws {
        let memory = PlanScrollMemory()
        let rig = Rig()
        rig.mount(Self.plan(), memory: memory)
        rig.ready()
        _ = try rig.read(at: 6_000)
        rig.mount(Self.plan(), memory: memory)
        rig.ready()
        XCTAssertFalse(rig.window.firstResponder === rig.view)
    }

    func testEditsAboveMoveTheSavedPositionWithItsLine() throws {
        let memory = PlanScrollMemory()
        let rig = Rig()
        rig.mount(Self.plan(), memory: memory)
        rig.ready()
        let before = try rig.read(at: 6_000)
        rig.view.insertText("abcd", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(memory.anchor?.offset, before.offset + 4, "shifted at once, before the layout is read again")
    }

    /// A scroll costs a timestamp: the layout is read once, after it has been still.
    func testTheLayoutIsReadWhenTheScrollIsQuietNotOnEveryTick() throws {
        let memory = PlanScrollMemory()
        let rig = Rig()
        rig.mount(Self.plan(), memory: memory)
        rig.ready()
        let first = try rig.read(at: 3_000)
        for y in stride(from: 3_000.0, to: 9_000.0, by: 100) { rig.scroll(to: y) }
        XCTAssertEqual(memory.anchor, first, "no read while the scrolling goes on")
        settleMainRunLoop(PlanTextView.Coordinator.readingQuiet + 0.3)
        XCTAssertNotEqual(memory.anchor?.offset, first.offset)
        XCTAssertEqual(memory.anchor?.offset, rig.coordinator.readingAnchor()?.offset)
    }

    // MARK: A round replaces the text

    func testAReplacedTextKeepsTheLineWhenItsParagraphIsStillThere() throws {
        let rig = Rig()
        let memory = PlanScrollMemory()
        rig.mount(Self.plan(), memory: memory)
        rig.ready()
        let before = try rig.read(at: 9_000)
        let paragraph = before.paragraph

        // Two sections added at the top: everything below moves down.
        rig.coordinator.load("## New A\n\nSomething new.\n\n## New B\n\nAnd more.\n\n" + Self.plan())
        rig.ready()
        let after = try XCTUnwrap(rig.coordinator.readingAnchor())
        XCTAssertEqual(after.paragraph, paragraph)
        XCTAssertEqual(after.within, before.within, accuracy: 1)
    }

    func testAReplacedTextFallsBackToTheSectionWhenTheParagraphIsGone() throws {
        let rig = Rig()
        let memory = PlanScrollMemory()
        rig.mount(Self.plan(), memory: memory)
        rig.ready()
        let before = try rig.read(at: 9_000)
        let section = try XCTUnwrap(before.section)

        // Every paragraph rewritten, the headings kept.
        let rewritten = Self.plan().replacingOccurrences(of: "Techs check in on arrival", with: "Crews report on arrival")
            .replacingOccurrences(of: "has words enough", with: "has other words enough")
            .replacingOccurrences(of: "- item", with: "- point")
        rig.coordinator.load(rewritten)
        rig.ready()
        let heading = (rig.view.string as NSString).range(of: section.text).location
        let top = try XCTUnwrap(rig.coordinator.lineTop(at: heading))
        XCTAssertEqual(top - (try XCTUnwrap(rig.coordinator.viewportTop)), Self.obscured, accuracy: 1,
                       "the heading of the section it was in is just under the pinned block, not behind it")
    }

    func testAReplacedTextFallsBackToTheTopWhenTheSectionIsGone() throws {
        let rig = Rig()
        let memory = PlanScrollMemory()
        rig.mount(Self.plan(), memory: memory)
        rig.ready()
        _ = try rig.read(at: 9_000)
        rig.coordinator.load("# A different plan\n\n" + Self.plan(200..<260))
        rig.ready()
        let after = try XCTUnwrap(rig.coordinator.readingAnchor())
        XCTAssertEqual(after.offset, 0)
        XCTAssertEqual(after.within, -Self.obscured, accuracy: 1, "the plan's first line just under the pinned block")
    }

    /// "Show in that version": the editor loads the version the note was written on and the page
    /// goes to the note's quote, just under the pinned block, not to where it was reading.
    func testShowInThatVersionTakesThePageToTheQuote() throws {
        let rig = Rig()
        let notes = PlanNotesController()
        notes.checkpoint = 2
        let memory = PlanScrollMemory()
        rig.mount("# The plan that replaced it\n\nNothing alike.\n", memory: memory, notes: notes)
        rig.ready()

        let version = Self.plan()
        let quote = "Techs check in on arrival 90."
        let anchor = NoteAnchor(checkpoint: 1, selecting: version.range(of: quote)!, in: version)
        notes.tapeNotes = [TapeNote(note: PlanNote(note: "n", anchor: anchor), consumedBy: 2)]
        notes.pendingReveal = PlanNotesController.Reveal(checkpoint: 1, anchor: anchor)
        rig.coordinator.load(version)
        rig.ready()

        XCTAssertNil(notes.pendingReveal, "used on the load")
        let offset = (rig.view.string as NSString).range(of: quote).location
        let top = try XCTUnwrap(rig.coordinator.lineTop(at: offset))
        let page = try XCTUnwrap(rig.coordinator.viewportTop)
        XCTAssertGreaterThan(rig.origin, 1_000, "the page left the top of the plan")
        XCTAssertGreaterThanOrEqual(top - page, Self.obscured, "below the pinned block, not behind it")
        XCTAssertLessThan(top - page, Self.obscured + 200, "and near the top of the page")
        XCTAssertNil(rig.coordinator.scrolling.flash, "flashed when it landed")
    }

    /// The version is already on screen: the same arrival, without a load.
    func testShowInThatVersionOnTheVersionShownScrollsThere() throws {
        let rig = Rig()
        let notes = PlanNotesController()
        notes.checkpoint = 1
        let version = Self.plan()
        let memory = PlanScrollMemory()
        rig.mount(version, memory: memory, notes: notes)
        rig.ready()
        XCTAssertEqual(rig.origin, 0)
        let quote = "Techs check in on arrival 110."
        let anchor = NoteAnchor(checkpoint: 1, selecting: version.range(of: quote)!, in: version)
        notes.tapeNotes = [TapeNote(note: PlanNote(note: "n", anchor: anchor), consumedBy: 2)]
        notes.showInVersion(notes.tapeNotes[0].id)
        rig.ready()
        let top = try XCTUnwrap(rig.coordinator.lineTop(at: (rig.view.string as NSString).range(of: quote).location))
        XCTAssertGreaterThan(rig.origin, 1_000)
        XCTAssertGreaterThanOrEqual(top - (try XCTUnwrap(rig.coordinator.viewportTop)), Self.obscured)
    }

    /// The maintainer's bug: notes written on the drafts lose their place after the editor shows another
    /// version, and do not come back when it shows the drafts again. A text swap left every note
    /// "detached" for good: the search for a detached note's quote began before the start of the
    /// text and so looked nowhere.
    func testNotesFindTheirQuotesAgainWhenTheirVersionIsShownAgain() throws {
        let rig = Rig()
        let notes = PlanNotesController()
        notes.checkpoint = 1
        let drafts = Self.plan(), synthesis = "# The plan that replaced it\n\nNothing alike.\n"
        rig.mount(drafts, memory: PlanScrollMemory(), notes: notes)
        let quotes = ["Techs check in on arrival 3.", "Techs check in on arrival 60.", "Techs check in on arrival 110."]
        notes.tapeNotes = quotes.map { q in
            TapeNote(note: PlanNote(note: "n", anchor: NoteAnchor(checkpoint: 1, selecting: drafts.range(of: q)!, in: drafts)), consumedBy: 2)
        }
        rig.ready()
        func found() -> Int { settleMainRunLoop(0.1); return notes.located.count }
        XCTAssertEqual(found(), 3, "on their own version")
        rig.coordinator.load(synthesis)
        notes.checkpoint = 2
        rig.ready()
        XCTAssertEqual(found(), 0, "the rewritten plan holds none of them")
        rig.coordinator.load(drafts)
        notes.checkpoint = 1
        rig.ready()
        XCTAssertEqual(found(), 3, "back on their own version every note is beside its quote again")
    }
}
