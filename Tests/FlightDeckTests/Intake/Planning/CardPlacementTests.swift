import AppKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Where the split-flap card goes, in AppKit screen coordinates (y up). The card lives in its
/// own child panel so the tape's ScrollView can't clip it; that makes placement our job, and
/// this is all of it.
final class CardPlacementTests: XCTestCase {
    private let window = CGRect(x: 100, y: 100, width: 800, height: 500)
    private let card = CGSize(width: 180, height: 70)

    /// Room below: the card hangs under the label, leading edges aligned.
    func testOpensBelowTheLabel() {
        let label = CGRect(x: 300, y: 450, width: 40, height: 18)
        let frame = CardPlacement.frame(for: card, anchor: label, within: window, gap: 9)
        XCTAssertEqual(frame, CGRect(x: 300, y: 450 - 9 - 70, width: 180, height: 70))
    }

    /// Near the window's bottom edge there's no room below, so it flips up over the label.
    func testFlipsUpNearTheBottomEdge() {
        let label = CGRect(x: 300, y: 140, width: 40, height: 18)
        let frame = CardPlacement.frame(for: card, anchor: label, within: window, gap: 9)
        XCTAssertEqual(frame.minY, 140 + 18 + 9, "flipped: starts a gap above the label")
        XCTAssertGreaterThan(frame.minY, label.maxY)
    }

    /// Neither side fits (a squat window): below wins, the reading direction, rather than
    /// covering the label's own row.
    func testStaysBelowWhenNeitherSideFits() {
        let squat = CGRect(x: 100, y: 100, width: 800, height: 100)
        let label = CGRect(x: 300, y: 140, width: 40, height: 18)
        let frame = CardPlacement.frame(for: card, anchor: label, within: squat, gap: 9)
        XCTAssertEqual(frame.maxY, 140 - 9)
    }

    /// The selection toolbar opens over the selection, and flips under it only when the
    /// window's top edge leaves no room.
    func testPrefersAboveFlipsBelowAtTheTop() {
        let middle = CGRect(x: 300, y: 300, width: 40, height: 18)
        XCTAssertEqual(CardPlacement.frame(for: card, anchor: middle, within: window, gap: 9, prefersAbove: true).minY,
                       300 + 18 + 9)
        let top = CGRect(x: 300, y: 560, width: 40, height: 18)
        XCTAssertEqual(CardPlacement.frame(for: card, anchor: top, within: window, gap: 9, prefersAbove: true).maxY,
                       560 - 9, "no room above: under the selection")
    }

    /// A label at the trailing edge slides its card back inside the window rather than
    /// hanging it off the side; one at the leading edge stays put.
    func testClampsHorizontallyInsideTheWindow() {
        let trailing = CGRect(x: 870, y: 450, width: 28, height: 18)
        XCTAssertEqual(CardPlacement.frame(for: card, anchor: trailing, within: window, gap: 9).maxX, window.maxX)
        let leading = CGRect(x: 90, y: 450, width: 28, height: 18)
        XCTAssertEqual(CardPlacement.frame(for: card, anchor: leading, within: window, gap: 9).minX, window.minX)
    }

    /// A window partly off-screen (or under the Dock) clamps its card to what can be seen.
    func testBoundsAreTheVisiblePartOfTheWindow() {
        let screen = CGRect(x: 0, y: 80, width: 1440, height: 820)
        XCTAssertEqual(CardPlacement.bounds(window: CGRect(x: 1000, y: 0, width: 800, height: 500), screen: screen),
                       CGRect(x: 1000, y: 80, width: 440, height: 420))
        XCTAssertEqual(CardPlacement.bounds(window: window, screen: nil), window, "no screen: the window alone")
        XCTAssertEqual(CardPlacement.bounds(window: CGRect(x: 5000, y: 0, width: 100, height: 100), screen: screen),
                       CGRect(x: 5000, y: 0, width: 100, height: 100), "wholly off-screen: nothing to clamp to, keep the window")
    }

    /// The card opens on keyboard focus only when a key moved the focus — never when a click
    /// focused a label, or when AppKit handed the window's initial focus to it.
    func testOnlyKeyboardFocusOpensTheCard() {
        XCTAssertTrue(SplitFlapText.isKeyboardFocus(focused: true, event: .keyDown))
        XCTAssertFalse(SplitFlapText.isKeyboardFocus(focused: true, event: .leftMouseDown))
        XCTAssertFalse(SplitFlapText.isKeyboardFocus(focused: true, event: nil))
        XCTAssertFalse(SplitFlapText.isKeyboardFocus(focused: false, event: .keyDown))
    }

    // MARK: - Trailing

    /// `.trailing`: beside the anchor, a gap off its trailing edge, top edges aligned — the churn
    /// lane's versions card, which below its marker sat over the section it explains.
    func testTrailingOpensBesideTheAnchorTopAligned() {
        let marker = CGRect(x: 120, y: 400, width: 132, height: 20)
        let frame = CardPlacement.frame(for: card, anchor: marker, within: window, gap: 9, side: .trailing)
        XCTAssertEqual(frame, CGRect(x: 120 + 132 + 9, y: 420 - 70, width: 180, height: 70))
    }

    /// No room past the trailing edge: it opens on the leading side instead of sliding back
    /// over the anchor.
    func testTrailingFlipsToLeadingAtTheRightEdge() {
        let marker = CGRect(x: 700, y: 400, width: 132, height: 20)
        let frame = CardPlacement.frame(for: card, anchor: marker, within: window, gap: 9, side: .trailing)
        XCTAssertEqual(frame.maxX, 700 - 9)
        XCTAssertEqual(frame.maxY, 420)
    }

    /// Near the window's bottom the card slides up to stay inside it, still beside the anchor.
    func testTrailingSlidesUpInsideTheWindow() {
        let marker = CGRect(x: 120, y: 130, width: 132, height: 20)
        let frame = CardPlacement.frame(for: card, anchor: marker, within: window, gap: 9, side: .trailing)
        XCTAssertEqual(frame.minY, window.minY)
        XCTAssertEqual(frame.minX, 120 + 132 + 9)
    }

    /// Below stays the default, so every existing card is unchanged.
    func testBelowIsTheDefaultSide() {
        let label = CGRect(x: 300, y: 450, width: 40, height: 18)
        XCTAssertEqual(CardPlacement.frame(for: card, anchor: label, within: window, gap: 9),
                       CardPlacement.frame(for: card, anchor: label, within: window, gap: 9, side: .below))
    }
}

/// The card's panel lifecycle: it must not float over a board that has moved on under it.
@MainActor
final class FloatingCardAnchorTests: XCTestCase {
    private var window: NSWindow!
    private var scroll: NSScrollView!
    private var anchor: FloatingCardAnchor!

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 300),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 300))
        anchor = FloatingCardAnchor(frame: NSRect(x: 20, y: 200, width: 40, height: 18))
        document.addSubview(anchor)
        scroll.documentView = document
        window.contentView = scroll
        window.orderFrontRegardless()
    }

    override func tearDown() async throws {
        anchor.present(nil)
        window.orderOut(nil)
    }

    private var card: AnyView { AnyView(Text("Refine 2").padding()) }
    private var shown: Bool { !(window.childWindows ?? []).isEmpty }

    func testPresentsAndReleasesThePanel() {
        anchor.present(card)
        XCTAssertTrue(shown)
        XCTAssertTrue(anchor.hasPanel)
        anchor.present(nil)
        XCTAssertFalse(shown)
        XCTAssertFalse(anchor.hasPanel, "closing releases the panel and its hosting view")
    }

    /// Scrolling the tape moves the label out from under its card: the card closes, and stays
    /// closed (the latch) while the same presentation keeps arriving, until it is withdrawn.
    func testScrollClosesAndLatchesUntilWithdrawn() {
        anchor.present(card)
        XCTAssertTrue(shown)
        scroll.contentView.scroll(to: NSPoint(x: 200, y: 0))
        XCTAssertFalse(shown, "scrolled: closed")
        anchor.present(card)
        XCTAssertFalse(shown, "latched: a re-render with the card still requested doesn't reopen it")
        anchor.present(nil)
        anchor.present(card)
        XCTAssertTrue(shown, "a fresh presentation reopens it")
    }

    func testResignKeyMiniaturizeAndDeactivateClose() {
        for name in [NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification] {
            anchor.present(nil)
            anchor.present(card)
            XCTAssertTrue(shown)
            NotificationCenter.default.post(name: name, object: window)
            XCTAssertFalse(shown, name.rawValue)
        }
        anchor.present(nil)
        anchor.present(card)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertFalse(shown, "app deactivated")
    }

    /// The same close, through the real SwiftUI stack: a SwiftUI `ScrollView` on macOS is an
    /// `NSScrollView` the anchor can find, so scrolling the tape really does close the card.
    func testSwiftUIScrollViewClosesTheCard() throws {
        let view = ScrollView(.horizontal) {
            HStack(spacing: 0) {
                Text("RF2").background(FloatingCard(isPresented: true, card: Text("Refine 2").padding()))
                Color.clear.frame(width: 2000, height: 20)
            }
        }
        let host = NSHostingView(rootView: view.frame(width: 400, height: 100))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(window.childWindows?.count, 1, "card open")

        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        let scroll = try XCTUnwrap(scrollViews(host).first, "SwiftUI ScrollView is backed by an NSScrollView")
        scroll.contentView.scroll(to: NSPoint(x: 300, y: 0))
        XCTAssertEqual(window.childWindows?.count ?? 0, 0, "scrolled: closed")
    }

    /// Re-presenting at an unchanged spot doesn't re-set the frame or re-order the panel.
    func testUnchangedPlacementIsSkipped() {
        anchor.present(card)
        let placements = anchor.placements
        anchor.present(card)
        anchor.needsLayout = true
        anchor.layoutSubtreeIfNeeded()
        XCTAssertEqual(anchor.placements, placements)
    }
}
