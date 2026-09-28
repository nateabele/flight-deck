import Foundation

/// What a human note asks the next round to do. `replace` carries its replacement text in
/// `PlanNote.note`; `delete` needs no text but may explain itself there.
public enum NoteKind: String, Codable, Sendable, CaseIterable {
    case comment, question, mustChange, delete, replace
}

/// Where in a plan a note points: the quoted text plus about 32 characters of context either
/// side, W3C `TextQuoteSelector` style. Context rather than offsets because the plan moves
/// under the note — a later round, or the human's own edits, shifts every offset, but the
/// quote and its neighbourhood usually survive, so `locate` can still find the spot.
public struct NoteAnchor: Codable, Equatable, Sendable {
    /// The checkpoint whose plan the quote was selected in — the effective plan (the human's
    /// edits included) as it read at that checkpoint.
    public var checkpoint: Int
    public var quote: String
    /// The nearest `#` heading above the quote, for the prompt and for a UI that lists notes by
    /// section; nil in a plan's preamble.
    public var section: String?
    public var prefix: String
    public var suffix: String

    /// How much context `init(checkpoint:selecting:in:)` captures either side of the quote.
    public static let contextLength = 32

    public init(checkpoint: Int, quote: String, section: String? = nil, prefix: String = "", suffix: String = "") {
        self.checkpoint = checkpoint
        self.quote = quote
        self.section = section
        self.prefix = prefix
        self.suffix = suffix
    }

    /// An anchor for a selection the human made in `markdown`, with its context and section
    /// filled in — the constructor the app's highlight gesture should use, so every anchor on
    /// the tape carries the same amount of context `locate` expects.
    public init(checkpoint: Int, selecting range: Range<String.Index>, in markdown: String) {
        let before = markdown[..<range.lowerBound]
        let after = markdown[range.upperBound...]
        self.init(checkpoint: checkpoint, quote: String(markdown[range]),
                  section: Self.heading(before: range.lowerBound, in: markdown),
                  prefix: String(before.suffix(Self.contextLength)),
                  suffix: String(after.prefix(Self.contextLength)))
    }

    /// Re-finds the quote in `markdown`, which may have moved on since the anchor was made:
    ///
    /// 1. every exact occurrence of `quote`; one is the answer, several are ranked by how much
    ///    of `prefix` ends right before each and how much of `suffix` starts right after it —
    ///    so "the same phrase in two sections" resolves to the one the human highlighted;
    /// 2. failing that, the same search with every whitespace run collapsed to one space on both
    ///    sides — a reflowed paragraph or re-indented list still matches, and the range returned
    ///    is mapped back onto the original text.
    ///
    /// nil when the quote is gone (or empty): the note is then unanchored in practice, and the
    /// UI should show it detached rather than highlight a guess.
    ///
    /// A short quote (under `shortQuote` characters) must also prove it is the same spot: at
    /// least `shortContext` characters of its recorded prefix or suffix around it, or the same
    /// section. "the job" or "offline" occurs all over a plan, so without that a note whose
    /// words were deleted jumped to the next instance of them instead of showing detached.
    public func locate(in markdown: String) -> Range<String.Index>? {
        guard !quote.isEmpty else { return nil }
        let short = quote.count < Self.shortQuote
        let exact = best(of: occurrences(of: quote, in: markdown), in: markdown, prefix: prefix, suffix: suffix,
                         confirmed: short ? { self.section == Self.heading(before: $0.lowerBound, in: markdown) } : nil)
        if let exact { return exact }
        let (normalized, map) = Self.collapsingWhitespace(markdown)
        let needle = Self.collapsingWhitespace(quote).text.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nil }
        let candidates = occurrences(of: needle, in: normalized)
        // `map[i]` is where normalized character i came from; the last character's own end is
        // the character after it in the original.
        func original(_ hit: Range<String.Index>) -> Range<String.Index> {
            let lower = normalized.distance(from: normalized.startIndex, to: hit.lowerBound)
            let upper = normalized.distance(from: normalized.startIndex, to: hit.upperBound)
            return map[lower]..<markdown.index(after: map[upper - 1])
        }
        return best(of: candidates, in: normalized,
                    prefix: Self.collapsingWhitespace(prefix).text,
                    suffix: Self.collapsingWhitespace(suffix).text,
                    confirmed: short ? { self.section == Self.heading(before: original($0).lowerBound, in: markdown) } : nil)
            .map(original)
    }

    /// Below this many characters a quote needs its context or section to confirm a match.
    public static let shortQuote = 20
    /// How much of the recorded prefix or suffix a short quote's match must keep.
    public static let shortContext = 8

    private func occurrences(of needle: String, in haystack: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var from = haystack.startIndex
        while from < haystack.endIndex, let r = haystack.range(of: needle, range: from..<haystack.endIndex) {
            found.append(r)
            from = haystack.index(after: r.lowerBound)
        }
        return found
    }

    /// The candidate whose surroundings agree most with the recorded context. Ties go to the
    /// first in document order, the only stable answer when the context says nothing.
    ///
    /// `confirmed`, for a short quote, is its section check: the winner must then keep
    /// `shortContext` characters of the prefix or of the suffix (or all of a shorter one — a
    /// quote at the very start or end of the plan), or be confirmed; otherwise nil.
    private func best(of candidates: [Range<String.Index>], in text: String, prefix: String, suffix: String,
                      confirmed: ((Range<String.Index>) -> Bool)? = nil) -> Range<String.Index>? {
        func score(_ r: Range<String.Index>) -> (p: Int, s: Int) {
            let before = text[..<r.lowerBound], after = text[r.upperBound...]
            return (zip(before.reversed(), prefix.reversed()).prefix { $0 == $1 }.count,
                    zip(after, suffix).prefix { $0 == $1 }.count)
        }
        guard var winner = candidates.first else { return nil }
        var top = score(winner)
        for r in candidates.dropFirst() {
            let s = score(r)
            if s.p + s.s > top.p + top.s { winner = r; top = s }
        }
        guard let confirmed else { return winner }
        func kept(_ n: Int, of context: String) -> Bool { n >= Self.shortContext || (!context.isEmpty && n == context.count) }
        return kept(top.p, of: prefix) || kept(top.s, of: suffix) || confirmed(winner) ? winner : nil
    }

    /// `text` with every whitespace run (newlines included) collapsed to a single space, plus
    /// the original index of each character that survived. A blockquote's `>` markers at the
    /// start of a line count as part of the run: a note quoted across a line break of a wrapped
    /// quote (`races the\n> first sync`) must still find the passage once the quote is one
    /// line (`MarkdownUnwrap`), where that `>` is gone.
    private static func collapsingWhitespace(_ text: String) -> (text: String, map: [String.Index]) {
        var out = "", map: [String.Index] = []
        var inRun = false
        var lineStart = false
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch.isWhitespace || (ch == ">" && inRun && lineStart) {
                if !inRun { out.append(" "); map.append(i) }
                inRun = true
                if ch.isNewline { lineStart = true }
            } else {
                lineStart = false
                out.append(ch); map.append(i)
                inRun = false
            }
            i = text.index(after: i)
        }
        return (out, map)
    }

    /// The last `#` heading line that starts before `index`, trimmed.
    static func heading(before index: String.Index, in markdown: String) -> String? {
        planLines(String(markdown[..<index])).last { $0.hasPrefix("#") }
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }
}

/// A note the human attaches to the plan for the next round — anchored to a highlighted quote,
/// or (with `anchor` nil) about the plan as a whole, which is all the old free-text ✎
/// annotation could say.
public struct PlanNote: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: NoteKind
    public var note: String
    public var anchor: NoteAnchor?

    public init(id: UUID = UUID(), kind: NoteKind = .comment, note: String, anchor: NoteAnchor? = nil) {
        self.id = id
        self.kind = kind
        self.note = note
        self.anchor = anchor
    }

    /// An old free-text annotation as an unanchored comment. The id is derived from the text
    /// (and its position, where there is one) rather than random: the app and the runner each
    /// decode the same legacy `tape.json` or `commands.jsonl` line independently, and a random
    /// id would differ between them — a `.removeNote` the app sent for the note it showed would
    /// then match nothing the runner holds.
    public static func legacy(_ text: String, index: Int = 0) -> PlanNote {
        PlanNote(id: stableUUID("\(index)\u{0}\(text)"), kind: .comment, note: text)
    }
}

/// A UUID from FNV-1a over `seed`'s UTF-8, twice with different offsets for 128 bits. Not
/// cryptographic — it only has to be the same in every process, which `Hasher` (randomly
/// seeded per launch) is not.
private func stableUUID(_ seed: String) -> UUID {
    func fnv(_ basis: UInt64) -> UInt64 {
        var h = basis
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
    let a = fnv(0xcbf29ce484222325), b = fnv(0x84222325cbf29ce4)
    var bytes = [UInt8](repeating: 0, count: 16)
    for i in 0..<8 { bytes[i] = UInt8(truncatingIfNeeded: a >> (8 * i)); bytes[8 + i] = UInt8(truncatingIfNeeded: b >> (8 * i)) }
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                       bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
}
