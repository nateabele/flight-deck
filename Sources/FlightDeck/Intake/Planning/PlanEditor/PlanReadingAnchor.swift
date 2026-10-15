import AppKit

/// Where the human was reading a plan, said in the plan's own text rather than in pixels: the
/// source offset of the line at the top of the page, and how far below that line's top the page's
/// edge sat. A pixel offset means nothing once the width, the typography or a
/// fold changes the layout, or text above it is edited; a line of text is still that line.
///
/// Taken from the layout on a quiet scroll (`PlanTextView.Coordinator.rememberReading`), kept by
/// `PlanScrollMemory`, and put back when the editor is made again.
struct PlanReadingAnchor: Equatable {
    /// UTF-16 offset of the first visible line's first character (a wrapped paragraph's lines
    /// each have one).
    var offset: Int
    /// How far the page's top edge was below that line's top; negative when the line was still
    /// below it (the page scrolled to something above the plan).
    var within: CGFloat
    /// The paragraph that names the line, trimmed, and how far from its start the line is — what
    /// finds the line again in a text that replaced this one (`relocated`). The paragraph at
    /// `offset`, or the next with words enough to tell it from the plan's other short lines when
    /// that one is a blank or a bullet's `-` (then `into` is negative); empty if none is near.
    var paragraph: String
    var into: Int
    /// Which identical paragraph it was: the nth with these words, so one of many `- Tests` lines
    /// is found again as that one.
    var occurrence: Int
    /// The innermost section it was in, for when the paragraph is gone.
    var section: PlanFoldKey?

    /// A paragraph too short to tell from the plan's other short lines (`---`, a bullet's `-`).
    static let identifyingLength = 6

    /// The anchor for the line starting at `offset` of `text`, `within` points above the page's top edge.
    static func at(_ offset: Int, within: CGFloat, in text: NSString, headings: [PlanHeading]) -> PlanReadingAnchor {
        let offset = min(max(offset, 0), text.length)
        var range = text.paragraphRange(for: NSRange(location: offset, length: 0))
        var words = Self.words(text, range)
        var hops = 0
        while words.count < identifyingLength, NSMaxRange(range) < text.length, hops < 6 {
            range = text.paragraphRange(for: NSRange(location: NSMaxRange(range), length: 0))
            words = Self.words(text, range)
            hops += 1
        }
        var occurrence = 0
        if words.count >= identifyingLength {
            var at = 0
            while at < range.location {
                let line = text.paragraphRange(for: NSRange(location: at, length: 0))
                if Self.words(text, line) == words { occurrence += 1 }
                at = NSMaxRange(line)
            }
        } else {
            words = ""
            range = text.paragraphRange(for: NSRange(location: offset, length: 0))
        }
        let section = PlanOutline.innermost(containing: offset, in: headings).map { headings[$0].key }
        return PlanReadingAnchor(offset: offset, within: within, paragraph: words, into: offset - range.location,
                                 occurrence: occurrence, section: section)
    }

    private static func words(_ text: NSString, _ range: NSRange) -> String {
        text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The anchor after an edit to the text it was taken in: text typed above it moves it down
    /// with the line; an edit across the line itself leaves it at the edit, which the next
    /// reading of the layout refines.
    func shifted(by edit: TextEdit) -> PlanReadingAnchor {
        var moved = self
        moved.offset = edit.shift(NSRange(location: offset, length: 0))?.location ?? min(offset, edit.range.location)
        return moved
    }

    /// How `relocated` found the line.
    enum Match: Equatable {
        /// The same paragraph is still where it was.
        case unchanged
        /// The same paragraph, found elsewhere in the new text.
        case paragraph
        /// The paragraph is gone; the section it was in is not.
        case section
        /// Neither: the top of the plan.
        case top
    }

    /// Where this reading position is in `text`, a plan that replaced the one it was taken in (a
    /// round landed): the same paragraph if it is still there, else the same section's heading,
    /// else the top of the plan.
    func relocated(in text: NSString, headings: [PlanHeading]) -> (anchor: PlanReadingAnchor, match: Match) {
        let start = offset - into
        if start >= 0, start <= text.length {
            let range = text.paragraphRange(for: NSRange(location: start, length: 0))
            if range.location == start, !paragraph.isEmpty, Self.words(text, range) == paragraph { return (self, .unchanged) }
        }
        if paragraph.count >= Self.identifyingLength {
            var found: [NSRange] = []
            var at = 0
            while at < text.length {
                let line = text.paragraphRange(for: NSRange(location: at, length: 0))
                if Self.words(text, line) == paragraph { found.append(line) }
                at = NSMaxRange(line)
            }
            if let line = found.indices.contains(occurrence) ? found[occurrence] : found.last {
                var there = self
                there.offset = min(max(line.location + into, 0), text.length)
                return (there, .paragraph)
            }
        }
        if let section, let heading = headings.first(where: { $0.key == section }) ?? headings.first(where: { $0.key.text == section.text }) {
            let line = Self.at(heading.line.location, within: 0, in: text, headings: headings)
            return (line, .section)
        }
        return (Self.at(0, within: 0, in: text, headings: headings), .top)
    }
}

/// One plan's reading position and caret, kept for the session by `IntakeService` so they
/// outlive the editor — which is made again whenever the human leaves the project for an
/// agent's tab and comes back — the way `PlanFoldStore` keeps the folds. A view state, never
/// written to disk: a position into a plan is only worth keeping until the plan moves on.
final class PlanScrollMemory {
    var anchor: PlanReadingAnchor?
    /// The caret or selection, and whether the editor had the keyboard when it was left.
    var selection: NSRange?
    var focused = false
}
