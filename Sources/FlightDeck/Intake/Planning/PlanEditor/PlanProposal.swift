import AppKit
import SwiftUI

/// A proposed edit drawn in place of the paragraph it would change (D17, option B): the block's
/// source is hidden and held to the proposed text's height, and `EditLayerFragment` draws the
/// proposed words in the plan's own typography — the same trick as a table's grid
/// (`PlanTableRowRef`), at paragraph level. The plan's bytes are as typed; the proposal is drawing.
struct PlanProposal: Equatable {
    let diff: UUID
    /// The block it stands in for, in the text's coordinates.
    let block: NSRange
    /// The block with the diff applied: what is drawn.
    let source: String
    /// The block as it is now: what the pointer shows struck through above it.
    let old: String
    /// The pointer is on it: the room for the old text and the toolbar is open above.
    var hovered = false

    /// `proposals` after one character edit: a block the edit is above moves with the text, one
    /// the edit is inside is dropped (its source shows, the caret being there, and the refresh
    /// lays the proposal again). Done in the same pass as the restyle, so typing above a proposal
    /// does not flash it back to source for a run-loop turn.
    static func moved(_ proposals: [PlanProposal], by edit: TextEdit) -> [PlanProposal] {
        proposals.compactMap { p in
            edit.shift(p.block).map { PlanProposal(diff: p.diff, block: $0, source: p.source, old: p.old, hovered: p.hovered) }
        }
    }

    /// The same after a pass of several character edits, in the order the storage reported them
    /// (each range is in the text after its own edit, so they compose in turn).
    static func moved(_ proposals: [PlanProposal], by edits: [TextEdit]) -> [PlanProposal] {
        edits.reduce(proposals) { moved($0, by: $1) }
    }
}

/// The proposed block and the old one, each laid out on a scratch text system with the plan's
/// theme at the editor's width — so the height the styler reserves is the height the drawing
/// takes, which is what a table's `PlanTableLayout.cached` does for its rows.
final class PlanProposalLayout: NSObject {
    /// Room above the old text for the hover toolbar.
    static let toolbarRow: CGFloat = 30
    /// Between the struck old text and the new.
    static let gap: CGFloat = 4

    private let proposed: Stack
    private let old: Stack
    let width: CGFloat

    /// One styled text on its own TextKit 1 stack: TextKit 1 because it answers a text's height and
    /// last line synchronously and draws glyphs at a given origin, which is all this needs.
    private final class Stack {
        let storage: NSTextStorage
        let manager = NSLayoutManager()
        let container: NSTextContainer
        let height: CGFloat
        let lastLine: CGRect

        init(source: String, theme: PlanTheme, width: CGFloat, struck: Bool) {
            let text = NSTextStorage(string: source)
            let box = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
            box.lineFragmentPadding = 0
            manager.addTextContainer(box)
            text.addLayoutManager(manager)
            MarkdownStyler.apply(to: text, blocks: MarkdownStyler.blocks(source), revealBlock: nil, theme: theme)
            if struck {
                // Over the visible runs only: the hidden syntax is clear, and a colour on it would show.
                text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                    if let color = value as? NSColor, color == .clear { return }
                    text.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                        .strikethroughColor: NSColor.systemRed.withAlphaComponent(0.6),
                                        .foregroundColor: NSColor.systemRed.withAlphaComponent(0.85)], range: range)
                }
            }
            manager.ensureLayout(for: box)
            let used = manager.usedRect(for: box)
            // The last line's own rect, for the ✦ after it.
            let glyphs = manager.numberOfGlyphs
            storage = text
            container = box
            lastLine = glyphs > 0 ? manager.lineFragmentUsedRect(forGlyphAt: glyphs - 1, effectiveRange: nil) : .zero
            height = ceil(used.height)
        }

        func draw(at origin: CGPoint) {
            let glyphs = manager.glyphRange(for: container)
            manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        }
    }

    init(source: String, old oldSource: String, theme: PlanTheme, width: CGFloat) {
        self.width = width
        proposed = Stack(source: source, theme: theme, width: width, struck: false)
        old = Stack(source: oldSource, theme: theme, width: width, struck: true)
    }

    /// The proposed text's height alone, at rest.
    var restHeight: CGFloat { proposed.height }
    /// With the toolbar row and the struck old text above it, under the pointer.
    var hoverHeight: CGFloat { Self.toolbarRow + old.height + Self.gap + proposed.height }

    func height(hovered: Bool) -> CGFloat { hovered ? hoverHeight : restHeight }

    /// Draws the proposed text with its top-left at `origin`, and the old text above it when hovered.
    /// Returns where the proposed text ended its last line, from `origin`, for the ✦ and the bar.
    @discardableResult
    func draw(at origin: CGPoint, hovered: Bool, context: CGContext) -> (bar: ClosedRange<CGFloat>, spark: CGPoint) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        var top = origin.y
        if hovered {
            old.draw(at: CGPoint(x: origin.x, y: top + Self.toolbarRow))
            top += Self.toolbarRow + old.height + Self.gap
        }
        proposed.draw(at: CGPoint(x: origin.x, y: top))
        return (top...(top + proposed.height), CGPoint(x: origin.x + proposed.lastLine.maxX + 3, y: top + proposed.lastLine.minY))
    }

    private static let cache: NSCache<NSString, PlanProposalLayout> = {
        let cache = NSCache<NSString, PlanProposalLayout>()
        cache.countLimit = 32
        return cache
    }()

    /// Width, the body face (family and size, as `PlanTableLayout.cached` keys its own) and both
    /// texts: a layout made for another type size must not answer for this one.
    static func cacheKey(source: String, old: String, theme: PlanTheme, width: CGFloat) -> String {
        "\(Int(width.rounded()))|\(theme.body.familyName ?? theme.body.fontName)|\(theme.body.pointSize)|\(source)|\(old)"
    }

    static func cached(source: String, old: String, theme: PlanTheme, width: CGFloat) -> PlanProposalLayout {
        let key = cacheKey(source: source, old: old, theme: theme, width: width) as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let made = PlanProposalLayout(source: source, old: old, theme: theme, width: width)
        cache.setObject(made, forKey: key)
        return made
    }
}

/// A source line's place in its block's proposal — the value of `.planProposal`. Only the block's
/// first line (`lead`) draws; the rest are held to no height at all.
final class PlanProposalRef: NSObject {
    let layout: PlanProposalLayout
    let lead: Bool
    let hovered: Bool

    init(layout: PlanProposalLayout, lead: Bool, hovered: Bool) {
        self.layout = layout
        self.lead = lead
        self.hovered = hovered
    }
}

extension NSAttributedString.Key {
    /// A paragraph or list item while a proposed edit is drawn in its place (`PlanProposalRef`).
    static let planProposal = NSAttributedString.Key("FlightDeck.planProposal")
}

extension MarkdownStyler {
    /// The block's source hidden and held to the proposal's height: its first line takes all of
    /// it, every other line almost none, and the last keeps the block's paragraph spacing.
    static func styleProposal(_ storage: NSTextStorage, _ block: MarkdownBlock, whole: NSRange, proposal: PlanProposal,
                              _ theme: PlanTheme) {
        let width = theme.contentWidth > 0 ? theme.contentWidth : 600
        let layout = PlanProposalLayout.cached(source: proposal.source, old: proposal.old, theme: theme, width: width)
        let spacing = theme.paragraphStyle(for: block.kind).paragraphSpacing
        let ns = storage.mutableString
        var lines: [NSRange] = []
        var at = whole.location
        while at < NSMaxRange(whole) {
            let line = ns.lineRange(for: NSRange(location: at, length: 0))
            lines.append(NSIntersectionRange(line, whole))
            at = NSMaxRange(line)
        }
        storage.removeAttribute(.backgroundColor, range: whole)
        storage.removeAttribute(.link, range: whole)
        for (i, line) in lines.enumerated() {
            let style = NSMutableParagraphStyle()
            let height = i == 0 ? layout.height(hovered: proposal.hovered) : 0.001
            style.minimumLineHeight = height
            style.maximumLineHeight = height
            if i == lines.count - 1 { style.paragraphSpacing = spacing }
            storage.addAttributes([.font: theme.hidden, .foregroundColor: NSColor.clear, .paragraphStyle: style,
                                   .planProposal: PlanProposalRef(layout: layout, lead: i == 0, hovered: proposal.hovered)],
                                  range: line)
        }
    }
}
