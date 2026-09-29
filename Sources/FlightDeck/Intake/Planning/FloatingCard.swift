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
/// margin with free space past it. (The churn lane's card used it until the plan wrapped to the
/// pane; it now opens `.belowLine`.)
///
/// `side: .above` is the board's hover card: over the anchor and centred on it, with a nub
/// pointing down at it. The tape runs along the board's bottom, so a card hung below a slot sat
/// on the neighbouring slots and on the row the pointer was moving along; above is out of that
/// path. It flips below only when there is no room above, and steers clear of `avoiding` (the
/// pinned control bar) when the other side has room.
///
/// `side: .belowLine` is the churn lane's versions card: the anchor is a whole line of text (the
/// marked heading, from the text column's leading edge to its trailing one) and the card hangs
/// just under it, leading edges aligned, with a nub up at the line — so it never covers the line
/// it explains. It flips above only when the visible area has no room below. `.trailing` was
/// the card's side while the plan had a fixed measure; wrapped to the pane, the text has no
/// free space beside it, and the flipped card sat on the very lines being compared.
enum CardPlacement {
    enum Side { case below, trailing, above, belowLine }

    /// How far an `.above` card keeps from the sides of its bounds.
    static let edgeMargin: CGFloat = 8
    /// How close to a card's corner its nub may sit — the corner radius plus half the nub.
    static let nubInset: CGFloat = 16

    static func frame(for card: CGSize, anchor: CGRect, within bounds: CGRect, gap: CGFloat,
                      prefersAbove: Bool = false, side: Side = .below, avoiding obstacles: [CGRect] = []) -> CGRect {
        if side == .trailing { return trailing(card, anchor: anchor, within: bounds, gap: gap) }
        if side == .above { return above(card, anchor: anchor, within: bounds, gap: gap, avoiding: obstacles) }
        if side == .belowLine { return belowLine(card, anchor: anchor, within: bounds, gap: gap) }
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

    /// Over the anchor, centred and slid inside the bounds' sides with a margin; below when
    /// there is no room above. Either side must keep clear of every obstacle the anchor isn't
    /// itself in; when neither can, above if it fits (over the control bar is better than over
    /// the tape), else whichever side has more room — never slid back over the anchor.
    private static func above(_ card: CGSize, anchor: CGRect, within bounds: CGRect, gap: CGFloat,
                              avoiding obstacles: [CGRect]) -> CGRect {
        let lo = bounds.minX + edgeMargin
        let x = min(max(anchor.midX - card.width / 2, lo), max(lo, bounds.maxX - edgeMargin - card.width))
        let up = CGRect(x: x, y: anchor.maxY + gap, width: card.width, height: card.height)
        let down = CGRect(x: x, y: anchor.minY - gap - card.height, width: card.width, height: card.height)
        let fits = { (r: CGRect) in r.minY >= bounds.minY && r.maxY <= bounds.maxY }
        let blocking = obstacles.filter { !$0.intersects(anchor) }
        let clear = { (r: CGRect) in !blocking.contains { $0.intersects(r) } }
        if let open = [up, down].first(where: { fits($0) && clear($0) }) { return open }
        if fits(up) { return up }
        if fits(down) { return down }
        return bounds.maxY - anchor.maxY >= anchor.minY - bounds.minY ? up : down
    }

    /// Under the line, leading edges aligned and slid inside the bounds' sides with a margin;
    /// above it when below runs out of the bounds and above fits; when neither fits, whichever
    /// side has more room — never back over the line.
    private static func belowLine(_ card: CGSize, anchor: CGRect, within bounds: CGRect, gap: CGFloat) -> CGRect {
        let lo = bounds.minX + edgeMargin
        let x = min(max(anchor.minX, lo), max(lo, bounds.maxX - edgeMargin - card.width))
        let down = CGRect(x: x, y: anchor.minY - gap - card.height, width: card.width, height: card.height)
        let up = CGRect(x: x, y: anchor.maxY + gap, width: card.width, height: card.height)
        if down.minY >= bounds.minY { return down }
        if up.maxY <= bounds.maxY { return up }
        return anchor.minY - bounds.minY >= bounds.maxY - anchor.maxY ? down : up
    }

    /// A `.belowLine` card's nub: near the line's leading end — the end its marker sits beside,
    /// in the gutter — held off the card's rounded corner.
    static func lineNubX(card: CGRect, anchor: CGRect) -> CGFloat {
        min(max(anchor.minX - card.minX + nubInset, nubInset), max(nubInset, card.width - nubInset))
    }

    /// Where along a placed card's width its nub goes: under the anchor's centre, held off the
    /// rounded corners when the card had to slide away from an anchor near the window's side.
    static func nubX(card: CGRect, anchor: CGRect) -> CGFloat {
        min(max(anchor.midX - card.minX, nubInset), max(nubInset, card.width - nubInset))
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
    /// Which side of the label the card opens on; the board's hover cards pass `.above`.
    var side: CardPlacement.Side = .below
    /// Told when the card closes itself (click, Esc, scroll, window change) — how the hover
    /// intent learns the card it thinks is open is gone.
    var onDismiss: (() -> Void)?

    func makeNSView(context: Context) -> FloatingCardAnchor { FloatingCardAnchor() }

    func updateNSView(_ anchor: FloatingCardAnchor, context: Context) {
        anchor.placement = side
        anchor.onDismiss = onDismiss
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
    /// `.above`'s tighter gap: just the nub's height and a hair, so the nub all but touches the
    /// label it names.
    private static let nubGap: CGFloat = 7
    /// `.belowLine`'s gap under the line: the nub's height, so its tip just meets the line.
    private static let lineGap: CGFloat = 6

    /// The selection toolbar's variant: its panel takes clicks (still non-activating, and a
    /// borderless panel never becomes key, so the editor keeps focus and its selection), and it
    /// opens above its anchor. Set before the first `present`.
    var interactive = false
    var prefersAbove = false
    /// Which side of this view the card opens on (`CardPlacement.Side`).
    var placement: CardPlacement.Side = .below
    /// Called after the card closes itself — see `FloatingCard.onDismiss`.
    var onDismiss: (() -> Void)?

    private var card: AnyView?
    private var dismissed = false
    private var panel: NSPanel?
    private var host: NSHostingView<AnyView>?
    /// The panel frame last applied, so a re-render at the same spot doesn't re-set the frame
    /// and re-order the panel on every update.
    private var placed: CGRect?
    private var observers: [NSObjectProtocol] = []
    /// Clicks, Esc and wheel events anywhere in the app while a hover card is up: the panel
    /// ignores the mouse, so nothing else would tell it the user has moved on.
    private var monitor: Any?
    /// Where the `.above` card's nub points, as last placed.
    private var nub: CardChrome.Nub?
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
        if let monitor { NSEvent.removeMonitor(monitor) }
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
        let content = { (nub: CardChrome.Nub?) in
            AnyView(CardChrome(card: card, nub: nub, entrance: !self.interactive).padding(room).accessibilityHidden(true))
        }
        let host = self.host ?? FirstMouseHostingView(rootView: content(nub))
        host.rootView = content(nub)
        let panel = self.panel ?? makePanel(host)
        self.host = host
        self.panel = panel

        let fitting = host.fittingSize
        let size = CGSize(width: fitting.width - 2 * room, height: fitting.height - 2 * room)
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        var within = CardPlacement.bounds(window: window.frame, screen: window.screen?.visibleFrame)
        // A line's card flips by what the page shows, not the whole window: below the scroll
        // view's visible part is room nobody can see.
        if placement == .belowLine, let clip = enclosingScrollView?.contentView {
            let shown = within.intersection(window.convertToScreen(clip.convert(clip.bounds, to: nil)))
            if !shown.isNull, !shown.isEmpty { within = shown }
        }
        let gap = switch placement {
        case .above: Self.nubGap
        case .belowLine: Self.lineGap
        case .below, .trailing: Self.gap
        }
        let spot = CardPlacement.frame(for: size, anchor: anchor, within: within, gap: gap, prefersAbove: prefersAbove,
                                       side: placement, avoiding: placement == .above ? FloatingCardObstacle.frames(in: window) : [])
        // The nub never changes the card's size, so setting it after measuring is safe — and the
        // view's structure is the same with or without one, so the card's reveal isn't restarted.
        let pointing: CardChrome.Nub? = switch placement {
        case .above: CardChrome.Nub(x: CardPlacement.nubX(card: spot, anchor: anchor), pointsDown: spot.minY >= anchor.maxY)
        case .belowLine: CardChrome.Nub(x: CardPlacement.lineNubX(card: spot, anchor: anchor), pointsDown: spot.minY >= anchor.maxY)
        case .below, .trailing: nil
        }
        if pointing != nub {
            nub = pointing
            host.rootView = content(pointing)
        }
        let frame = spot.insetBy(dx: -room, dy: -room)
        guard frame != placed || panel.parent == nil else { return }
        placed = frame
        placements += 1
        panel.setFrame(frame, display: true)
        let opening = panel.parent == nil
        if opening {
            if !interactive { panel.alphaValue = 0 }
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        if opening && !interactive {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = CardReveal.fadeIn
                panel.animator().alphaValue = 1
            }
            watchEvents()
        }
    }

    /// Closes the card on a click anywhere, Esc, or a wheel event — the panel ignores the
    /// mouse, so without this a card opened by hover stayed up through a click on the slot
    /// under it. The event itself carries on to wherever it was going.
    private func watchEvents() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                              .keyDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { _ = self?.closes(on: event) }
            return event
        }
    }

    /// Whether `event` closes the open card — and if so, closes it. Only Esc among keys: Tab
    /// moving keyboard focus opens the next label's card through focus, not by closing this one.
    func closes(on event: NSEvent) -> Bool {
        guard panel != nil, event.type != .keyDown || event.keyCode == 53 else { return false }
        dismiss()
        return true
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
        onDismiss?()
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
    ///
    /// A hover card fades out: detached from its window at once (so it's gone as far as the
    /// window, and a fresh card, are concerned), then ordered out when the fade lands.
    private func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        if interactive {
            panel.orderOut(nil)
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = CardReveal.fadeOut
                panel.animator().alphaValue = 0
            }, completionHandler: { panel.orderOut(nil) })
        }
        self.panel = nil
        host = nil
        placed = nil
        nub = nil
    }
}

/// The card inside its panel: the nub pointing at the anchor (`.above` and `.belowLine`), and a hover card's
/// entrance — a slight scale-in alongside the panel's fade, none under Reduce Motion.
private struct CardChrome: View {
    struct Nub: Equatable {
        /// From the card's leading edge.
        var x: CGFloat
        /// The card is over its anchor, so the nub hangs from its bottom edge.
        var pointsDown: Bool
    }

    let card: AnyView
    let nub: Nub?
    let entrance: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = false

    var body: some View {
        card
            .overlay(alignment: nub?.pointsDown == false ? .topLeading : .bottomLeading) {
                if let nub {
                    CardNub(pointsDown: nub.pointsDown)
                        .frame(width: CardNub.width, height: CardNub.height + CardNub.tab)
                        .offset(x: nub.x - CardNub.width / 2, y: nub.pointsDown ? CardNub.height : -CardNub.height)
                }
            }
            .scaleEffect(entered || reduceMotion || !entrance ? 1 : 0.94, anchor: nub?.pointsDown == false ? .top : .bottom)
            .onAppear {
                withAnimation(.easeOut(duration: CardReveal.fadeIn)) { entered = true }
            }
    }
}

/// The small pointer from a card to the label it names, in the card's own glass: the edge
/// colour of the side it hangs from, and the card's rim along its two slanted sides. A `tab`
/// of fill reaches back into the card to paint over the rim where the two meet.
private struct CardNub: View {
    static let width: CGFloat = 14
    static let height: CGFloat = 6
    static let tab: CGFloat = 2

    let pointsDown: Bool

    var body: some View {
        let fill = pointsDown ? Color(red: 0.059, green: 0.071, blue: 0.086) : Color(red: 0.102, green: 0.118, blue: 0.145)
        Canvas { context, size in
            let w = size.width, base = pointsDown ? Self.tab : size.height - Self.tab
            let tip = pointsDown ? size.height : 0
            var shape = Path()
            shape.move(to: CGPoint(x: 0, y: base))
            shape.addLine(to: CGPoint(x: w / 2, y: tip))
            shape.addLine(to: CGPoint(x: w, y: base))
            shape.closeSubpath()
            context.fill(shape, with: .color(fill))
            context.fill(Path(CGRect(x: 0.5, y: pointsDown ? 0 : base, width: w - 1, height: Self.tab)), with: .color(fill))
            var rim = Path()
            rim.move(to: CGPoint(x: 0, y: base))
            rim.addLine(to: CGPoint(x: w / 2, y: tip))
            rim.addLine(to: CGPoint(x: w, y: base))
            context.stroke(rim, with: .color(SplitFlapCard.phosphor.opacity(0.16)), lineWidth: 1)
        }
    }
}

/// Marks a view hover cards should keep off — the pinned control bar over the board. An `.above`
/// card opens below its label instead when that side has room (`CardPlacement`'s `avoiding`).
/// A registry of live marker views, read only when a card is placed, so no card has to walk
/// the window's view tree.
struct FloatingCardObstacle: NSViewRepresentable {
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {}

    /// Every marked view's frame in `window`, in screen coordinates.
    @MainActor static func frames(in window: NSWindow) -> [CGRect] {
        Marker.live.allObjects.compactMap { marker in
            marker.window === window ? window.convertToScreen(marker.convert(marker.bounds, to: nil)) : nil
        }
    }

    final class Marker: NSView {
        @MainActor static let live = NSHashTable<Marker>.weakObjects()

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { Self.live.remove(self) } else { Self.live.add(self) }
        }
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
