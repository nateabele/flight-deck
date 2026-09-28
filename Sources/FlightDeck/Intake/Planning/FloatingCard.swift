import AppKit
import SwiftUI

/// Where a label's card goes, in AppKit screen coordinates (y up): under the label with leading
/// edges aligned, flipped above it when the window's bottom edge leaves no room below, and slid
/// back inside the window's sides. Pure, so `CardPlacementTests` pins the flip without a window.
enum CardPlacement {
    static func frame(for card: CGSize, anchor: CGRect, within bounds: CGRect, gap: CGFloat) -> CGRect {
        let below = anchor.minY - gap - card.height
        let above = anchor.maxY + gap
        // Below is the reading direction; flip only when that runs off the bottom AND above fits,
        // so a squat window doesn't trade one clipped card for a card covering its own row.
        let y = below < bounds.minY && above + card.height <= bounds.maxY ? above : below
        let x = min(max(anchor.minX, bounds.minX), max(bounds.minX, bounds.maxX - card.width))
        return CGRect(x: x, y: y, width: card.width, height: card.height)
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
/// ourselves — `CardPlacement`.
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
final class FloatingCardAnchor: NSView {
    /// Transparent margin around the card inside the panel, so `SplitFlapCard`'s own shadow
    /// (radius 17, offset 14) isn't cut off at the panel's edge.
    private static let shadowRoom: CGFloat = 34
    private static let gap: CGFloat = 9

    private var card: AnyView?
    private var panel: NSPanel?
    private var host: NSHostingView<AnyView>?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func present(_ card: AnyView?) {
        self.card = card
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

    private func place() {
        guard let card, let window else { return close() }
        let room = Self.shadowRoom
        let content = AnyView(card.padding(room).accessibilityHidden(true))
        let host = self.host ?? NSHostingView(rootView: content)
        host.rootView = content
        let panel = self.panel ?? makePanel(host)
        self.host = host
        self.panel = panel

        let fitting = host.fittingSize
        let size = CGSize(width: fitting.width - 2 * room, height: fitting.height - 2 * room)
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let frame = CardPlacement.frame(for: size, anchor: anchor, within: window.frame, gap: Self.gap)
        panel.setFrame(frame.insetBy(dx: -room, dy: -room), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    private func makePanel(_ host: NSHostingView<AnyView>) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false        // the card draws its own
        panel.ignoresMouseEvents = true
        host.wantsLayer = true
        panel.contentView = host
        return panel
    }

    private func close() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}
