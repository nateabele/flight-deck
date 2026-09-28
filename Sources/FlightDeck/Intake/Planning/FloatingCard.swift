import AppKit
import SwiftUI

/// Where a label's card goes, in AppKit screen coordinates (y up): under the label with leading
/// edges aligned, flipped above it when the window's bottom edge leaves no room below, and slid
/// back inside the window's sides. Pure, so `CardPlacementTests` pins the flip without a window.
///
/// `prefersAbove` is the selection toolbar's mirror image: over the selection, where it doesn't
/// cover the lines being read next, flipped below only when the top edge leaves no room.
///
/// `side: .trailing` opens beside the anchor instead, top edges aligned — for an anchor in a
/// margin (the churn lane's marker), whose card hung below it over the very section it explains.
enum CardPlacement {
    enum Side { case below, trailing }

    static func frame(for card: CGSize, anchor: CGRect, within bounds: CGRect, gap: CGFloat,
                      prefersAbove: Bool = false, side: Side = .below) -> CGRect {
        if side == .trailing { return trailing(card, anchor: anchor, within: bounds, gap: gap) }
        let below = anchor.minY - gap - card.height
        let above = anchor.maxY + gap
        // Below is the reading direction; flip only when that runs off the bottom AND above fits,
        // so a squat window doesn't trade one clipped card for a card covering its own row.
        let y = prefersAbove
            ? (above + card.height > bounds.maxY && below >= bounds.minY ? below : above)
            : (below < bounds.minY && above + card.height <= bounds.maxY ? above : below)
        let x = min(max(anchor.minX, bounds.minX), max(bounds.minX, bounds.maxX - card.width))
        return CGRect(x: x, y: y, width: card.width, height: card.height)
    }

    /// Beside the anchor, flipped to its leading side when the trailing one runs out of window
    /// (never slid back over the anchor itself), and moved up only as far as it takes to stay
    /// inside the window.
    private static func trailing(_ card: CGSize, anchor: CGRect, within bounds: CGRect, gap: CGFloat) -> CGRect {
        let after = anchor.maxX + gap
        let before = anchor.minX - gap - card.width
        let x = after + card.width <= bounds.maxX || before < bounds.minX ? after : before
        let y = max(bounds.minY, min(anchor.maxY, bounds.maxY) - card.height)
        return CGRect(x: x, y: y, width: card.width, height: card.height)
    }

    /// The area a card may occupy: the part of the window that's actually visible on its screen
    /// (not off the display's edge, not under the Dock or the menu bar), or the window itself
    /// when there's no screen or no overlap to clamp to.
    static func bounds(window: CGRect, screen: CGRect?) -> CGRect {
        guard let screen else { return window }
        let visible = window.intersection(screen)
        return visible.isNull || visible.isEmpty ? window : visible
    }
}

/// Presents `card` beside the view it backs, in a borderless child panel of that view's window.
///
/// **Why a panel, not an `.overlay` or a `.popover`.** An overlay is clipped by the tape's
/// horizontal ScrollView — the card for a slot vanished below the tape's bottom edge, which is
/// exactly where it opens. A popover escapes the clipping but brings system chrome (material
/// and an arrow the card can't restyle into the board's glass), and a transient popover
/// dismisses on the next click and can take focus from the board. A non-activating child
/// panel that ignores the mouse draws nothing but the card, never takes key, never eats the
/// hover that opened it (a card appearing under the pointer would otherwise end the hover and
/// flicker), and moves with its window because it is a child window. The price is placing it
/// ourselves — `CardPlacement` — and closing it ourselves — see `FloatingCardAnchor`.
struct FloatingCard<Card: View>: NSViewRepresentable {
    let isPresented: Bool
    let card: Card

    func makeNSView(context: Context) -> FloatingCardAnchor { FloatingCardAnchor() }

    func updateNSView(_ anchor: FloatingCardAnchor, context: Context) {
        anchor.present(isPresented ? AnyView(card) : nil)
    }

    static func dismantleNSView(_ anchor: FloatingCardAnchor, coordinator: ()) {
        anchor.present(nil)
    }
}

/// The AppKit half of `FloatingCard`: a view that never takes a hit, whose frame is the
/// anchor, and which owns the panel.
///
/// A panel outlives the SwiftUI state that asked for it unless something closes it: scrolling
/// the tape slides the label away from a card left hanging in place, and a card over a window
/// that lost key, was minimised or whose app went to the background floats over whatever the
/// user moved on to. Each of those closes the card and latches it shut; a re-render that still
/// asks for the card (the pointer never "left") doesn't reopen it — only withdrawing the
/// request (`present(nil)`) and making a fresh one does.
final class FloatingCardAnchor: NSView {
    /// Transparent margin around the card inside the panel, so `SplitFlapCard`'s own shadow
    /// (radius 17, offset 14) isn't cut off at the panel's edge.
    private static let shadowRoom: CGFloat = 34
    private static let gap: CGFloat = 9

    /// The selection toolbar's variant: its panel takes clicks (still non-activating, and a
    /// borderless panel never becomes key, so the editor keeps focus and its selection), and it
    /// opens above its anchor. Set before the first `present`.
    var interactive = false
    var prefersAbove = false
    /// Which side of this view the card opens on (`CardPlacement.Side`).
    var placement: CardPlacement.Side = .below

    private var card: AnyView?
    private var dismissed = false
    private var panel: NSPanel?
    private var host: NSHostingView<AnyView>?
    /// The panel frame last applied, so a re-render at the same spot doesn't re-set the frame
    /// and re-order the panel on every update.
    private var placed: CGRect?
    private var observers: [NSObjectProtocol] = []
    private weak var observedWindow: NSWindow?
    private weak var observedClip: NSClipView?

    /// How many times the panel has actually been moved — for tests of the skip.
    private(set) var placements = 0
    /// For tests: what this anchor is listening to right now.
    var observerCount: Int { observers.count }
    var hasPanel: Bool { panel != nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func present(_ card: AnyView?) {
        self.card = card
        if card == nil { dismissed = false }
        place()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        place()
    }

    override func layout() {
        super.layout()
        place()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func place() {
        // Observed only while a card is asked for: every split-flap label carries an anchor,
        // and each kept its window, app and scroll observers for life — woken by every scroll
        // for cards nobody had requested.
        guard let card else {
            stopObserving()
            return close()
        }
        observe()
        guard !dismissed, let window, !window.isMiniaturized else { return close() }
        let room = Self.shadowRoom
        let content = AnyView(card.padding(room).accessibilityHidden(true))
        let host = self.host ?? FirstMouseHostingView(rootView: content)
        host.rootView = content
        let panel = self.panel ?? makePanel(host)
        self.host = host
        self.panel = panel

        let fitting = host.fittingSize
        let size = CGSize(width: fitting.width - 2 * room, height: fitting.height - 2 * room)
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let within = CardPlacement.bounds(window: window.frame, screen: window.screen?.visibleFrame)
        let frame = CardPlacement.frame(for: size, anchor: anchor, within: within, gap: Self.gap, prefersAbove: prefersAbove,
                                        side: placement)
            .insetBy(dx: -room, dy: -room)
        guard frame != placed || panel.parent == nil else { return }
        placed = frame
        placements += 1
        panel.setFrame(frame, display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    /// (Re)subscribes to the events that must close the card whenever the window or the
    /// enclosing scroll view changes. Delivered synchronously (`queue: nil`) on the posting
    /// thread — all of these post on main — so the card is gone before the next frame draws.
    ///
    /// Every enclosing scroll view, not just the nearest: a card's anchor can sit in a scroll
    /// view inside the detail document (the board's tape), which scrolls too, and either one
    /// slides the anchor out from under a card left hanging in place.
    private func observe() {
        let clip = enclosingScrollView?.contentView
        guard window !== observedWindow || clip !== observedClip else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        observedWindow = window
        observedClip = clip
        guard let window else { return }
        let center = NotificationCenter.default
        let dismiss: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        observers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: nil, using: dismiss),
            center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: window, queue: nil, using: dismiss),
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil, using: dismiss),
        ]
        var scroll = enclosingScrollView
        while let current = scroll {
            let clip = current.contentView
            clip.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil, using: dismiss))
            scroll = current.superview?.enclosingScrollView
        }
    }

    private func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        observedWindow = nil
        observedClip = nil
    }

    /// Latches only a card that is actually requested: an event with nothing showing must not
    /// block the next hover.
    private func dismiss() {
        guard card != nil else { return }
        dismissed = true
        close()
    }

    private func makePanel(_ host: NSHostingView<AnyView>) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false        // the card draws its own
        panel.ignoresMouseEvents = !interactive
        panel.isReleasedWhenClosed = false
        host.wantsLayer = true
        panel.contentView = host
        return panel
    }

    /// Takes the panel down and lets it go: a board with dozens of slots would otherwise keep a
    /// window and a hosting view alive per slot ever hovered.
    private func close() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
        host = nil
        placed = nil
    }
}

/// Takes the click that lands on an interactive card even though its panel never becomes key —
/// without it the first click on a toolbar button would only try to activate the panel.
private final class FirstMouseHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Calls `onScroll` whenever the enclosing scroll view scrolls — how the board forgets a hover
/// the pointer never got to end (the slot slid out from under it). macOS 14 has no SwiftUI
/// scroll-offset callback, so this reads the clip view's bounds like `FloatingCardAnchor` does.
struct ScrollWatcher: NSViewRepresentable {
    let onScroll: () -> Void

    func makeNSView(context: Context) -> WatcherView { WatcherView() }
    func updateNSView(_ view: WatcherView, context: Context) { view.onScroll = onScroll }

    final class WatcherView: NSView {
        var onScroll: (() -> Void)?
        private var observer: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard window != nil, let clip = enclosingScrollView?.contentView else { return }
            clip.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                              queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.onScroll?() }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
