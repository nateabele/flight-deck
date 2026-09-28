import AppKit
import XCTest
@testable import FlightDeck

/// Folding a section in the real editor: a view state over the plan that never touches the
/// stored text, hides the body from layout, and opens again wherever the caret lands in it.
@MainActor
final class PlanFoldingTests: XCTestCase {
    static let plan = """
    # Plan

    Intro paragraph.

    ## 1. Overview

    The overview's first paragraph, long enough to wrap onto a second line in a narrow window, and then some more words.

    ### 1.1 Detail

    Deep detail.

    ```sh
    # a comment in a fence, not a heading
    echo hi
    ```

    ## 2. Rules

    - rule one
    - rule two

    ## 3. Rollout

    Ship it.
    """

    private struct Fixture {
        let coordinator: PlanTextView.Coordinator
        let container: PlanEditorContainer
        let window: NSWindow
        var view: PlanNSTextView { container.textView }

        func settle() {
            let until = Date().addingTimeInterval(3)
            repeat { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) } while view.layingOutWholePlan && Date() < until
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
        }

        /// Where a character's line starts, laid out.
        func top(of text: String) -> CGFloat? {
            view.caretRect(at: (view.string as NSString).range(of: text).location)?.minY
        }

        func key(_ line: String) -> PlanFoldKey { coordinator.headings.first { $0.key.text == line }!.key }
    }

    private func editor(_ text: String = plan, store: PlanFoldStore? = nil) -> Fixture {
        let view = PlanTextView(text: .constant(text), editable: true, onCommit: { _ in }, incoming: nil, onShowIncoming: {}).folds(store)
        let coordinator = view.makeCoordinator()
        if let store { coordinator.foldStore = store }
        let container = PlanEditorContainer(onShow: {})
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 700, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        container.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        coordinator.textView = container.textView
        container.textView.delegate = coordinator
        container.textView.textStorage?.delegate = coordinator
        coordinator.load(text)
        container.layoutSubtreeIfNeeded()
        let f = Fixture(coordinator: coordinator, container: container, window: window)
        f.settle()
        return f
    }

    func testFoldingHidesTheBodyAndNeverTouchesTheText() throws {
        let f = editor()
        defer { f.window.close() }
        let before = f.view.string
        let height = f.view.frame.height
        let rulesTop = try XCTUnwrap(f.top(of: "## 2. Rules"))
        let overviewTop = try XCTUnwrap(f.top(of: "## 1. Overview"))

        f.coordinator.toggleFold(f.key("## 1. Overview"))
        f.settle()
        XCTAssertEqual(f.view.string, before, "folding is a view state: the stored plan is byte-identical")
        XCTAssertEqual(f.view.textStorage?.string, before)
        XCTAssertEqual(f.coordinator.foldFilter.hidden.map { (before as NSString).substring(with: $0) },
                       ["\nThe overview's first paragraph, long enough to wrap onto a second line in a narrow window, and then some more words.\n\n### 1.1 Detail\n\nDeep detail.\n\n```sh\n# a comment in a fence, not a heading\necho hi\n```\n\n"])
        let folded = try XCTUnwrap(f.top(of: "## 2. Rules"))
        XCTAssertLessThan(folded, rulesTop - 100, "the next section moved up into the folded body's room")
        XCTAssertGreaterThan(folded, overviewTop, "…and still sits under its heading")
        XCTAssertLessThan(f.view.frame.height, height - 100, "the page is shorter by the body")

        f.coordinator.toggleFold(f.key("## 1. Overview"))
        f.settle()
        XCTAssertEqual(try XCTUnwrap(f.top(of: "## 2. Rules")), rulesTop, accuracy: 0.5, "opened: back where it was")
        XCTAssertEqual(f.view.frame.height, height, accuracy: 0.5)
        XCTAssertEqual(f.view.string, before)
    }

    func testTheCaretLandingInAFoldedSectionOpensIt() {
        let f = editor()
        defer { f.window.close() }
        f.coordinator.toggleFold(f.key("## 2. Rules"))
        XCTAssertFalse(f.coordinator.foldFilter.hidden.isEmpty)
        // A Find match, a click-through from elsewhere, an arrow key: all a selection change.
        f.view.setSelectedRange(NSRange(location: (f.view.string as NSString).range(of: "rule two").location, length: 3))
        XCTAssertTrue(f.coordinator.foldFilter.hidden.isEmpty, "the section holding the selection opened")
        XCTAssertFalse(f.coordinator.foldStore.folds.isFolded(f.key("## 2. Rules")))
    }

    func testFoldingTheCaretSectionMovesTheCaretToItsHeading() {
        let f = editor()
        defer { f.window.close() }
        let ns = f.view.string as NSString
        f.view.setSelectedRange(NSRange(location: ns.range(of: "Deep detail").location + 2, length: 0))
        XCTAssertTrue(f.coordinator.foldCaretSection(true), "⌥⌘←")
        XCTAssertTrue(f.coordinator.foldStore.folds.isFolded(f.key("### 1.1 Detail")), "the innermost section folds")
        XCTAssertEqual(f.view.selectedRange().location, NSMaxRange(ns.range(of: "### 1.1 Detail")), "caret parked on the heading")
        XCTAssertFalse(f.coordinator.foldFilter.hidden.isEmpty, "…so the fold stays shut")
        XCTAssertTrue(f.coordinator.foldCaretSection(true), "again: the parent folds")
        XCTAssertTrue(f.coordinator.foldStore.folds.isFolded(f.key("## 1. Overview")))
        f.view.setSelectedRange(NSRange(location: NSMaxRange(ns.range(of: "## 1. Overview")), length: 0))
        XCTAssertTrue(f.coordinator.foldCaretSection(false), "⌥⌘→ on the folded heading opens it")
        XCTAssertFalse(f.coordinator.foldStore.folds.isFolded(f.key("## 1. Overview")))
    }

    func testTheChordReachesTheEditorOnlyWhileFocused() throws {
        let f = editor()
        defer { f.window.close() }
        f.window.makeFirstResponder(f.view)
        f.view.setSelectedRange(NSRange(location: (f.view.string as NSString).range(of: "Ship it").location, length: 0))
        let left = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                                                  windowNumber: f.window.windowNumber, context: nil,
                                                  characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
                                                  charactersIgnoringModifiers: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
                                                  isARepeat: false, keyCode: 123))
        XCTAssertTrue(f.view.performKeyEquivalent(with: left))
        XCTAssertTrue(f.coordinator.foldStore.folds.isFolded(f.key("## 3. Rollout")))
        f.window.makeFirstResponder(nil)
        XCTAssertFalse(f.view.performKeyEquivalent(with: left), "unfocused, the chord is not the editor's")
    }

    func testEditingKeepsFoldsOnTheirHeadings() {
        let f = editor()
        defer { f.window.close() }
        f.coordinator.toggleFold(f.key("## 3. Rollout"))
        let ns = f.view.string as NSString
        // Typing above the fold moves it; retyping the folded heading keeps it folded.
        f.view.setSelectedRange(NSRange(location: ns.range(of: "Intro").location, length: 0))
        f.view.insertText("An ", replacementRange: f.view.selectedRange())
        f.view.setSelectedRange(NSRange(location: NSMaxRange((f.view.string as NSString).range(of: "## 3. Rollout")), length: 0))
        f.view.insertText(" plan", replacementRange: f.view.selectedRange())
        XCTAssertTrue(f.coordinator.foldStore.folds.isFolded(f.key("## 3. Rollout plan")))
        XCTAssertEqual(f.coordinator.foldFilter.hidden.map { (f.view.string as NSString).substring(with: $0) }, ["\nShip it."])
    }

    func testFoldsLiveInTheStoreAcrossEditorsAndRounds() {
        let store = PlanFoldStore()
        let first = editor(store: store)
        first.coordinator.toggleFold(first.key("## 2. Rules"))
        first.coordinator.toggleFold(first.key("## 3. Rollout"))
        first.window.close()

        // Another intake and back: a fresh editor on the same store.
        let again = editor(store: store)
        XCTAssertEqual(again.coordinator.foldFilter.hidden.count, 2, "folds outlived the editor")

        // A new round renames §3 away and rewrites §2's body.
        let next = Self.plan.replacingOccurrences(of: "- rule two", with: "- rule two, sharper")
            .replacingOccurrences(of: "## 3. Rollout", with: "## 3. Launch")
        again.coordinator.load(next)
        XCTAssertEqual(store.folds.folded, [PlanFoldKey(text: "## 2. Rules", occurrence: 0)], "a vanished heading's fold is dropped")
        XCTAssertEqual(again.coordinator.foldFilter.hidden.map { (next as NSString).substring(with: $0) }, ["\n- rule one\n- rule two, sharper\n\n"])
        again.window.close()
    }

    func testANoteInAFoldedSectionSitsAtItsHeading() {
        let f = editor()
        defer { f.window.close() }
        let ns = f.view.string as NSString
        let quote = ns.range(of: "rule two")
        XCTAssertEqual(f.coordinator.visibleProxy(quote), quote)
        f.coordinator.toggleFold(f.key("## 2. Rules"))
        XCTAssertEqual(f.coordinator.visibleProxy(quote), ns.range(of: "## 2. Rules"))
    }

    func testAChevronClickFoldsAndThePillOpens() throws {
        let f = editor()
        defer { f.window.close() }
        f.view.displayIfNeeded()
        f.coordinator.foldGutter.display()
        // Hovering a heading line shows its chevron; clicking it folds.
        let top = try XCTUnwrap(f.view.caretRect(at: (f.view.string as NSString).range(of: "## 2. Rules").location + 4))
        f.coordinator.hoverFold(at: NSPoint(x: 200, y: top.midY))
        XCTAssertEqual(f.coordinator.foldGutter.hovered, f.key("## 2. Rules"))
        let chevron = NSPoint(x: f.coordinator.foldGutter.chevronX, y: top.midY)
        XCTAssertTrue(f.view.onFoldClick?(chevron) == true)
        XCTAssertTrue(f.coordinator.foldStore.folds.isFolded(f.key("## 2. Rules")))
        f.settle()
        f.coordinator.foldGutter.display()
        let mark = try XCTUnwrap(f.coordinator.foldGutter.marks.first { $0.folded })
        XCTAssertEqual(mark.lines, 2, "the pill counts the two hidden items")
        XCTAssertTrue(f.view.onFoldClick?(NSPoint(x: f.coordinator.foldGutter.pillRect(mark).midX, y: mark.line.midY)) == true)
        XCTAssertFalse(f.coordinator.foldStore.folds.isFolded(f.key("## 2. Rules")))
        XCTAssertFalse(f.view.onFoldClick?(NSPoint(x: 300, y: 5)) == true, "a click in the text is the text's")
    }
}

/// The breadcrumb names the section whose heading has scrolled under the pinned block, shows
/// nothing while that heading is on screen, and a click brings the heading back.
@MainActor
final class PlanReadingPositionTests: XCTestCase {
    func testBreadcrumbNamesTheSectionScrolledUnderThePinnedBlock() throws {
        let text = (1...12).map { "## \($0). Section \($0)\n\n" + String(repeating: "Words in section \($0) that fill a paragraph. ", count: 12) }
            .joined(separator: "\n\n")
        let view = PlanTextView(text: .constant(text), editable: true, onCommit: { _ in }, incoming: nil, onShowIncoming: {})
        let coordinator = view.makeCoordinator()
        let container = PlanEditorContainer(onShow: {})
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 700, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        scroll.documentView = container
        window.contentView = scroll
        coordinator.textView = container.textView
        container.textView.delegate = coordinator
        coordinator.load(text)
        container.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        container.layoutSubtreeIfNeeded()
        let until = Date().addingTimeInterval(3)
        repeat { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) } while container.textView.layingOutWholePlan && Date() < until
        // What SwiftUI does with the height the editor reports.
        container.frame = NSRect(x: 0, y: 0, width: 700, height: container.contentHeight)
        container.layoutSubtreeIfNeeded()
        let reading = PlanReadingPosition()
        coordinator.reading = reading
        XCTAssertNil(coordinator.readingHeading(), "at the top, §1's heading is on screen")
        container.textView.obscuredTop = 100

        let ns = text as NSString
        let heading5 = try XCTUnwrap(container.textView.caretRect(at: ns.range(of: "## 5. Section 5").location))
        // Scroll so the reading line (100 pt down) sits a little into §5, its heading under the block.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: heading5.minY - 100 + 60))
        XCTAssertEqual(coordinator.readingHeading()?.heading.title, "5. Section 5")
        coordinator.readingMoved()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(reading.section, "5. Section 5", "published for the pinned board")
        reading.jump()
        XCTAssertNil(coordinator.readingHeading(), "clicked: the heading is back on screen, under the block")
        let visible = container.textView.convert(scroll.contentView.bounds, from: scroll.contentView)
        XCTAssertEqual(heading5.minY - visible.minY, 112, accuracy: 3, "just under the 100 pt block")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(reading.section)
    }
}
