import AppKit
import IntakeKit

/// What the styler leaves on a visual block's hidden source lines (`.planVisual`): which visual,
/// its caption, and the height the lines were held to. One object per block, on every line of it,
/// so the block's lines read back as one run.
final class PlanVisualRef: NSObject {
    let id: String
    let pending: Bool
    let caption: String
    let height: CGFloat
    init(id: String, pending: Bool, caption: String, height: CGFloat) {
        self.id = id; self.pending = pending; self.caption = caption; self.height = height
    }
}

extension NSAttributedString.Key {
    /// A visual block's hidden source (`PlanVisualRef`): `VisualBlockOverlay` lays a
    /// `VisualBlockView` over exactly these lines.
    static let planVisual = NSAttributedString.Key("FlightDeck.planVisual")
}

/// Lays a `VisualBlockView` over each visual block in the plan (V-R1, the table pattern).
///
/// The editor has no attachments, so a block is text like any other: the styler hides its source
/// and holds its lines to the block's fixed height (`MarkdownStyler.styleVisual`), and this puts
/// a view in exactly that band, found the way `PlanTableController.bandOrigin` finds a table row.
///
/// **It never paints over text** (Review Focus 2). The view's frame is the band the hidden lines
/// occupy, read back from TextKit after every restyle, scroll and layout pass, never cached
/// across an edit; a block whose lines are not hidden (the caret is in it, so its source shows,
/// or its fence was deleted, or it was never closed) has no `.planVisual` and so no view — the
/// view goes the moment the source shows.
///
/// It also decides which blocks hold a live web view: one on screen asks `VisualLivePool` for
/// one, one that leaves the screen gives it back and shows its picture.
@MainActor
final class VisualBlockOverlay {
    unowned let view: PlanNSTextView

    /// The intake's visuals; nil makes every block a "missing visual" placeholder.
    var store: (any VisualStoreReading)? {
        didSet {
            let identity = store.map(VisualStoreIdentity.of)
            guard identity != storeIdentity else { return }
            storeIdentity = identity
            reload()
        }
    }
    private var storeIdentity: String?
    /// The plan checkpoint shown, for the block states it recorded (spec §7).
    var checkpoint: Int? { didSet { if checkpoint != oldValue { reload() } } }
    /// Off, no block goes live and every block shows its picture: a render's, since a web view's
    /// content is not in its layer and would draw blank.
    var allowsLive = true
    /// Make a block's alternate its primary — see `VisualBlockView.onMakePrimary`. Nil (as in
    /// P2a, where nothing here may write `block.json`) leaves "Make primary" disabled.
    var onMakePrimary: ((String, Int) -> Void)? {
        didSet {
            for (key, block) in blocks {
                let id = String(key[..<(key.lastIndex(of: "#") ?? key.endIndex)])
                block.onMakePrimary = onMakePrimary.map { action in { r in action(id, r) } }
            }
        }
    }

    private var models: [String: VisualBlockModel] = [:]
    /// The views, by `<id>#<n>` (the n-th block of that id in the plan), so typing that moves a
    /// block keeps its view and its live web view.
    private(set) var blocks: [String: VisualBlockView] = [:]
    private var onScreen: Set<ObjectIdentifier> = []
    private var refreshQueued = false

    init(view: PlanNSTextView) { self.view = view }

    // MARK: - Models

    func model(id: String, pending: Bool) -> VisualBlockModel {
        let key = "\(id)|\(pending)"
        if let model = models[key] { return model }
        let model = VisualBlockModel.load(id: id, pending: pending, store: store, checkpoint: checkpoint)
        models[key] = model
        return model
    }

    /// The height the styler holds a block's lines to.
    func height(id: String, pending: Bool) -> CGFloat {
        VisualBlockLayout.height(for: model(id: id, pending: pending))
    }

    /// Forget what was read: a new plan was loaded, or the store changed.
    func reload() { models = [:] }

    // MARK: - Placing

    struct Placement: Equatable {
        let key: String
        /// The hidden source, in the text.
        let range: NSRange
        /// Where the view goes, in the text view's coordinates.
        let band: CGRect
    }

    /// Every visual block's hidden source and band, in text order.
    func placements() -> [Placement] {
        guard let storage = view.textStorage, storage.length > 0 else { return [] }
        var out: [Placement] = []
        var counts: [String: Int] = [:]
        storage.enumerateAttribute(.planVisual, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let ref = value as? PlanVisualRef else { return }
            let n = counts[ref.id, default: 0]
            counts[ref.id] = n + 1
            guard let band = band(for: range) else { return }
            out.append(Placement(key: "\(ref.id)#\(n)", range: range, band: band))
        }
        return out
    }

    /// The band `range`'s laid-out lines occupy: from the first line's top to the last line's
    /// bottom, without the spacing kept above and below the block. Nil when its lines are not
    /// laid out as the block's (a folded section hides them).
    func band(for range: NSRange) -> CGRect? {
        guard range.length > 0, let layout = view.textLayoutManager, let content = layout.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(content.documentRange.location, offsetBy: NSMaxRange(range) - 1) else { return nil }
        if let whole = NSTextRange(location: start, end: content.location(end, offsetBy: 1) ?? end) { layout.ensureLayout(for: whole) }
        guard let first = layout.textLayoutFragment(for: start), let last = layout.textLayoutFragment(for: end),
              Self.isVisual(first), Self.isVisual(last) else { return nil }
        let top = first.layoutFragmentFrame.minY + (first.textLineFragments.first?.typographicBounds.minY ?? 0)
        let bottom = last.layoutFragmentFrame.minY + (last.textLineFragments.last?.typographicBounds.maxY ?? last.layoutFragmentFrame.height)
        let origin = view.textContainerOrigin
        let padding = view.textContainer?.lineFragmentPadding ?? 0
        let width = (view.textContainer?.size.width ?? view.bounds.width) - 2 * padding
        return CGRect(x: origin.x + padding, y: origin.y + top, width: max(0, width), height: max(0, bottom - top))
    }

    private static func isVisual(_ fragment: NSTextLayoutFragment) -> Bool {
        guard let paragraph = (fragment.textElement as? NSTextParagraph)?.attributedString, paragraph.length > 0 else { return false }
        return paragraph.attribute(.planVisual, at: 0, effectiveRange: nil) is PlanVisualRef
    }

    /// On the next turn of the run loop, once, however many scroll ticks and layout passes ask.
    func setNeedsRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshQueued = false
                self?.refresh()
            }
        }
    }

    /// Puts every block's view in its band now, removes the views of blocks that are gone or
    /// whose source shows, and settles which blocks are live.
    func refresh() {
        guard let storage = view.textStorage else { return }
        var seen = Set<String>()
        var counts: [String: Int] = [:]
        storage.enumerateAttribute(.planVisual, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let ref = value as? PlanVisualRef else { return }
            let n = counts[ref.id, default: 0]
            counts[ref.id] = n + 1
            let key = "\(ref.id)#\(n)"
            guard let band = band(for: range) else { return }
            seen.insert(key)
            let model = model(id: ref.id, pending: ref.pending)
            let block: VisualBlockView
            if let existing = blocks[key] {
                block = existing
                block.store = store
                block.update(model: model, caption: ref.caption)
            } else {
                block = VisualBlockView(model: model, caption: ref.caption, store: store)
                block.onNeedsLive = { [weak self] block in
                    self?.onScreen.remove(ObjectIdentifier(block))
                    self?.updateLiveness()
                }
                block.onMakePrimary = onMakePrimary.map { action in { r in action(ref.id, r) } }
                view.addSubview(block)
                blocks[key] = block
            }
            if block.frame != band { block.frame = band }
        }
        for (key, block) in blocks where !seen.contains(key) {
            block.goSnapshot()
            block.removeFromSuperview()
            onScreen.remove(ObjectIdentifier(block))
            blocks[key] = nil
        }
        updateLiveness()
    }

    /// Blocks on screen go live (at most `VisualLivePool.limit` across the app), blocks off it go
    /// back to their pictures, and blocks near the screen draw their pictures.
    func updateLiveness() {
        let visible = view.visibleRect
        let near = visible.insetBy(dx: 0, dy: -max(visible.height, 400))
        for block in blocks.values {
            let id = ObjectIdentifier(block)
            let shown = !visible.isEmpty && block.frame.intersects(visible) && view.window != nil
            let wasShown = onScreen.contains(id)
            if shown { onScreen.insert(id) } else { onScreen.remove(id) }
            block.setWantsPictures(!visible.isEmpty && block.frame.intersects(near))
            guard !block.model.representations.isEmpty else { continue }
            if shown, allowsLive, !block.isLive, !block.comparing {
                // A block that was already on screen and lost its web view to a newer one waits
                // for a free slot, rather than taking one back and starting a tug of war.
                if VisualLivePool.shared.hasRoom || !wasShown { VisualLivePool.shared.grant(block) }
            } else if shown, block.isLive {
                VisualLivePool.shared.touch(block)
            } else if !shown, block.isLive {
                block.goSnapshot()
            }
        }
    }

    /// Every view goes back to its picture and leaves the text view (the editor is going away).
    func tearDown() {
        for block in blocks.values { block.goSnapshot(); block.removeFromSuperview() }
        blocks = [:]
        onScreen = []
    }
}

/// The live web views every plan's blocks share: at most `limit` at once, the least recently
/// used going back to its picture when another block needs one (spec §8). A plan with many
/// visuals never runs many web content processes.
@MainActor
final class VisualLivePool {
    static let limit = 3
    static let shared = VisualLivePool()

    private var budget = VisualLiveBudget<ObjectIdentifier>(limit: VisualLivePool.limit)
    private var views: [ObjectIdentifier: WeakBlock] = [:]

    private struct WeakBlock { weak var block: VisualBlockView? }

    var hasRoom: Bool { prune(); return budget.hasRoom }
    var liveCount: Int { prune(); return budget.live.count }

    /// `block` goes live; the least recently used block goes back to its picture if the pool was full.
    func grant(_ block: VisualBlockView) {
        prune()
        let id = ObjectIdentifier(block)
        let evicted = budget.use(id)
        views[id] = WeakBlock(block: block)
        if let evicted, let other = views[evicted]?.block {
            other.goSnapshot()
        }
        block.goLive()
    }

    /// Marks a live block as just used; a block that is not live is left alone.
    func touch(_ block: VisualBlockView) {
        let id = ObjectIdentifier(block)
        if budget.isLive(id) { budget.use(id) }
    }

    func release(_ block: VisualBlockView) {
        let id = ObjectIdentifier(block)
        budget.release(id)
        views[id] = nil
    }

    /// A block freed without giving its slot back (its editor went away) holds nothing.
    private func prune() {
        for id in budget.live where views[id]?.block == nil {
            budget.release(id)
            views[id] = nil
        }
    }
}
