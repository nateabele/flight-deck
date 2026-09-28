import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// The plan as part of the page: the editor has no scroller of its own, grows to its text, and
/// the pane's one scroll view scrolls it — text below the fold lays out when the page brings it
/// into view, the caret stays on screen while typing, and nothing lays the whole plan out.
///
/// The page here is an `NSScrollView` whose document holds the editor below a stand-in header,
/// the shape the detail pane's SwiftUI `ScrollView` gives it; `fit()` does what SwiftUI does
/// with the editor's reported height.
final class PlanEditorOneScrollTests: XCTestCase {
    private final class Page: NSView {
        override var isFlipped: Bool { true }
    }

    private struct Fixture {
        let coordinator: PlanTextView.Coordinator
        let container: PlanEditorContainer
        let outer: NSScrollView
        let page: NSView
        let window: NSWindow

        /// SwiftUI's half: the editor gets the height it asks for, and the page grows to hold it.
        @MainActor
        func fit() {
            container.frame = NSRect(x: 20, y: PlanEditorOneScrollTests.header, width: 860, height: container.contentHeight)
            page.frame.size.height = PlanEditorOneScrollTests.header + container.contentHeight + 40
            page.layoutSubtreeIfNeeded()
        }

        @MainActor
        func scrollPage(to y: CGFloat) {
            let end = max(0, page.frame.height - outer.contentView.bounds.height)
            outer.contentView.scroll(to: NSPoint(x: 0, y: min(y, end)))
            outer.reflectScrolledClipView(outer.contentView)
        }

        /// The document range TextKit 2 has laid out for the viewport, as UTF-16 offsets.
        @MainActor
        var viewport: NSRange? {
            guard let layout = container.textView.textLayoutManager, let content = layout.textContentManager,
                  let range = layout.textViewportLayoutController.viewportRange else { return nil }
            let start = content.offset(from: content.documentRange.location, to: range.location)
            return NSRange(location: start, length: content.offset(from: range.location, to: range.endLocation))
        }

        /// A character's rect in the page's coordinates (where the page's visible rect is).
        @MainActor
        func rectInPage(_ location: Int) -> NSRect {
            let view = container.textView
            return page.convert(view.caretRect(at: location) ?? .null, from: view)
        }
    }

    static let header: CGFloat = 400

    @MainActor
    private func editor(_ text: String) -> Fixture {
        let view = PlanTextView(text: .constant(text), editable: true, onCommit: { _ in }, incoming: nil, onShowIncoming: {})
        let coordinator = view.makeCoordinator()
        let container = PlanEditorContainer(onShow: {})
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        outer.hasVerticalScroller = true
        let page = Page(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        outer.documentView = page
        page.addSubview(container)
        window.contentView = outer
        coordinator.textView = container.textView
        coordinator.revertButton = container.revert
        container.textView.delegate = coordinator
        container.textView.textStorage?.delegate = coordinator
        coordinator.load(text)
        let fixture = Fixture(coordinator: coordinator, container: container, outer: outer, page: page, window: window)
        fixture.fit()
        window.orderFrontRegardless()
        drain()
        fixture.fit()
        container.textView.displayIfNeeded()
        return fixture
    }

    private func drain(_ seconds: TimeInterval = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// The text view scrolls in the page's clip view, not one of its own: a wheel over the plan
    /// scrolls the page.
    @MainActor
    func testTheEditorHasNoScrollViewOfItsOwn() {
        let f = editor(PlanEditorKeystrokeTests.plan())
        defer { f.coordinator.timer?.invalidate(); f.window.close() }
        XCTAssertTrue(f.container.textView.enclosingScrollView === f.outer, "the page's scroll view is the text's")
        XCTAssertFalse(Self.all(f.container).contains { $0 is NSScrollView }, "no scroll view inside the editor")
    }

    /// A long plan is as tall as its text (TextKit 2's estimate, no full layout); a short one
    /// keeps the minimum, so there is room to type.
    @MainActor
    func testTheEditorIsAsTallAsItsText() {
        let long = editor(PlanEditorKeystrokeTests.plan())
        defer { long.coordinator.timer?.invalidate(); long.window.close() }
        // 2,000 lines, a quarter of them blank, at ≥ 10 pt a line.
        XCTAssertGreaterThan(long.container.contentHeight, 2_000 * 10)
        XCTAssertEqual(long.container.intrinsicContentSize.height, long.container.contentHeight)
        XCTAssertEqual(long.container.textView.frame.height, long.container.contentHeight, accuracy: 0.5)

        let short = editor("# Plan\n\nOne line.")
        defer { short.coordinator.timer?.invalidate(); short.window.close() }
        XCTAssertEqual(short.container.contentHeight, PlanEditorContainer.minimumTextHeight)
    }

    /// TextKit 2 lays out only what the page shows: the viewport stops well short of the end at
    /// the top, and once the page scrolls to the bottom the plan's last lines are laid out there.
    /// Before the editor followed the page's clip view, text scrolled into view stayed blank.
    @MainActor
    func testScrollingThePageLaysOutTheTextItBringsIntoView() throws {
        let f = editor(PlanEditorKeystrokeTests.plan())
        defer { f.coordinator.timer?.invalidate(); f.window.close() }
        let length = (f.container.textView.string as NSString).length
        let top = try XCTUnwrap(f.viewport)
        XCTAssertLessThan(NSMaxRange(top), length / 4, "at the top only the top is laid out: \(top) of \(length)")

        waitForWholeLayout(f)
        f.fit()
        f.scrollPage(to: .infinity)
        drain()
        let bottom = try XCTUnwrap(f.viewport)
        XCTAssertEqual(NSMaxRange(bottom), length, "the plan's end is laid out once the page shows it: \(bottom)")
        XCTAssertGreaterThan(bottom.location, length / 2, "and not the whole plan: \(bottom)")
        let last = f.rectInPage(length - 1)
        XCTAssertTrue(f.outer.contentView.documentVisibleRect.intersects(last),
                      "the last line is where the page shows: \(last) in \(f.outer.contentView.documentVisibleRect)")
    }

    /// After a load the whole plan is laid out once, off the keystroke path, so its height is
    /// exact: one scroll to the bottom reaches the plan's last line, and scrolling there again
    /// moves nothing. On TextKit 2's estimate alone the page's end ran short and moved down as
    /// the plan was read — six scrolls to the bottom in the offscreen render.
    @MainActor
    func testOneScrollToTheBottomReachesThePlansEndAndItStaysPut() throws {
        // The pass's cost, measured once in a single slice, then as it runs: in slices.
        let slice = PlanNSTextView.fullLayoutSlice
        PlanNSTextView.fullLayoutSlice = .seconds(10)
        let whole = editor(PlanEditorKeystrokeTests.plan())
        waitForWholeLayout(whole)
        print("PlanEditor whole-plan layout, one slice: \(whole.container.textView.lastFullLayout.map { "\($0.time)" } ?? "none")")
        whole.coordinator.timer?.invalidate()
        whole.window.close()
        PlanNSTextView.fullLayoutSlice = slice

        let f = editor(PlanEditorKeystrokeTests.plan())
        defer { f.coordinator.timer?.invalidate(); f.window.close() }
        waitForWholeLayout(f)
        let pass = try XCTUnwrap(f.container.textView.lastFullLayout, "the pass ran")
        print("PlanEditor whole-plan layout, sliced: \(pass.time) over \(pass.slices) slices of ≤ \(slice)")
        f.fit()
        let length = (f.container.textView.string as NSString).length
        f.scrollPage(to: .infinity)
        drain()
        let last = f.rectInPage(length - 1)
        XCTAssertTrue(f.outer.contentView.documentVisibleRect.intersects(last),
                      "one scroll reaches the last line: \(last) in \(f.outer.contentView.documentVisibleRect)")
        let height = f.page.frame.height
        for _ in 0..<3 {
            f.fit()
            f.scrollPage(to: .infinity)
            drain()
        }
        f.fit()
        XCTAssertEqual(f.page.frame.height, height, accuracy: 0.5, "the page's end stayed put")
    }

    /// Runs the runloop until the whole-plan pass is done (bounded).
    @MainActor
    private func waitForWholeLayout(_ f: Fixture) {
        let deadline = Date().addingTimeInterval(5)
        while f.container.textView.layingOutWholePlan, Date() < deadline { drain(0.01) }
        drain()
        XCTAssertFalse(f.container.textView.layingOutWholePlan, "the pass finished")
    }

    /// Typing new lines at the end of a plan that runs past the window keeps the caret on the
    /// page's screen: the reveal reaches the page's scroll view, including after the page has
    /// grown to fit what the keystroke added — four lines at a time (a paste), more than the
    /// page's margin below the plan, so the keystroke's own reveal can't reach them.
    @MainActor
    func testTypingAtTheEndKeepsTheCaretOnScreen() {
        let f = editor(PlanEditorKeystrokeTests.plan())
        defer { f.coordinator.timer?.invalidate(); f.window.close() }
        let view = f.container.textView
        f.window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        for _ in 0..<5 {
            view.insertText("\nmore\nmore\nmore\nmore", replacementRange: view.selectedRange())
            drain()
            f.fit()
            drain()
        }
        // SwiftUI keeps handing the editor the height it reports; the whole-plan pass, restarted
        // by each keystroke, may still grow it after the last one, and that growth must reveal too.
        for _ in 0..<3 where abs(f.page.frame.height - (PlanEditorOneScrollTests.header + f.container.contentHeight + 40)) >= 0.5 {
            f.fit()
            drain()
        }
        let caret = f.rectInPage(view.selectedRange().location)
        let visible = f.outer.contentView.documentVisibleRect
        XCTAssertTrue(visible.contains(NSPoint(x: caret.midX, y: caret.maxY - 1)), "caret \(caret) off screen \(visible)")
    }

    /// Something drawn over the page's top edge (the pinned control bar and board) hides what is
    /// under it, so the caret is revealed below it, not merely inside the clip view.
    @MainActor
    func testTheCaretIsRevealedBelowWhatCoversThePageTop() {
        let f = editor(PlanEditorKeystrokeTests.plan())
        defer { f.coordinator.timer?.invalidate(); f.window.close() }
        let view = f.container.textView
        view.obscuredTop = 300
        f.window.makeFirstResponder(view)
        let at = (view.string as NSString).range(of: "Techs check in on arrival 60.").location
        // The caret's line just inside the clip's top edge: visible to AppKit, under the block.
        let line = f.rectInPage(at)
        f.scrollPage(to: line.minY - 20)
        drain()
        view.setSelectedRange(NSRange(location: at, length: 0))
        view.insertText("x", replacementRange: view.selectedRange())
        drain()
        let caret = f.rectInPage(at)
        let visible = f.outer.contentView.documentVisibleRect
        XCTAssertGreaterThanOrEqual(caret.minY, visible.minY + 300 - 0.5, "caret \(caret) under the covered top of \(visible)")
    }

    /// A burst of edits in one runloop turn hands SwiftUI its new height once, not once per
    /// edit — each hand-over relays out the whole pane.
    @MainActor
    func testHeightChangesReachSwiftUIOnceATurn() {
        let f = editor("# Plan\n\n" + String(repeating: "A line of the plan.\n", count: 40))
        defer { f.coordinator.timer?.invalidate(); f.window.close() }
        let view = f.container.textView
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        let before = f.container.heightPublishes
        for _ in 0..<20 { view.insertText("\nanother", replacementRange: view.selectedRange()) }
        XCTAssertEqual(f.container.heightPublishes, before, "nothing handed over mid-burst")
        drain()
        // The burst's growths arrive together; a later turn may hand over once more, as the
        // display pass firms up TextKit 2's estimate.
        let handovers = f.container.heightPublishes - before
        XCTAssertTrue((1...2).contains(handovers), "\(handovers) hand-overs for 20 edits")
        XCTAssertEqual(f.container.publishedHeight, f.container.contentHeight, "and SwiftUI ends on the text's height")
    }

    /// A heatmap cell's jump (`PlanSection.focus`) scrolls the PAGE to that section's hunk in
    /// Diff vs Previous, landing it `pageObscuredTop` below the page's top — under the pinned
    /// block, not behind it. With the diff in a scroll view of its own, the page never moved.
    @MainActor
    func testAHeatmapJumpScrollsThePageToTheSectionsHunk() throws {
        let sections = (1...40).map { "## \($0). Section \($0)\n\nBody of section \($0).\nMore of section \($0).\n" }
        let old = sections.joined(separator: "\n")
        let new = old.replacingOccurrences(of: "Body of section 5.", with: "Body of section 5, rewritten.")
            .replacingOccurrences(of: "Body of section 35.", with: "Body of section 35, rewritten.")
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let tape = Tape(checkpoints: [Checkpoint(id: 1, stage: .synthesis, round: 0, major: true, createdAt: date),
                                      Checkpoint(id: 2, parent: 1, stage: .refine, round: 1, major: false, createdAt: date)],
                        target: .none, status: .paused)
        let load: (Int, String) -> Data? = { id, file in file == "plan.md" ? Data((id == 1 ? old : new).utf8) : nil }
        let above: CGFloat = 3_000, covered: CGFloat = 200
        func page(_ focus: PlanFocus) -> some View {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: above)
                        PlanSection(intakeID: UUID(uuid: UUID_NULL), tape: tape, loadFile: load, onSend: { _ in }).focus(focus)
                        // Room below, so the page's end doesn't clamp where a jump can land.
                        Color.clear.frame(height: above)
                    }
                    .environment(\.pageJump, PageJump { proxy.scrollTo($0, anchor: PageJump.anchor(below: $1, height: 700)) })
                    .environment(\.pageObscuredTop, covered)
                }
            }
            .frame(width: 900, height: 700)
        }
        let host = NSHostingView(rootView: AnyView(page(PlanFocus(checkpoint: 2, section: "## 5. Section 5", seq: 1))))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        drain(0.5)
        let scroll = try XCTUnwrap(Self.all(host).compactMap { $0 as? NSScrollView }.first)
        let five = scroll.contentView.bounds.minY
        host.rootView = AnyView(page(PlanFocus(checkpoint: 2, section: "## 35. Section 35", seq: 2)))
        drain(0.5)
        let thirtyFive = scroll.contentView.bounds.minY
        print("PlanSection jump: §5 at \(five), §35 at \(thirtyFive)")
        // §5's hunk opens the diff, which starts just under the view picker: ~40 pt into the section.
        XCTAssertEqual(five, above + 40 - covered, accuracy: 30, "§5's hunk just under the covered top")
        XCTAssertGreaterThan(thirtyFive, five + 40, "§35's hunk is further down the page, and the page went there")
    }

    private static func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }
}
