import AppKit
import IntakeKit

/// One piece of the human's edits as the editor draws it (spec §7.2), in UTF-16 offsets of the
/// EDITED text — the text the editor holds.
///
/// - `.inserted`: `range` is the characters the human added (a whole inserted line includes
///   its newline, so an inserted blank line still gets its gutter bar).
/// - `.deleted`: `range` is zero-length, where the removed text used to be; `ghost` is that
///   text, drawn struck through but never stored. `inline` ghosts sit inside a line (the
///   words a one-line change removed); the rest are whole lines drawn above the line that now
///   follows them (below the last line, at the end of the plan).
struct EditMark: Equatable {
    enum Kind { case inserted, deleted }
    let kind: Kind
    let range: NSRange
    /// Index into the hunks `EditLayer.marks` returned with it — what Revert puts back.
    let hunk: Int
    var ghost = ""
    var inline = false
}

/// The amber banner's content: "Your edits to Refine 2 conflicted with this round · Open Refine 2".
struct EditConflictNotice: Equatable {
    let title: String
    let openLabel: String
    /// The checkpoint still holding the edits — what "Open" selects.
    let open: Int
}

/// The human's edits as a layer over the agents' plan (spec §7.2): what to mark, the header
/// chip, the conflict banner, carrying an edit onto a newer head, and the attributes the
/// editor draws the marks with. Everything but `apply` is pure over strings.
enum EditLayer {
    /// Shown once per plan the first time it carries edits — see `IntakeService.editNoteShown`.
    static let keptNote = "Your edits are kept; the next round treats them as fixed."

    /// The chip's Revert all confirmation: "Revert all 3 edits?", "Revert your edit?".
    static func revertAllPrompt(_ edits: Int) -> String {
        edits == 1 ? "Revert your edit?" : "Revert all \(edits) edits?"
    }

    // MARK: - Marks

    /// The edits in `edited` over `generated`, as marks plus the hunks they came from.
    ///
    /// A hunk's lines are paired old-to-new by similarity before marking: a one-line change
    /// marks only the words that changed ("Unassigned ~~for 24 hours~~ until a dispatcher
    /// assigns it"), where marking the whole line twice would bury a two-word edit. Unpaired
    /// old lines become whole-line ghosts; unpaired new lines, whole-line insertions.
    static func marks(generated: String, edited: String) -> (marks: [EditMark], hunks: [PlanHunk]) {
        let diff = LineWindowDiff(generated: generated, edited: edited)
        let hunks = diff.hunks
        guard !hunks.isEmpty else { return ([], []) }
        /// Where line `j` of the edited text begins; the end of the text past its last line —
        /// a ghost there is drawn below the plan's last line.
        let start = diff.lineStart

        var out: [EditMark] = []
        for (h, hunk) in hunks.enumerated() {
            var ghost: [String] = []
            var run: (from: Int, to: Int)?
            func flushRun() {
                guard let r = run else { return }
                out.append(EditMark(kind: .inserted, range: NSRange(location: start(r.from), length: start(r.to + 1) - start(r.from)), hunk: h))
                run = nil
            }
            func flushGhost(at line: Int) {
                guard !ghost.isEmpty else { return }
                out.append(EditMark(kind: .deleted, range: NSRange(location: start(hunk.newStart + line), length: 0), hunk: h,
                                    ghost: ghost.joined(separator: "\n")))
                ghost = []
            }
            for op in align(hunk.oldLines, hunk.newLines) {
                switch op {
                case .delete(let i):
                    flushRun()
                    ghost.append(hunk.oldLines[i])
                case .insert(let j):
                    flushGhost(at: j)
                    let line = hunk.newStart + j
                    if let r = run, r.to == line - 1 { run = (r.from, line) } else { flushRun(); run = (line, line) }
                case .pair(let i, let j):
                    flushRun()
                    flushGhost(at: j)
                    out += inlineMarks(old: hunk.oldLines[i], new: hunk.newLines[j], lineStart: start(hunk.newStart + j), hunk: h)
                }
            }
            flushRun()
            flushGhost(at: hunk.newLines.count)
        }
        return (out, hunks)
    }

    /// The characters each hunk covers in the edited text — its lines, or for a pure deletion
    /// the line its ghost is drawn on. Hovering there offers that hunk's Revert.
    static func spans(_ hunks: [PlanHunk], edited: String) -> [NSRange] {
        let starts = lineStarts(edited)
        let length = (edited as NSString).length
        func start(_ j: Int) -> Int { j < starts.count ? starts[j] : length }
        return hunks.map { hunk in
            let first = hunk.newLines.isEmpty ? min(hunk.newStart, max(starts.count - 1, 0)) : hunk.newStart
            let last = hunk.newLines.isEmpty ? first : hunk.newStart + hunk.newLines.count - 1
            return NSRange(location: start(first), length: max(start(last + 1) - start(first), 0))
        }
    }

    /// UTF-16 offset of every line's first character, split on LF only — the rule
    /// `PlanLayers` diffs by (a CR before the LF stays part of its line).
    private static func lineStarts(_ text: String) -> [Int] {
        // Over a UTF-16 copy: iterating `utf16` of the editor's (NSString-backed) text went
        // through the bridge a character at a time.
        let ns = text as NSString
        var units = [unichar](repeating: 0, count: ns.length)
        units.withUnsafeMutableBufferPointer { if let base = $0.baseAddress { ns.getCharacters(base, range: NSRange(location: 0, length: ns.length)) } }
        var starts = [0]
        units.withUnsafeBufferPointer { u in
            var i = 0
            while i < u.count {
                if u[i] == 10 { starts.append(i + 1) }
                i += 1
            }
        }
        return starts
    }

    private enum Op { case delete(Int), insert(Int), pair(Int, Int) }

    /// Lines of one hunk paired in order by similarity (a weighted LCS). Above `pairLimit`
    /// cells a big paste is simply its lines: a pairing nobody could read anyway is not worth
    /// a keystroke's frame.
    private static func align(_ old: [String], _ new: [String]) -> [Op] {
        let pairLimit = 400
        guard !old.isEmpty, !new.isEmpty, old.count * new.count <= pairLimit else {
            return old.indices.map { .delete($0) } + new.indices.map { .insert($0) }
        }
        let a = old.map(Array.init), b = new.map(Array.init)
        var weight = Array(repeating: Array(repeating: 0.0, count: b.count), count: a.count)
        for i in a.indices { for j in b.indices { weight[i][j] = similarity(a[i], b[j]) } }
        var best = Array(repeating: Array(repeating: 0.0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                var v = max(best[i - 1][j], best[i][j - 1])
                if weight[i - 1][j - 1] > 0 { v = max(v, best[i - 1][j - 1] + weight[i - 1][j - 1]) }
                best[i][j] = v
            }
        }
        var ops: [Op] = []
        var i = a.count, j = b.count
        while i > 0 || j > 0 {
            if i > 0, j > 0, weight[i - 1][j - 1] > 0, best[i][j] == best[i - 1][j - 1] + weight[i - 1][j - 1] {
                ops.append(.pair(i - 1, j - 1)); i -= 1; j -= 1
            } else if j > 0, i == 0 || best[i][j] == best[i][j - 1] {
                ops.append(.insert(j - 1)); j -= 1
            } else {
                ops.append(.delete(i - 1)); i -= 1
            }
        }
        // Deletions before insertions at the same point, so a replaced line reads old then new.
        return ops.reversed()
    }

    /// The share of the longer line the two have in common at their ends; 0 below the point
    /// where marking inside the line would read as noise ("- " alone doesn't make two list
    /// items the same line).
    private static func similarity(_ a: [Character], _ b: [Character]) -> Double {
        let (p, s) = commonEnds(a, b)
        let score = Double(p + s) / Double(max(a.count, b.count, 1))
        return score >= 0.3 ? score : 0
    }

    private static func commonEnds(_ a: [Character], _ b: [Character]) -> (prefix: Int, suffix: Int) {
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        return (p, s)
    }

    /// The words a one-line change removed and added. The common ends are cut back to word
    /// boundaries, so "cat" → "car" marks the word, not a lone "t" → "r".
    private static func inlineMarks(old: String, new: String, lineStart: Int, hunk: Int) -> [EditMark] {
        let a = Array(old), b = Array(new)
        var (p, s) = commonEnds(a, b)
        func word(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        while p > 0, word(a[p - 1]), (p < a.count && word(a[p])) || (p < b.count && word(b[p])) { p -= 1 }
        while s > 0, word(a[a.count - s]),
              (a.count - s - 1 >= p && word(a[a.count - s - 1])) || (b.count - s - 1 >= p && word(b[b.count - s - 1])) { s -= 1 }
        let removed = String(a[p..<(a.count - s)])
        let added = String(b[p..<(b.count - s)])
        let at = lineStart + String(b[..<p]).utf16.count
        var out: [EditMark] = []
        if !removed.isEmpty { out.append(EditMark(kind: .deleted, range: NSRange(location: at, length: 0), hunk: hunk, ghost: removed, inline: true)) }
        if !added.isEmpty { out.append(EditMark(kind: .inserted, range: NSRange(location: at, length: added.utf16.count), hunk: hunk)) }
        return out
    }

    // MARK: - Chip and banner

    /// "3 edits by you" — the header chip's count, before its "· Revert all"; nil hides it.
    static func chip(_ hunks: [PlanHunk]) -> String? {
        guard !hunks.isEmpty else { return nil }
        return "\(hunks.count) edit\(hunks.count == 1 ? "" : "s") by you"
    }

    /// "Your edits to Refine 2 conflicted with this round", for the newest of `c`.
    static func conflictBanner(_ c: [EditConflict], names: (Int) -> String) -> String? {
        guard let last = c.last else { return nil }
        return "Your edits to \(names(last.edits)) conflicted with this round"
    }

    /// The banner for the plan head `head`: only a conflict that landed IN the head is news —
    /// once another round lands over it, the edits' checkpoint is history the human can still
    /// open from the tape.
    static func conflictNotice(_ c: [EditConflict], head: Int?, names: (Int) -> String) -> EditConflictNotice? {
        let current = c.filter { $0.landedIn == head }
        guard let last = current.last, let title = conflictBanner(current, names: names) else { return nil }
        return EditConflictNotice(title: title, openLabel: "Open \(names(last.edits))", open: last.edits)
    }

    // MARK: - Re-targeting a stale edit

    /// What to send for an edit committed after its checkpoint stopped being the plan head.
    struct Retarget: Equatable, Sendable {
        var command: TapeCommand
        /// Set when the edit could not be carried: it stays on its checkpoint, and the banner
        /// points the human at it.
        var conflict: EditConflict?
    }

    /// The runner's own carry rule (`PlanLayers.carryForward`), for the one case it can't see:
    /// an edit committed after the new head already exists. Kept on the old checkpoint it
    /// would feed nothing (`TapeStore.headPlanCheckpoint`), so it is three-way merged onto the
    /// head — ours = the head's plan, base = the text the edit was typed on, theirs = the edit —
    /// and sent for the head. A conflict keeps it where it was typed, as before.
    ///
    /// Nonisolated and async, so `git` runs off the main actor. The app's own environment is
    /// enough: `git` is `/usr/bin/git`, on every PATH, and a login-shell lookup here would
    /// block for seconds.
    static func retarget(markdown: String, typedOn: Int, base: String, head: Int, headPlan: String,
                         runner: CommandRunner) async -> Retarget {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("flightdeck-carry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        switch await PlanLayers.carryForward(ours: headPlan, base: base, theirs: markdown, runner: runner,
                                             environment: ProcessInfo.processInfo.environment, scratch: scratch) {
        case .merged(let plan):
            return Retarget(command: .editPlan(checkpoint: head, markdown: plan), conflict: nil)
        case .conflicted:
            return Retarget(command: .editPlan(checkpoint: typedOn, markdown: markdown),
                            conflict: EditConflict(edits: typedOn, landedIn: head))
        }
    }

    // MARK: - Attributes

    static let insertedTint = NSColor.systemGreen.withAlphaComponent(0.16)
    static let barColor = NSColor.systemGreen
    static let deletedColor = NSColor.systemRed

    /// The green tint under inserted words, for the editor's `DecorationLayer` — a rendering
    /// attribute, not a storage one, so it coexists with the notes' highlights (see there).
    /// On the words only: over a newline it paints a sliver past the end of the line.
    static func tints(_ marks: [EditMark], in text: String) -> [(NSRange, [NSAttributedString.Key: Any])] {
        let ns = text as NSString
        var out: [(NSRange, [NSAttributedString.Key: Any])] = []
        for mark in marks where mark.kind == .inserted && NSMaxRange(mark.range) <= ns.length {
            var i = mark.range.location
            while i < NSMaxRange(mark.range) {
                let line = ns.lineRange(for: NSRange(location: i, length: 0))
                var content = NSIntersectionRange(line, mark.range)
                while content.length > 0, [10, 13].contains(ns.character(at: NSMaxRange(content) - 1)) { content.length -= 1 }
                if content.length > 0 { out.append((content, [.backgroundColor: insertedTint])) }
                i = NSMaxRange(line)
            }
        }
        return out
    }

    /// Lays `marks` over `storage`, touching only characters inside `within` (nil: all of it).
    ///
    /// Must run right after the styler restyled exactly those ranges: the styler resets every
    /// attribute there, the layer's included, and the layer ADDS to what it finds (kern and
    /// paragraph spacing make room for ghosts on top of the styler's own) — applied twice to
    /// the same range, a ghost's gap would double.
    ///
    /// Only what changes layout, or what a layout fragment must read back, is a storage
    /// attribute here; the insertion tint is `tints`. Nothing here changes a character. Ghosts take room through kern (inside a line), head
    /// indent (at a line's start) or paragraph spacing (whole lines), and are drawn by
    /// `EditLayerFragment` into that room.
    static func apply(_ marks: [EditMark], to storage: NSTextStorage, within ranges: [NSRange]?, theme: PlanTheme) {
        guard !marks.isEmpty, storage.length > 0 else { return }
        let ns = storage.string as NSString
        func inside(_ location: Int) -> Bool {
            guard let ranges else { return true }
            return ranges.contains { NSLocationInRange(location, $0) }
        }
        storage.beginEditing()
        defer { storage.endEditing() }
        for mark in marks {
            switch mark.kind {
            case .inserted:
                for part in ranges ?? [NSRange(location: 0, length: storage.length)] {
                    let r = NSIntersectionRange(mark.range, part)
                    guard r.length > 0, NSMaxRange(r) <= storage.length else { continue }
                    storage.addAttribute(.planEditInserted, value: true, range: r)
                }
            case .deleted:
                addGhost(mark, to: storage, ns: ns, inside: inside, theme: theme)
            }
        }
    }

    private static func addGhost(_ mark: EditMark, to storage: NSTextStorage, ns: NSString, inside: (Int) -> Bool, theme: PlanTheme) {
        let anchor = mark.range.location
        let atEnd = anchor >= storage.length
        let paragraph = ns.paragraphRange(for: NSRange(location: min(anchor, storage.length - 1), length: 0))
        let placement: EditGhost.Placement
        let host: Int
        if mark.inline, !atEnd, anchor > paragraph.location {
            // The gap follows the character before the removed words.
            placement = .inline
            host = ns.rangeOfComposedCharacterSequence(at: anchor - 1).location
        } else if mark.inline, !atEnd {
            placement = .lineStart
            host = anchor
        } else if !atEnd {
            placement = .above
            host = anchor
        } else {
            placement = .below
            host = storage.length - 1
        }
        guard inside(host) else { return }
        let font = ghostFont(storage, at: host, placement: placement, theme: theme)
        let ghost = EditGhost(text: mark.ghost, font: font, placement: placement)
        let existing = (storage.attribute(.planEditGhosts, at: host, effectiveRange: nil) as? EditGhosts)?.all ?? []
        storage.addAttribute(.planEditGhosts, value: EditGhosts(existing + [ghost]), range: NSRange(location: host, length: 1))

        switch placement {
        case .inline:
            let kern = (storage.attribute(.kern, at: host, effectiveRange: nil) as? CGFloat) ?? 0
            storage.addAttribute(.kern, value: kern + ghost.room, range: NSRange(location: host, length: 1))
        case .lineStart, .above, .below:
            let hostParagraph = ns.paragraphRange(for: NSRange(location: host, length: 0))
            let style = ((storage.attribute(.paragraphStyle, at: hostParagraph.location, effectiveRange: nil) as? NSParagraphStyle)
                ?? .default).mutableCopy() as! NSMutableParagraphStyle
            switch placement {
            case .lineStart: style.firstLineHeadIndent += ghost.room
            case .above: style.paragraphSpacingBefore += ghost.height
            default: style.paragraphSpacing += ghost.height
            }
            storage.addAttribute(.paragraphStyle, value: style, range: hostParagraph)
        }
    }

    /// Inside a line the ghost matches the words around it; whole-line ghosts are raw lines of
    /// Markdown, so they take the body font.
    private static func ghostFont(_ storage: NSTextStorage, at host: Int, placement: EditGhost.Placement, theme: PlanTheme) -> NSFont {
        guard placement == .inline || placement == .lineStart else { return theme.body }
        // The host itself may be hidden syntax (a 0.01 pt font); the words after it are not.
        for i in [host + 1, host] where i < storage.length {
            if let font = storage.attribute(.font, at: i, effectiveRange: nil) as? NSFont, font.pointSize >= 6 { return font }
        }
        return theme.body
    }
}

extension NSAttributedString.Key {
    /// Characters the human inserted: the edit gutter lane draws its bar beside their lines.
    static let planEditInserted = NSAttributedString.Key("FlightDeck.planEditInserted")
    /// `EditGhosts` to draw at this character — never characters of the text.
    static let planEditGhosts = NSAttributedString.Key("FlightDeck.planEditGhosts")
}

/// Removed text to draw where it was, struck through. A class, since attribute values are
/// objects and the fragment reads it back per draw.
final class EditGhost: NSObject {
    enum Placement { case inline, lineStart, above, below }
    let text: String
    let font: NSFont
    let placement: Placement

    init(text: String, font: NSFont, placement: Placement) {
        self.text = text
        self.font = font
        self.placement = placement
    }

    var lines: [String] { text.components(separatedBy: "\n") }
    var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) + 2 }
    /// Horizontal room an inline ghost takes: its words plus a little air either side.
    var room: CGFloat { ceil(attributed(text).size().width) + 6 }
    /// Vertical room whole-line ghosts take.
    var height: CGFloat { CGFloat(lines.count) * lineHeight + 2 }

    func attributed(_ line: String) -> NSAttributedString {
        NSAttributedString(string: line, attributes: [
            .font: font,
            .foregroundColor: EditLayer.deletedColor.withAlphaComponent(0.8),
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: EditLayer.deletedColor.withAlphaComponent(0.75),
            .backgroundColor: EditLayer.deletedColor.withAlphaComponent(0.1),
        ])
    }
}

/// More than one ghost can land on one character (a removed line above a line whose words
/// also changed).
final class EditGhosts: NSObject {
    let all: [EditGhost]
    init(_ all: [EditGhost]) { self.all = all }
}

// MARK: - Gutter

/// The plan editor's left margin, split into lanes left to right: CHURN (the agents' per-round
/// churn per section, spec §8.2 — `ChurnLaneView`) and EDIT (the human's edits, green bars —
/// this layer). One type so every lane agrees on where the others are, and the text on where it
/// starts.
///
/// EDIT sits against the text, where a bar reads as marking the line beside it; CHURN is outside
/// it and takes room only while it has markers (`churn`): its captions ("still since R2") need
/// a real column, and a plan with no cycle to describe shouldn't be indented for one.
enum PlanGutter {
    enum Lane { case churn, edit }

    /// View edge to the first lane.
    static let leading: CGFloat = 6
    static let editWidth: CGFloat = 3
    static let laneGap: CGFloat = 5
    /// A caption and one small bar per round of a cycle.
    static let churnWidth: CGFloat = ChurnLaneView.width
    /// Last lane to the text — and the column a heading's fold chevron sits in
    /// (`PlanFoldGutter`), between the edit bars and the words, only on a hovered or folded
    /// heading.
    static let textGap: CGFloat = 18
    /// The chevron column's centre, from the text's leading edge (negative: left of it).
    static let chevronCenter: CGFloat = -9

    /// Where the text begins, from the text view's leading edge.
    static func width(churn: Bool) -> CGFloat {
        leading + (churn ? churnWidth + laneGap : 0) + editWidth + textGap
    }

    /// Text to the view's trailing edge: a margin that reads as one rather than words running
    /// into the pane's edge.
    static let trailingMargin: CGFloat = 32

    /// The text container's width in a text view `viewWidth` wide: the pane's width, less the
    /// gutter lanes and the trailing margin. The plan wraps to the pane like any text editor —
    /// a fixed 720 pt measure broke every long paragraph at the same column however wide the
    /// window was, which read as hard line breaks in the plan (the maintainer: "arbitrary fixed-width
    /// line breaks"). Resizing reflows it (`PlanNSTextView.fitContainer`).
    static func textWidth(viewWidth: CGFloat, churn: Bool) -> CGFloat {
        max(0, viewWidth - width(churn: churn) - trailingMargin)
    }

    /// A lane's horizontal extent in the text view's coordinates.
    static func span(_ lane: Lane, churn: Bool) -> (x: CGFloat, width: CGFloat) {
        switch lane {
        case .churn: (leading, churn ? churnWidth : 0)
        case .edit: (width(churn: churn) - textGap - editWidth, editWidth)
        }
    }

    /// A lane's x relative to the text's own leading edge (the text container's origin) —
    /// negative; what a layout fragment, which knows only its own geometry, draws at. The same
    /// with or without the churn column, which is outside the edit lane.
    static func offset(_ lane: Lane) -> CGFloat { span(lane, churn: true).x - width(churn: true) }
}

// MARK: - Drawing

/// Every paragraph of the plan is laid out as one of these (`EditLayerLayout`): it draws the
/// edit lane's bars and the deletion ghosts into the room `EditLayer.apply` made for them, and
/// behind the text a fenced block's box and a quote's bar (`MarkdownStyler`'s `.planCodeBox`,
/// `.planQuote`). Drawing, not text, is what keeps the stored plan byte-identical to
/// `plan.user.md`.
final class EditLayerFragment: NSTextLayoutFragment {
    private var paragraphText: NSAttributedString? { (textElement as? NSTextParagraph)?.attributedString }

    private var codeBox: CodeBox? {
        guard let text = paragraphText, text.length > 0, let raw = text.attribute(.planCodeBox, at: 0, effectiveRange: nil) as? Int
        else { return nil }
        return CodeBox(rawValue: raw)
    }

    private var isQuote: Bool {
        guard let text = paragraphText, text.length > 0 else { return false }
        return text.attribute(.planQuote, at: 0, effectiveRange: nil) != nil
    }

    /// The box behind a fenced block's line, in this fragment's coordinates: the text
    /// container's full width, and the fragment's full height — its spacing included, which is
    /// where the fences' padding is — so consecutive lines' bands meet with no seam.
    private var codeBand: CGRect? {
        guard codeBox != nil else { return nil }
        let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        return CGRect(x: -layoutFragmentFrame.minX, y: 0, width: width, height: layoutFragmentFrame.height)
    }

    private var ghosts: [(index: Int, ghost: EditGhost)] {
        guard let text = paragraphText else { return [] }
        var out: [(Int, EditGhost)] = []
        text.enumerateAttribute(.planEditGhosts, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let value = value as? EditGhosts else { return }
            for ghost in value.all { out.append((range.location, ghost)) }
        }
        return out
    }

    /// The gutter lies left of the text and the whole-line ghosts may sit outside the lines'
    /// own bounds: both must be inside the surface, or they are clipped away.
    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        if let band = codeBand { bounds = bounds.union(band) }
        let gutterX = PlanGutter.offset(.edit) - layoutFragmentFrame.minX - 1
        bounds = bounds.union(CGRect(x: gutterX, y: bounds.minY, width: 1, height: bounds.height))
        for (_, ghost) in ghosts where ghost.placement == .above || ghost.placement == .below {
            let width = ghost.lines.map { ceil(ghost.attributed($0).size().width) }.max() ?? 0
            let top = ghost.placement == .above ? (textLineFragments.first?.typographicBounds.minY ?? 0) - ghost.height : bounds.maxY
            bounds = bounds.union(CGRect(x: 0, y: top, width: width, height: ghost.height))
        }
        return bounds
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        drawBlockDecoration(at: point, in: context)
        super.draw(at: point, in: context)
        guard let text = paragraphText, !textLineFragments.isEmpty else { return }
        let ghosts = ghosts
        var inserted = Set<Int>()
        text.enumerateAttribute(.planEditInserted, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard value != nil else { return }
            for (i, line) in textLineFragments.enumerated() where NSIntersectionRange(line.characterRange, range).length > 0
                || (range.length == 0 && NSLocationInRange(range.location, line.characterRange)) {
                inserted.insert(i)
            }
        }
        guard !inserted.isEmpty || !ghosts.isEmpty else { return }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let laneX = point.x + PlanGutter.offset(.edit) - layoutFragmentFrame.minX
        func bar(_ minY: CGFloat, _ maxY: CGFloat, _ color: NSColor) {
            color.setFill()
            NSBezierPath(roundedRect: CGRect(x: laneX, y: point.y + minY, width: PlanGutter.editWidth, height: maxY - minY),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }

        var removedIn = Set<Int>()
        for (index, ghost) in ghosts {
            switch ghost.placement {
            case .inline, .lineStart:
                guard let (i, line) = lineFragment(containing: index) else { continue }
                removedIn.insert(i)
                // Where the room starts. Inside a line it follows the host character's own
                // advance: measured, since the caret offset of the character after a kerned
                // one is interpolated across the gap (probed: mid-gap, not its end).
                let gapStart: CGFloat
                if ghost.placement == .inline {
                    var attributes = text.attributes(at: index, effectiveRange: nil)
                    attributes[.kern] = nil
                    let host = NSAttributedString(string: text.attributedSubstring(from: NSRange(location: index, length: 1)).string,
                                                  attributes: attributes)
                    gapStart = line.locationForCharacter(at: index).x + host.size().width
                } else {
                    gapStart = line.locationForCharacter(at: index).x - ghost.room
                }
                let origin = line.typographicBounds.origin
                let baseline = origin.y + line.glyphOrigin.y
                ghost.attributed(ghost.text).draw(at: CGPoint(x: point.x + origin.x + gapStart + 3,
                                                              y: point.y + baseline - ghost.font.ascender))
            case .above, .below:
                let top = ghost.placement == .above
                    ? textLineFragments[0].typographicBounds.minY - ghost.height
                    : textLineFragments[textLineFragments.count - 1].typographicBounds.maxY
                // One unwrapped line each, at full length: fitted to the paragraph's own width
                // a removed line longer than the line below it lost its end
                // (`renderingSurfaceBounds` makes the room).
                for (k, line) in ghost.lines.enumerated() {
                    ghost.attributed(line).draw(at: CGPoint(x: point.x, y: point.y + top + 1 + CGFloat(k) * ghost.lineHeight))
                }
                bar(top + 1, top + ghost.height - 1, EditLayer.deletedColor)
            }
        }
        for (i, line) in textLineFragments.enumerated() where inserted.contains(i) || removedIn.contains(i) {
            let b = line.typographicBounds
            switch (inserted.contains(i), removedIn.contains(i)) {
            case (true, true):
                // A changed line: green over red, as in the mockup's split bar.
                bar(b.minY, b.midY, EditLayer.barColor)
                bar(b.midY, b.maxY, EditLayer.deletedColor)
            case (true, false): bar(b.minY, b.maxY, EditLayer.barColor)
            default: bar(b.minY, b.maxY, EditLayer.deletedColor)
            }
        }
    }

    /// A code line's share of its block's rounded box, or a quote line's bar — under the text.
    private func drawBlockDecoration(at point: CGPoint, in context: CGContext) {
        let theme = PlanTheme.standard
        if let band = codeBand, let box = codeBox {
            let radius: CGFloat = 6
            // Rounded only where the box ends: a middle line's band runs past its own edges by
            // the radius, and the clip cuts the overrun off square.
            var rect = band.offsetBy(dx: point.x, dy: point.y)
            if !box.contains(.first) { rect.origin.y -= radius; rect.size.height += radius }
            if !box.contains(.last) { rect.size.height += radius }
            context.saveGState()
            context.clip(to: band.offsetBy(dx: point.x, dy: point.y))
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(theme.codeBlockBackground.cgColor)
            context.fillPath()
            context.restoreGState()
        }
        if isQuote, let first = textLineFragments.first, let last = textLineFragments.last {
            let top = first.typographicBounds.minY, bottom = last.typographicBounds.maxY
            context.setFillColor(theme.quoteBar.cgColor)
            context.addPath(CGPath(roundedRect: CGRect(x: point.x - layoutFragmentFrame.minX + 2, y: point.y + top,
                                                       width: 3, height: max(bottom - top, 1)),
                                   cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            context.fillPath()
        }
    }

    private func lineFragment(containing index: Int) -> (Int, NSTextLineFragment)? {
        for (i, line) in textLineFragments.enumerated() where NSLocationInRange(index, line.characterRange) { return (i, line) }
        return textLineFragments.last.map { (textLineFragments.count - 1, $0) }
    }
}

/// Hands TextKit 2 an `EditLayerFragment` for every paragraph. Held strongly by the editor's
/// container: a layout manager's delegate is weak.
final class EditLayerLayout: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        EditLayerFragment(textElement: textElement, range: textElement.elementRange)
    }
}

// MARK: - Revert on hover

/// The per-hunk "Revert" (spec §7.2): shown at the top right of the hunk under the pointer,
/// hidden elsewhere. A subview of the text view, so it scrolls with the text.
final class EditRevertButton {
    let button: NSButton
    weak var textView: NSTextView?
    /// Each hunk's characters (`EditLayer.spans`).
    var spans: [NSRange] = [] { didSet { if oldValue != spans { show(nil) } } }
    var enabled = false { didSet { if !enabled { show(nil) } } }
    var onRevert: ((Int) -> Void)?
    private(set) var hovered: Int?
    private let target = Target()

    init() {
        button = NSButton(title: "Revert", target: nil, action: nil)
        // A small opaque pill of its own (the mockup's), not a bezel: it floats over the
        // text, and an inline bezel drew as bare grey text an inactive window made unreadable.
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.attributedTitle = NSAttributedString(string: "Revert", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.labelColor,
        ])
        button.isHidden = true
        button.setAccessibilityIdentifier("plan-edit-revert")
        button.sizeToFit()
        button.target = target
        button.action = #selector(Target.fire(_:))
        target.action = { [weak self] in
            guard let self, let hunk = hovered else { return }
            show(nil)
            onRevert?(hunk)
        }
    }

    /// The pointer moved to `point` (text view coordinates), or left the view.
    func hover(at point: NSPoint?) {
        guard enabled, let point, let hunk = hunk(at: point) else { return show(nil) }
        show(hunk)
    }

    /// Shows the button for `hunk`, or hides it.
    func show(_ hunk: Int?) {
        guard let hunk, spans.indices.contains(hunk), let textView, let rect = rect(of: spans[hunk], in: textView) else {
            hovered = nil
            button.isHidden = true
            return
        }
        hovered = hunk
        if button.superview !== textView { textView.addSubview(button) }
        textView.effectiveAppearance.performAsCurrentDrawingAppearance {
            button.layer?.backgroundColor = NSColor.controlColor.blended(withFraction: 0.12, of: .labelColor)?.cgColor
            button.layer?.borderColor = NSColor.separatorColor.cgColor
            button.layer?.borderWidth = 0.5
        }
        let size = button.fittingSize
        button.frame = NSRect(x: textView.bounds.maxX - size.width - 22, y: rect.minY + 1, width: size.width + 16, height: 20)
        button.isHidden = false
    }

    private func hunk(at point: NSPoint) -> Int? {
        guard let textView, let layout = textView.textLayoutManager, let content = layout.textContentManager else { return nil }
        let origin = textView.textContainerOrigin
        let local = CGPoint(x: max(point.x - origin.x, 1), y: point.y - origin.y)
        guard let fragment = layout.textLayoutFragment(for: local) else { return nil }
        let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        return spans.firstIndex { NSLocationInRange(offset, $0) || $0.location == offset }
    }

    /// The hunk's first and last paragraphs' frames, in the text view's coordinates.
    private func rect(of span: NSRange, in textView: NSTextView) -> NSRect? {
        guard let layout = textView.textLayoutManager, let content = layout.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: span.location),
              let first = layout.textLayoutFragment(for: start) else { return nil }
        var frame = first.layoutFragmentFrame
        if span.length > 1, let end = content.location(content.documentRange.location, offsetBy: NSMaxRange(span) - 1),
           let last = layout.textLayoutFragment(for: end) {
            frame = frame.union(last.layoutFragmentFrame)
        }
        let origin = textView.textContainerOrigin
        return frame.offsetBy(dx: origin.x, dy: origin.y)
    }

    private final class Target: NSObject {
        var action: () -> Void = {}
        @objc func fire(_ sender: Any?) { action() }
    }
}

// MARK: - Hooks

/// Where the plan section's edit layer reports to the intake. State that must outlive the
/// section — which intakes have shown "Your edits are kept…", and the conflicts behind the
/// banner the live card draws — lives on `IntakeService`, not in view state.
struct PlanEditHooks {
    /// The kept-edits note already showed for this intake's plan.
    var noteShown = false
    var onNoteShown: () -> Void = {}
    /// A stale edit that could not be carried onto the head.
    var onConflict: (EditConflict) -> Void = { _ in }
    /// Runs `git merge-file` for `EditLayer.retarget`; a test hands in a fake.
    var runner: CommandRunner = SystemCommandRunner()
    /// The intake's tape as the service holds it now — what a merge waiting its turn re-reads
    /// the plan head from (`PlanEditRouter`). Nil falls back to the last tape the section was
    /// handed, which trails the service by a view update.
    var liveTape: (() -> Tape?)?
    /// The intake's own router (`IntakeService.editRouter`), which outlives the section; nil
    /// gives the section one of its own (renders, tests).
    var router: PlanEditRouter?
    /// The intake's folded sections (`IntakeService.planFolds`), which outlive the section; nil
    /// keeps them in the editor for as long as it lives.
    var folds: PlanFoldStore?
    /// The intake's project directory, which the plan's relative file links resolve against
    /// (`PlanLinks`); nil resolves only absolute and `~` paths.
    var projectPath: String?
}

/// `PlanLayers.userDiff`'s hunks, found without splitting and hashing the whole plan on every
/// keystroke: the characters both texts share at each end are cut off first (a memcmp over
/// UTF-16), back to whole lines plus one shared line of context either side, and only the
/// window between is diffed. The diff trims shared end lines itself, so its middle — and every
/// hunk — is the same as the whole-plan diff's; the hunks are then moved to whole-plan line
/// numbers and given their section from the whole plan. On a 2,000-line plan this took the
/// edit layer from most of a keystroke's budget to a small part of it.
struct LineWindowDiff {
    let hunks: [PlanHunk]
    /// UTF-16 offset of line `j` of the edited text — for the window's lines and the one after
    /// it, which is all a hunk's marks ask for; past the last line, the text's length.
    let lineStart: (Int) -> Int

    init(generated: String, edited: String) {
        let a = Self.units(generated), b = Self.units(edited)
        let limit = min(a.count, b.count)
        var same = 0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                // In blocks first: a Debug-build loop over every character was itself a
                // millisecond on a long plan.
                let block = 512
                while same + block <= limit, memcmp(pa.baseAddress! + same, pb.baseAddress! + same, block * 2) == 0 { same += block }
                while same < limit, pa[same] == pb[same] { same += 1 }
            }
        }
        // Back to a line start, then one more line: a shared line of context before the window.
        var prefix = Self.lineStart(before: same, in: a)
        if prefix > 0 { prefix = Self.lineStart(before: prefix - 1, in: a) }

        var tail = 0
        let tailLimit = limit - prefix
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                let block = 512
                while tail + block <= tailLimit,
                      memcmp(pa.baseAddress! + a.count - tail - block, pb.baseAddress! + b.count - tail - block, block * 2) == 0 { tail += block }
                while tail < tailLimit, pa[a.count - 1 - tail] == pb[b.count - 1 - tail] { tail += 1 }
            }
        }
        // Forward to the start of a shared line, then one more: a line of context after it.
        // `suffix` counts the characters cut from the end; 0 cuts nothing.
        var suffix = 0
        if let first = Self.nextLineStart(from: a.count - tail, in: a, within: tail),
           let second = Self.nextLineStart(from: first, in: a, within: a.count - first) {
            suffix = a.count - second
        }

        let skipped = Self.newlines(in: a, upTo: prefix)
        func text(_ u: [unichar], _ from: Int, _ to: Int) -> String {
            // Without the window's last newline when a suffix follows: the suffix's first line
            // starts after it, and a trailing newline would read as one more, empty line.
            let end = suffix > 0 ? to - 1 : to
            guard end > from else { return "" }
            // `String(decoding:)`, a native Swift string: `String(utf16CodeUnits:)` is an
            // NSString underneath, and the line diff over it went through the bridge.
            return u.withUnsafeBufferPointer { String(decoding: UnsafeBufferPointer(rebasing: $0[from..<end]), as: UTF16.self) }
        }
        let windowA = text(a, prefix, a.count - suffix), windowB = text(b, prefix, b.count - suffix)
        let found = PlanLayers.userDiff(generated: windowA, edited: windowB)
        hunks = found.map { h in
            var hunk = h
            hunk.oldStart += skipped
            hunk.newStart += skipped
            hunk.section = h.newLines.isEmpty && !h.oldLines.isEmpty
                ? Self.heading(atLine: hunk.oldStart, lineOffset: Self.offset(ofLine: h.oldStart, in: a, from: prefix), in: a)
                : Self.heading(atLine: hunk.newStart, lineOffset: Self.offset(ofLine: h.newStart, in: b, from: prefix), in: b)
            return hunk
        }

        var starts: [Int] = [prefix]
        let windowEnd = b.count - suffix
        b.withUnsafeBufferPointer { pb in
            var i = prefix
            while i < windowEnd {
                if pb[i] == 10 { starts.append(i + 1) }
                i += 1
            }
        }
        let length = b.count
        lineStart = { j in
            let k = j - skipped
            if k >= 0, k < starts.count { return starts[k] }
            return k < 0 ? 0 : length
        }
    }

    private static func units(_ text: String) -> [unichar] {
        let ns = text as NSString
        var out = [unichar](repeating: 0, count: ns.length)
        out.withUnsafeMutableBufferPointer { if let base = $0.baseAddress { ns.getCharacters(base, range: NSRange(location: 0, length: ns.length)) } }
        return out
    }

    /// The start of the line holding offset `i` (`i` itself when it follows a newline).
    private static func lineStart(before i: Int, in u: [unichar]) -> Int {
        var j = i
        while j > 0, u[j - 1] != 10 { j -= 1 }
        return j
    }

    /// The first line start at or after `from` whose preceding newline lies inside the last
    /// `within` characters (the shared tail); nil when there is none.
    private static func nextLineStart(from: Int, in u: [unichar], within: Int) -> Int? {
        var j = max(from, u.count - within, 1)
        while j <= u.count {
            if u[j - 1] == 10, j - 1 >= u.count - within { return j }
            j += 1
            if j > u.count { break }
        }
        return nil
    }

    private static func newlines(in u: [unichar], upTo end: Int) -> Int {
        u.withUnsafeBufferPointer { p in
            var n = 0, i = 0
            while i < end { if p[i] == 10 { n += 1 }; i += 1 }
            return n
        }
    }

    /// The UTF-16 offset of window line `line` (window lines counted from `from`).
    private static func offset(ofLine line: Int, in u: [unichar], from: Int) -> Int {
        var i = from, n = 0
        while n < line, i < u.count { if u[i] == 10 { n += 1 }; i += 1 }
        return i
    }

    /// `PlanMetrics`' section for a hunk: the last line at or above it starting with `#`,
    /// trimmed; nil in the preamble.
    private static func heading(atLine _: Int, lineOffset: Int, in u: [unichar]) -> String? {
        var start = lineStart(before: min(lineOffset, u.count), in: u)
        while true {
            if start < u.count, u[start] == 35 {
                var end = start
                while end < u.count, u[end] != 10 { end += 1 }
                if end > start, u[end - 1] == 13 { end -= 1 }
                let line = u.withUnsafeBufferPointer { String(utf16CodeUnits: $0.baseAddress! + start, count: end - start) }
                return line.trimmingCharacters(in: .whitespaces)
            }
            guard start > 0 else { return nil }
            start = lineStart(before: start - 1, in: u)
        }
    }
}
