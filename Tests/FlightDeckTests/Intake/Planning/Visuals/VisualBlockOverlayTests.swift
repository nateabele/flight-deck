import AppKit
import IntakeKit
import XCTest
@testable import FlightDeck

/// The visual blocks in the editor (V-R1): a `VisualBlockView` laid over each block's hidden
/// source, as tall as the block's model says.
///
/// - Review Focus 1: a block whose id has no revision is a quiet placeholder of fixed height,
///   never a crash and never a collapsed editor.
/// - Review Focus 2: typing above or below a block, putting the caret in it or deleting its fence
///   — the view follows the block or goes, and never covers a line of text.
/// - At most three blocks hold a live web view, the least recently used going back to its picture.
@MainActor
final class VisualBlockOverlayTests: XCTestCase {
    private var fixture: VisualFixture!

    override func setUpWithError() throws { fixture = try VisualFixture() }
    override func tearDown() { fixture.remove() }

    @MainActor struct Editor {
        let coordinator: PlanTextView.Coordinator
        let container: PlanEditorContainer
        let scroll: NSScrollView
        let window: NSWindow
        var view: PlanNSTextView { container.textView }
        var overlay: VisualBlockOverlay { view.visualBlocks }

        func settle() {
            let until = Date().addingTimeInterval(3)
            repeat { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) } while view.layingOutWholePlan && Date() < until
            container.frame.size.height = container.contentHeight
            scroll.documentView?.frame.size.height = container.contentHeight
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            container.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
        }

        func close() {
            coordinator.timer?.invalidate()
            overlay.tearDown()
            window.close()
        }

        /// Every block view, in text order.
        var blocks: [VisualBlockView] {
            overlay.placements().compactMap { overlay.blocks[$0.key] }
        }

        func offset(_ needle: String) -> Int {
            let r = (view.string as NSString).range(of: needle)
            precondition(r.location != NSNotFound, needle)
            return r.location
        }

        /// The laid-out lines of every paragraph that is not a visual block's hidden source, in
        /// the text view's coordinates: what a block's view must never cover.
        func textLineRects() -> [CGRect] {
            guard let layout = view.textLayoutManager else { return [] }
            var out: [CGRect] = []
            let origin = view.textContainerOrigin
            layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
                let text = (fragment.textElement as? NSTextParagraph)?.attributedString
                if let text, text.length > 0, text.attribute(.planVisual, at: 0, effectiveRange: nil) == nil,
                   !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    for line in fragment.textLineFragments {
                        out.append(line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX + origin.x,
                                                                   dy: fragment.layoutFragmentFrame.minY + origin.y))
                    }
                }
                return true
            }
            return out
        }

        func assertNothingCovered(_ context: String, file: StaticString = #filePath, line: UInt = #line) {
            for block in blocks where !block.isHidden {
                for rect in textLineRects() where rect.intersects(block.frame.insetBy(dx: 0, dy: 0.5)) {
                    XCTFail("\(context): the block at \(block.frame) covers text at \(rect)", file: file, line: line)
                }
            }
        }
    }

    private func editor(_ text: String, store: (any VisualStoreReading)?, height: CGFloat = 900, focused: Bool = true) -> Editor {
        let view = PlanTextView(text: .constant(text), editable: true, onCommit: { _ in }, incoming: nil, onShowIncoming: {})
            .visuals(store)
        let coordinator = view.makeCoordinator()
        let container = PlanEditorContainer(onShow: {})
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let page = FlippedPage(frame: NSRect(x: 0, y: 0, width: 900, height: height))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: height))
        scroll.hasVerticalScroller = true
        scroll.documentView = page
        page.addSubview(container)
        window.contentView = scroll
        container.frame = NSRect(x: 0, y: 0, width: 900, height: height)
        coordinator.textView = container.textView
        container.textView.delegate = coordinator
        container.textView.textStorage?.delegate = coordinator
        container.textView.onFocusChange = { [weak coordinator] in coordinator?.focusChanged() }
        container.textView.isFocused = focused
        // What `makeNSView` does before its first load.
        container.textView.visualBlocks.store = store
        coordinator.load(text)
        let e = Editor(coordinator: coordinator, container: container, scroll: scroll, window: window)
        e.settle()
        e.overlay.refresh()
        return e
    }

    private final class FlippedPage: NSView {
        override var isFlipped: Bool { true }
    }

    private static let missingPlan = """
    # Pairing

    The phone pairs with the Mac over SPAKE2 using a short code.

    ```fd-visual id=nowhere
    Pairing handshake: phone, Mac and hostd
    ```

    If the exchange fails, the phone shows the code entry again.
    """

    private static let pairingPlan = missingPlan.replacingOccurrences(of: "id=nowhere", with: "id=pairing-handshake")

    // MARK: - Review Focus 1: a missing revision

    func testAMissingRevisionIsAFixedHeightPlaceholder() throws {
        for store in [fixture.store as (any VisualStoreReading)?, nil] {
            let e = editor(Self.missingPlan, store: store, focused: false)
            defer { e.close() }
            let block = try XCTUnwrap(e.blocks.first, "a view, not a crash and not nothing")
            XCTAssertEqual(e.blocks.count, 1)
            XCTAssertEqual(block.model.content, .missing)
            XCTAssertEqual(block.frame.height, VisualBlockLayout.placeholder, accuracy: 1)
            XCTAssertEqual(block.testSnapshot.placeholder, "Missing visual · nowhere")
            let after = e.textLineRects().first { $0.minY > block.frame.minY }
            XCTAssertNotNil(after, "the paragraph after the block is still laid out")
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(after).minY, block.frame.maxY - 0.5, "below the placeholder, not under it")
            e.assertNothingCovered("missing")
        }
    }

    func testAPendingVisualIsAPlaceholderOfTheSameHeight() throws {
        let e = editor(Self.missingPlan.replacingOccurrences(of: "id=nowhere", with: "id=nowhere pending"), store: fixture.store, focused: false)
        defer { e.close() }
        let block = try XCTUnwrap(e.blocks.first)
        XCTAssertEqual(block.model.content, .pending)
        XCTAssertEqual(block.frame.height, VisualBlockLayout.placeholder, accuracy: 1)
        XCTAssertEqual(block.testSnapshot.placeholder, "Visual requested · nowhere")
    }

    func testABlockIsAsTallAsItsModelWhateverItDraws() throws {
        try fixture.pairing()
        let e = editor(Self.pairingPlan, store: fixture.store, focused: false)
        defer { e.close() }
        let block = try XCTUnwrap(e.blocks.first)
        XCTAssertEqual(block.model.representations.count, 3)
        XCTAssertEqual(block.frame.height, VisualBlockLayout.header + VisualBlockLayout.body + VisualBlockLayout.filmstrip, accuracy: 1)
        XCTAssertEqual(block.testSnapshot.tiles, ["Sequence ★", "Components", "Data flow"])
        e.assertNothingCovered("pairing")
    }

    // MARK: - Review Focus 2: editing next to a block

    func testTypingAboveMovesTheBlockWithItsText() throws {
        let e = editor(Self.missingPlan, store: fixture.store)
        defer { e.close() }
        let before = try XCTUnwrap(e.blocks.first).frame
        e.view.setSelectedRange(NSRange(location: e.offset("The phone pairs"), length: 0))
        e.view.insertText("A whole new paragraph typed above the block, long enough to matter.\n\n", replacementRange: e.view.selectedRange())
        let after = try XCTUnwrap(e.blocks.first, "the same block, still drawn")
        XCTAssertGreaterThan(after.frame.minY, before.minY + 10, "it moved down with the text")
        XCTAssertEqual(after.frame.height, before.height, accuracy: 0.5)
        e.assertNothingCovered("typed above, same turn")
        e.settle()
        e.assertNothingCovered("typed above, settled")
    }

    func testTypingBelowLeavesTheBlockWhereItIs() throws {
        let e = editor(Self.missingPlan, store: fixture.store)
        defer { e.close() }
        let before = try XCTUnwrap(e.blocks.first).frame
        e.view.setSelectedRange(NSRange(location: e.offset("If the exchange"), length: 0))
        e.view.insertText("Typed below: ", replacementRange: e.view.selectedRange())
        XCTAssertEqual(try XCTUnwrap(e.blocks.first).frame, before)
        e.assertNothingCovered("typed below")
    }

    func testDeletingTheLinesAboveMovesTheBlockUp() throws {
        let e = editor(Self.missingPlan, store: fixture.store)
        defer { e.close() }
        let before = try XCTUnwrap(e.blocks.first).frame
        let start = e.offset("The phone pairs")
        let end = e.offset("```fd-visual")
        e.view.setSelectedRange(NSRange(location: start, length: end - start))
        e.view.deleteBackward(nil)
        // The caret is now at the block's opening fence, which is in the block: its source shows.
        XCTAssertTrue(e.blocks.isEmpty)
        e.assertNothingCovered("deleted above, caret at the fence")
        e.view.setSelectedRange(NSRange(location: e.offset("If the exchange"), length: 0))
        let after = try XCTUnwrap(e.blocks.first)
        XCTAssertLessThan(after.frame.minY, before.minY - 10)
        e.assertNothingCovered("deleted above")
    }

    func testTheCaretInTheBlockShowsItsSourceAndTheViewGoes() throws {
        let e = editor(Self.missingPlan, store: fixture.store)
        defer { e.close() }
        XCTAssertEqual(e.blocks.count, 1)
        let caption = e.offset("Pairing handshake: phone")
        e.view.setSelectedRange(NSRange(location: caption + 3, length: 0))
        XCTAssertTrue(e.blocks.isEmpty, "the source shows, so nothing is drawn over it")
        XCTAssertTrue(e.view.subviews.allSatisfy { !($0 is VisualBlockView) }, "the view left the text view")
        let font = e.view.textStorage?.attribute(.font, at: caption, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(font?.pointSize ?? 0, 5, "the caption is readable text again")
        e.assertNothingCovered("caret in")
        // Out again: the view comes back.
        e.view.setSelectedRange(NSRange(location: e.offset("If the exchange"), length: 0))
        XCTAssertEqual(e.blocks.count, 1)
        e.assertNothingCovered("caret out")
    }

    func testDeletingTheClosingFenceRemovesTheView() throws {
        let e = editor(Self.missingPlan, store: fixture.store)
        defer { e.close() }
        let ns = e.view.string as NSString
        let close = ns.range(of: "```\n\nIf the exchange")
        e.view.setSelectedRange(NSRange(location: close.location, length: 4))
        e.view.deleteBackward(nil)
        e.view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(e.blocks.isEmpty, "an unclosed fence is code to the end of the plan, not a hidden block")
        XCTAssertTrue(e.view.subviews.allSatisfy { !($0 is VisualBlockView) })
        e.assertNothingCovered("closing fence deleted")
    }

    func testDeletingTheOpeningFenceRemovesTheView() throws {
        let e = editor(Self.missingPlan, store: fixture.store)
        defer { e.close() }
        let open = (e.view.string as NSString).range(of: "```fd-visual id=nowhere\n")
        e.view.setSelectedRange(open)
        e.view.deleteBackward(nil)
        e.view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(e.blocks.isEmpty)
        XCTAssertTrue(e.view.subviews.allSatisfy { !($0 is VisualBlockView) })
        e.assertNothingCovered("opening fence deleted")
    }

    func testTwoBlocksWithTheSameIdEachGetAView() throws {
        let plan = Self.missingPlan + "\n\n```fd-visual id=nowhere\nAgain\n```\n\nEnd."
        let e = editor(plan, store: fixture.store, focused: false)
        defer { e.close() }
        let blocks = e.blocks
        XCTAssertEqual(blocks.count, 2)
        guard blocks.count == 2 else { return }
        XCTAssertLessThan(blocks[0].frame.maxY, blocks[1].frame.minY)
        e.assertNothingCovered("two blocks")
    }

    // MARK: - Live web views

    func testAtMostThreeBlocksAreLiveAndTheLeastRecentlyUsedGoesBack() throws {
        for (i, id) in ["v-a", "v-b", "v-c", "v-d", "v-e"].enumerated() {
            try fixture.revision(id, r: 1, source: i.isMultiple(of: 2) ? VisualFixture.flowchart : VisualFixture.sequence)
        }
        let plan = ["v-a", "v-b", "v-c", "v-d", "v-e"].map { "Paragraph before \($0).\n\n```fd-visual id=\($0)\n\($0)\n```\n" }.joined(separator: "\n")
        // Tall enough that every block is on screen at once.
        let e = editor(plan, store: fixture.store, height: 2400, focused: false)
        defer { e.close() }
        e.overlay.updateLiveness()
        XCTAssertEqual(e.blocks.count, 5)
        XCTAssertEqual(e.blocks.filter(\.isLive).count, VisualLivePool.limit, "three of five on screen are live")
        XCTAssertEqual(VisualLivePool.shared.liveCount, VisualLivePool.limit)
        let live = e.blocks.filter(\.isLive)
        let waiting = try XCTUnwrap(e.blocks.first { !$0.isLive })
        // The first to go live is the least recently used once the others were touched after it.
        VisualLivePool.shared.touch(live[1])
        VisualLivePool.shared.touch(live[2])
        VisualLivePool.shared.grant(waiting)
        XCTAssertTrue(waiting.isLive)
        XCTAssertFalse(live[0].isLive, "the least recently used went back to its picture")
        XCTAssertEqual(e.blocks.filter(\.isLive).count, VisualLivePool.limit)
    }

    func testABlockThatLeavesTheScreenGivesItsWebViewBack() throws {
        try fixture.revision("v-a", r: 1, source: VisualFixture.flowchart)
        let filler = (0..<60).map { "Filler paragraph \($0) that pushes the page down." }.joined(separator: "\n\n")
        let e = editor("```fd-visual id=v-a\nTop\n```\n\n" + filler, store: fixture.store, height: 600, focused: false)
        defer { e.close() }
        e.overlay.updateLiveness()
        let block = try XCTUnwrap(e.blocks.first)
        XCTAssertTrue(block.isLive)
        e.scroll.contentView.scroll(to: NSPoint(x: 0, y: 2000))
        e.scroll.reflectScrolledClipView(e.scroll.contentView)
        e.overlay.updateLiveness()
        XCTAssertFalse(block.isLive, "off screen, it shows its picture")
        XCTAssertEqual(VisualLivePool.shared.liveCount, 0)
    }

    func testAParseErrorShowsInTheLiveBlock() throws {
        try fixture.revision("broken", r: 1, source: VisualFixture.broken)
        let e = editor("```fd-visual id=broken\nBroken\n```\n\nAfter.", store: fixture.store, focused: false)
        defer { e.close() }
        e.overlay.updateLiveness()
        let block = try XCTUnwrap(e.blocks.first)
        XCTAssertTrue(block.isLive)
        let until = Date().addingTimeInterval(20)
        while block.liveStatus == .loading, Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        guard case .failed(let message, _) = block.liveStatus else { return XCTFail("\(String(describing: block.liveStatus))") }
        XCTAssertTrue(message.contains("Parse error"), message)
    }
}
