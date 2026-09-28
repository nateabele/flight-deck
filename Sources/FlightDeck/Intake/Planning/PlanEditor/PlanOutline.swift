import AppKit

/// Which heading a fold belongs to: the heading's line as written (`## 4. Dispatch rules`) and
/// which occurrence of that line it is. By text, so a fold outlives a new round that moved the
/// section; with the occurrence, so folding one of a plan's many `### Tests` doesn't fold all.
struct PlanFoldKey: Hashable {
    let text: String
    let occurrence: Int
}

/// One heading of the plan and the section under it, in UTF-16 offsets of the plan text.
struct PlanHeading: Equatable {
    let level: Int
    /// The heading's words, without its `#`s — what the outline cues and VoiceOver show.
    let title: String
    let key: PlanFoldKey
    /// The heading line, without its newline.
    let line: NSRange
    /// What folding hides: from the line after the heading to the next heading of the same or
    /// a higher level (or the end), subsections included. Empty for a heading with nothing
    /// under it.
    let body: NSRange
}

/// The plan's outline, from the styler's block parse — so a `#` inside a code fence is code,
/// as the editor draws it, and never a section. Pure.
enum PlanOutline {
    static func headings(_ blocks: [MarkdownBlock], in text: NSString) -> [PlanHeading] {
        var found: [(level: Int, block: MarkdownBlock)] = []
        for block in blocks { if case .heading(let level) = block.kind { found.append((level, block)) } }
        var seen: [String: Int] = [:]
        var out: [PlanHeading] = []
        out.reserveCapacity(found.count)
        for (i, (level, block)) in found.enumerated() {
            let lineText = text.substring(with: block.range).trimmingCharacters(in: .whitespaces)
            let occurrence = seen[lineText, default: 0]
            seen[lineText] = occurrence + 1
            let contentStart = block.syntaxRanges.first.map(NSMaxRange) ?? block.range.location
            let title = text.substring(with: NSRange(location: contentStart, length: max(NSMaxRange(block.range) - contentStart, 0)))
                .trimmingCharacters(in: .whitespaces)
            let end = found[(i + 1)...].first { $0.level <= level }?.block.range.location ?? text.length
            let lineEnd = NSMaxRange(block.range)
            let bodyStart = min(lineEnd < text.length && text.character(at: lineEnd) == 10 ? lineEnd + 1 : lineEnd, end)
            out.append(PlanHeading(level: level, title: title, key: PlanFoldKey(text: lineText, occurrence: occurrence),
                                   line: block.range, body: NSRange(location: bodyStart, length: end - bodyStart)))
        }
        return out
    }

    /// The deepest section holding `location` — its heading line or its body; nil above the
    /// first heading. What ⌥⌘← folds.
    static func innermost(containing location: Int, in headings: [PlanHeading]) -> Int? {
        var best: Int?
        for (i, h) in headings.enumerated() {
            guard h.line.location <= location else { break }
            let end = max(NSMaxRange(h.body), NSMaxRange(h.line))
            if location <= end, location < end || i == headings.count - 1 || h.body.length == 0 || location == NSMaxRange(h.line) {
                best = i
            }
        }
        return best
    }

    /// The non-blank lines in `range` — a folded section's "12 lines".
    static func lineCount(_ range: NSRange, in text: NSString) -> Int {
        var count = 0
        text.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            if text.substring(with: line).contains(where: { !$0.isWhitespace }) { count += 1 }
        }
        return count
    }

    // MARK: Nav cues

    /// The section being read: the last heading whose top is at or above `probe` (a line just
    /// under the page's pinned block); nil while the plan's first heading is still below it.
    /// The pinned board's breadcrumb (`PlanReadingPosition`).
    static func current(tops: [CGFloat], probe: CGFloat) -> Int? {
        var lo = 0, hi = tops.count - 1, best: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if tops[mid] <= probe { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best
    }
}

/// Which sections are folded — a view state over the plan, never part of it: nothing here
/// touches the text, and the editor hides the folded bodies from layout only
/// (`PlanFoldFilter`).
struct PlanFolds: Equatable {
    private(set) var folded: Set<PlanFoldKey> = []

    var isEmpty: Bool { folded.isEmpty }

    func isFolded(_ key: PlanFoldKey) -> Bool { folded.contains(key) }

    mutating func toggle(_ key: PlanFoldKey) {
        if folded.remove(key) == nil { folded.insert(key) }
    }

    mutating func set(_ key: PlanFoldKey, folded fold: Bool) {
        if fold { folded.insert(key) } else { folded.remove(key) }
    }

    /// A new text (a round landed, another checkpoint): folds whose heading is gone are dropped.
    mutating func reconcile(with headings: [PlanHeading]) {
        let present = Set(headings.map(\.key))
        folded.formIntersection(present)
    }

    /// An edit that kept the headings' number and order (typing, including on a heading line)
    /// carries each fold to the heading now in its place — so retyping a folded heading's
    /// words keeps it folded rather than springing it open. Anything else reconciles by text.
    mutating func carry(from old: [PlanHeading], to new: [PlanHeading]) {
        guard !folded.isEmpty else { return }
        guard old.count == new.count, zip(old, new).allSatisfy({ $0.level == $1.level }) else { return reconcile(with: new) }
        folded = Set(zip(old, new).compactMap { folded.contains($0.key) ? $1.key : nil })
    }

    /// The folded sections' bodies, sorted, a body inside another folded one merged into it.
    func hidden(in headings: [PlanHeading]) -> [NSRange] {
        guard !folded.isEmpty else { return [] }
        var out: [NSRange] = []
        for h in headings where h.body.length > 0 && folded.contains(h.key) {
            if let last = out.last, h.body.location < NSMaxRange(last) {
                out[out.count - 1] = NSUnionRange(last, h.body)
            } else {
                out.append(h.body)
            }
        }
        return out
    }
}

/// One intake's folds, kept by `IntakeService` for the session so they outlive the editor —
/// which is rebuilt on every intake switch — the way the plan-edit router does.
final class PlanFoldStore {
    var folds = PlanFolds()
}

/// Where you are in the plan, said as quietly as possible (Nate: "very unobtrusive"): once the
/// section you are reading has scrolled its heading up under the page's pinned block, its name
/// shows in the pinned board's footer, between DEP · CLR and ARR · REV, in the board's own
/// caption; a click on it brings the heading back. Nothing shows while the heading is on screen.
///
/// Chosen from three rendered variants (`readable-cue-*.png`): a trailing tick rail (one tick
/// per heading) read as a column of dashes beside the text and competed with list markers; a
/// faint bar in the leading margin said nothing without a label and sat in the fold chevrons'
/// column; the breadcrumb drawn over the text covered the first line under the block, so it
/// lives in the block's own empty footer instead.
///
/// The editor sets `section`; the pane holds this in `@State` and only the crumb observes it, so
/// a scroll that changes the section redraws the crumb and nothing else. Nothing animates, so
/// Reduce Motion has nothing to take away. VoiceOver gets the outline from the editor's
/// Headings rotor.
@MainActor
final class PlanReadingPosition: ObservableObject {
    @Published private(set) var section: String?
    /// Scrolls the heading of `section` back under the pinned block; set by the editor.
    var jump: () -> Void = {}

    nonisolated init() {}

    func set(_ section: String?) {
        if section != self.section { self.section = section }
    }

    static func label(_ title: String) -> String { "§ " + title }
}
