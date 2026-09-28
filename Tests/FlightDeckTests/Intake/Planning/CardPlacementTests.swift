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

    // MARK: - Above (the board's hover cards)

    /// `.above`: over the anchor a small gap up, centred on it — out of the path of a pointer
    /// moving along the tape, which is near the board's bottom.
    func testAboveOpensOverTheAnchorCentred() {
        let slot = CGRect(x: 400, y: 200, width: 40, height: 18)
        let frame = CardPlacement.frame(for: card, anchor: slot, within: window, gap: 7, side: .above)
        XCTAssertEqual(frame, CGRect(x: 420 - 90, y: 218 + 7, width: 180, height: 70))
    }

    /// No room above (the window's top edge): below, still centred, still clear of the anchor.
    func testAboveFlipsBelowWhenClippedAtTheTop() {
        let slot = CGRect(x: 400, y: 540, width: 40, height: 18)
        let frame = CardPlacement.frame(for: card, anchor: slot, within: window, gap: 7, side: .above)
        XCTAssertEqual(frame.maxY, 540 - 7)
        XCTAssertEqual(frame.midX, 420)
    }

    /// Near a side the card slides back inside, an edge margin short of it — the nub, not the
    /// card, keeps pointing at the anchor.
    func testAboveClampsHorizontallyWithAMargin() {
        let trailing = CGRect(x: 880, y: 200, width: 16, height: 18)
        let t = CardPlacement.frame(for: card, anchor: trailing, within: window, gap: 7, side: .above)
        XCTAssertEqual(t.maxX, window.maxX - CardPlacement.edgeMargin)
        let leading = CGRect(x: 150, y: 200, width: 16, height: 18)
        let l = CardPlacement.frame(for: card, anchor: leading, within: window, gap: 7, side: .above)
        XCTAssertEqual(l.minX, window.minX + CardPlacement.edgeMargin)
        XCTAssertEqual(CardPlacement.nubX(card: l, anchor: leading), leading.midX - l.minX)
        XCTAssertEqual(CardPlacement.nubX(card: t, anchor: trailing), t.width - CardPlacement.nubInset,
                       "an anchor past the card's corner: the nub stops at the corner's radius")
    }

    /// Whatever the anchor's spot in the window, the card never lands on it.
    func testAboveNeverCoversTheAnchor() {
        for x in stride(from: 90.0, through: 900.0, by: 37) {
            for y in stride(from: 90.0, through: 600.0, by: 23) {
                let anchor = CGRect(x: x, y: y, width: 36, height: 18)
                let frame = CardPlacement.frame(for: card, anchor: anchor, within: window, gap: 7, side: .above)
                XCTAssertFalse(frame.intersects(anchor), "\(anchor)")
            }
        }
    }

    /// The pinned control bar above the board: a card that would sit over it opens below
    /// instead when there is room — and a bar the anchor itself sits in is no obstacle.
    func testAboveAvoidsAnObstacle() {
        let bar = CGRect(x: 100, y: 400, width: 800, height: 78)
        let now = CGRect(x: 300, y: 360, width: 60, height: 20)
        let frame = CardPlacement.frame(for: card, anchor: now, within: window, gap: 7, side: .above, avoiding: [bar])
        XCTAssertEqual(frame.maxY, 360 - 7, "below NOW rather than over the bar")
        let cell = CGRect(x: 300, y: 420, width: 60, height: 20)
        XCTAssertEqual(CardPlacement.frame(for: card, anchor: cell, within: window, gap: 7, side: .above, avoiding: [bar]).minY,
                       440 + 7, "inside the bar: the bar isn't in its way")
        let low = CGRect(x: 300, y: 140, width: 60, height: 20)
        let tall = CGRect(x: 100, y: 170, width: 800, height: 400)
        XCTAssertEqual(CardPlacement.frame(for: card, anchor: low, within: window, gap: 7, side: .above, avoiding: [tall]).minY,
                       160 + 7, "no clear side at all: above wins, over the bar rather than the tape")
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

    /// An anchor with no card asked for listens to nothing. Every split-flap label carries an
    /// anchor, and each one kept its window, app and scroll observers for as long as it lived —
    /// a board's worth of observers woken by every scroll, for cards nobody had asked for.
    func testAnIdleAnchorObservesNothing() {
        anchor.layout()
        XCTAssertEqual(anchor.observerCount, 0, "no card requested, nothing observed")
        anchor.present(card)
        XCTAssertGreaterThan(anchor.observerCount, 0)
        anchor.present(nil)
        XCTAssertEqual(anchor.observerCount, 0, "withdrawn: observers gone with it")
    }

    /// The plan's notes follow scrolling of the clip views around the editor — and only those,
    /// not every clip view in the app (`object: nil` woke the bridge for every scroll anywhere).
    func testNotesFollowOnlyTheirOwnEnclosingClips() {
        let inner = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let text = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        inner.documentView = text
        let outerDocument = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 300))
        outerDocument.addSubview(inner)
        let outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        outer.documentView = outerDocument
        XCTAssertEqual(PlanNotesBridge.enclosingClips(of: text).map(ObjectIdentifier.init),
                       [inner.contentView, outer.contentView].map(ObjectIdentifier.init))
        XCTAssertEqual(PlanNotesBridge.enclosingClips(of: NSView()), [])
    }

    /// A hover card never takes the mouse: it can't eat the hover or the click on the board
    /// under it.
    func testTheHoverCardPanelIgnoresTheMouse() throws {
        anchor.present(card)
        let panel = try XCTUnwrap(window.childWindows?.first)
        XCTAssertTrue(panel.ignoresMouseEvents)
    }

    /// A click anywhere, or Esc, closes a hover card and latches it like a scroll does.
    func testClickAndEscapeClose() throws {
        for event in [
            NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                             context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53),
        ] {
            anchor.present(nil)
            anchor.present(card)
            XCTAssertTrue(shown)
            XCTAssertTrue(anchor.closes(on: try XCTUnwrap(event)))
            XCTAssertFalse(shown)
        }
        let other = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                     context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)
        anchor.present(nil)
        anchor.present(card)
        XCTAssertFalse(anchor.closes(on: try XCTUnwrap(other)), "an ordinary key leaves it be")
        XCTAssertTrue(shown)
    }

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
