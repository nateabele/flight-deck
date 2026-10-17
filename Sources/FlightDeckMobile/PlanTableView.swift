import FleetKit
import MarkdownUI
import SwiftUI

/// What the reader draws for a `.richBlock`: a Markdown table as a grid of its own, anything else
/// (a list, a quote) as MarkdownUI draws it. One place, so the plan reader and the conversation
/// timeline cannot disagree about a table.
struct RichBlockView: View {
    let text: String
    /// A plan's block: the reading serif. The conversation timeline's stays sans.
    var serif = false

    var body: some View {
        if let table = PipeTable.parse(text) {
            PlanTableView(source: text, table: table, serif: serif)
        } else {
            Markdown(text).markdownTheme(serif ? TimelineMarkdown.planTheme : TimelineMarkdown.theme)
        }
    }
}

/// A pipe table as a grid: columns sized to what is in them, cells that wrap inside their own
/// column, a semibold header with a rule under it, quiet borders.
///
/// **Why not MarkdownUI's table.** It gave every column an equal share and broke words to fit
/// them ("Surfa / ce"), so a table with a one-word column beside two sentence columns spent a
/// third of the phone's width on the one word and ran the sentences down twelve lines. The widths
/// here come from `PipeTable.fit` — the rule the Mac's plan editor lays its tables out by — so a
/// table reads the same in both places.
///
/// **Wide tables scroll sideways, and do not stack.** A table is wider than the phone only when
/// its columns' longest words cannot share the width (five or six columns); `PipeTable.fit`
/// then keeps every word whole and the grid is as wide as that takes, in a horizontal scroll
/// view. A stacked fallback (each row a card of "Header: value" lines) reads well but is a
/// different document from the one on the Mac, and every decision about a table — which
/// column is the key, where a row ends — is lost in it. A table that fits is never scrolled.
struct PlanTableView: View {
    let source: String
    let table: PipeTable
    var serif = false

    /// The width the table may take, read off the scroll view. Only the width: the grid's height
    /// is the scroll view's own, from `fixedSize`, and never fed back in.
    ///
    /// **Never measure the height and feed it back.** This was a `GeometryReader` whose
    /// content's height went out as a preference, into `@State`, and back in as `.frame(height:)`.
    /// In an ordinary frame SwiftUI settles that a frame later. Inside a layout forced
    /// synchronously, it does not settle at all: pushing a conversation whose screen held a table
    /// froze the phone until the watchdog killed it (2026-10-16, "The Plan", iOS 18.3.1, a hang
    /// in `PlanTableGridLayout` under `KeyboardOverlapReader.HostView.didMoveToWindow`, whose
    /// first read of `keyboardLayoutGuide` lays the whole window out mid-push). The width cannot
    /// loop: what the table holds does not change how wide its row is.
    @State private var width: CGFloat = 0

    var body: some View {
        let rows = Self.cells(source, table)
        ScrollView(.horizontal, showsIndicators: false) {
            PlanTableGridLayout(columns: table.columnCount, available: width) {
                ForEach(rows.indices, id: \.self) { r in
                    ForEach(0..<table.columnCount, id: \.self) { c in
                        PlanTableCell(text: rows[r][c], header: r == 0, serif: serif, alignment: table.alignments[c],
                                      lastColumn: c == table.columnCount - 1, lastRow: r == rows.count - 1)
                        PlanTableCell(text: Self.longestWord(rows[r][c]), header: r == 0, serif: serif, alignment: .left,
                                      lastColumn: true, lastRow: true)
                            .layoutValue(key: PlanTableProbeKey.self, value: true)
                            .hidden().accessibilityHidden(true)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(PlanTableStyle.line, lineWidth: 0.5))
        }
        // As tall as the grid: a scroll view would otherwise take every point it is offered.
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// The table's cells as drawn: row by row, the delimiter row left out, short rows filled.
    static func cells(_ source: String, _ table: PipeTable) -> [[AttributedString]] {
        let ns = source as NSString
        return table.rows.enumerated().filter { $0.offset != PipeTable.delimiterRow }.map { _, row in
            (0..<table.columnCount).map { c in c < row.cells.count ? attributed(ns.substring(with: row.cells[c])) : AttributedString() }
        }
    }

    /// The widest word of a cell, with the cell's own styling: what the cell measures as when it
    /// is as narrow as it can be without breaking a word. SwiftUI's `Text` has no such width —
    /// proposed none, it breaks inside words — so the layout measures this instead.
    static func longestWord(_ text: AttributedString) -> AttributedString {
        var best = text[text.startIndex..<text.startIndex]
        var start = text.startIndex
        var index = text.startIndex
        while index <= text.endIndex {
            if index == text.endIndex || text.characters[index].isWhitespace {
                let word = text[start..<index]
                if word.characters.count > best.characters.count { best = word }
                if index == text.endIndex { break }
                start = text.characters.index(after: index)
            }
            if index == text.endIndex { break }
            index = text.characters.index(after: index)
        }
        return AttributedString(best)
    }

    /// A cell's inline Markdown — bold, italic, `code`, links, an escaped pipe — in the reader's
    /// own look for code (`TimelineMarkdown`'s tint and wash), so a span reads the same in a cell
    /// as in a paragraph.
    static func attributed(_ markdown: String) -> AttributedString {
        var text = (try? AttributedString(markdown: markdown, options: .init(
            allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(PipeTable.display(markdown))
        let code = text.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }.map(\.range)
        for range in code {
            text[range].font = .system(.subheadline, design: .monospaced)
            text[range].foregroundColor = TimelineMarkdown.codeTint
            text[range].backgroundColor = TimelineMarkdown.codeWash
        }
        return text
    }
}

enum PlanTableStyle {
    static let line = Color(.separator)
    static let headerRule = Color(.opaqueSeparator)
    static let headerWash = Color.primary.opacity(0.06)
    static let padding = CGSize(width: 10, height: 7)
}

/// Marks the hidden copy of a cell the layout measures for the cell's longest word.
private struct PlanTableProbeKey: LayoutValueKey {
    static let defaultValue = false
}

private struct PlanTableCell: View {
    let text: AttributedString
    let header: Bool
    let serif: Bool
    let alignment: PipeTable.Alignment
    let lastColumn: Bool
    let lastRow: Bool

    var body: some View {
        Text(text)
            .font(.system(.subheadline, design: serif ? .serif : .default))
            .lineSpacing(serif ? 3 : 0)
            .fontWeight(header ? .semibold : nil)
            .multilineTextAlignment(alignment == .center ? .center : alignment == .right ? .trailing : .leading)
            .textSelection(.enabled)
            .padding(.horizontal, PlanTableStyle.padding.width)
            .padding(.vertical, PlanTableStyle.padding.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment == .center ? .top : alignment == .right ? .topTrailing : .topLeading)
            .background(header ? PlanTableStyle.headerWash : .clear)
            .overlay(alignment: .trailing) {
                if !lastColumn { Rectangle().fill(PlanTableStyle.line).frame(width: 0.5) }
            }
            .overlay(alignment: .bottom) {
                if !lastRow { Rectangle().fill(header ? PlanTableStyle.headerRule : PlanTableStyle.line).frame(height: header ? 1 : 0.5) }
            }
    }
}

/// Lays the cells (row by row, `columns` to a row) out in columns of `PipeTable.fit`'s widths,
/// each row as tall as its tallest cell. `available` is the width the table may take; the layout
/// is wider than that only when the words will not fit, and the scroll view around it takes over.
/// Cell padding is part of each cell, so what is measured is what is drawn.
struct PlanTableGridLayout: Layout {
    let columns: Int
    let available: CGFloat

    struct Cache {
        var widths: [CGFloat] = []
        var heights: [CGFloat] = []
        var overflows = false
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    private func measure(_ subviews: Subviews, _ cache: inout Cache) {
        guard cache.widths.isEmpty, columns > 0, !subviews.isEmpty else { return }
        // Each cell is followed by its probe (`PlanTableView.longestWord`): the cells are the even ones.
        let cells = subviews.filter { !$0[PlanTableProbeKey.self] }
        let probes = subviews.filter { $0[PlanTableProbeKey.self] }
        var natural = [Double](repeating: 0, count: columns)
        var longest = [Double](repeating: 0, count: columns)
        for (i, view) in cells.enumerated() {
            let c = i % columns
            natural[c] = max(natural[c], view.sizeThatFits(.unspecified).width)
            if i < probes.count { longest[c] = max(longest[c], probes[i].sizeThatFits(.unspecified).width) }
        }
        let fit = PipeTable.fit(natural: natural, longestWord: longest, available: max(available, 1), padding: 0,
                                minimumContent: 44, breakWords: false)
        cache.widths = fit.widths.map { CGFloat($0) }
        cache.overflows = fit.overflows
        cache.heights = stride(from: 0, to: cells.count, by: columns).map { start in
            (start..<min(start + columns, cells.count)).map { i in
                cells[i].sizeThatFits(ProposedViewSize(width: cache.widths[i - start], height: nil)).height
            }.max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        measure(subviews, &cache)
        return CGSize(width: cache.widths.reduce(0, +), height: cache.heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        measure(subviews, &cache)
        let cells = subviews.filter { !$0[PlanTableProbeKey.self] }
        var y = bounds.minY
        for (r, height) in cache.heights.enumerated() {
            var x = bounds.minX
            for c in 0..<columns where r * columns + c < cells.count {
                cells[r * columns + c].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                             proposal: ProposedViewSize(width: cache.widths[c], height: height))
                x += cache.widths[c]
            }
            y += height
        }
        for probe in subviews where probe[PlanTableProbeKey.self] {
            probe.place(at: bounds.origin, anchor: .topLeading, proposal: .zero)
        }
    }
}
